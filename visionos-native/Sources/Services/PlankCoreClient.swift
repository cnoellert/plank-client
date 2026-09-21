import Combine
import Foundation

enum ConnectionPhase: Equatable, Sendable {
    case idle
    case probing
    case needsCredentials(PlankHostIdentity)
    case authenticating(PlankHostIdentity)
    case authenticated(PlankHostIdentity, PlankAuthentication)
    case startingSession(PlankHostIdentity, PlankAuthentication)
    case frameReceived(PlankHostIdentity, PlankAuthentication, PlankFrameProbe)
    case streaming(PlankHostIdentity, PlankAuthentication, UInt64)
    case failed(String)
}

@MainActor
final class PlankCoreClient: ObservableObject {
    @Published private(set) var phase: ConnectionPhase = .idle
    @Published private(set) var latestFrame: PlankRenderedFrame?
    @Published private(set) var remoteCursor: PlankRemoteCursor?

    private var httpClient: PlankHTTPClient?
    private var lastIdentity: PlankHostIdentity?
    private var connectedHost: HostBookmark?
    private let inputQueue = PlankInputQueue()
    private var streamTask: Task<Void, Never>?

    func connect(to host: HostBookmark) async {
        phase = .probing
        do {
            let client = try PlankHTTPClient(host: host)
            let identity = try await client.fetchServerInfo()
            guard identity.supportsAuthentication else {
                throw PlankHTTPError.invalidResponse("This Host does not advertise PLANK authentication.")
            }
            httpClient = client
            lastIdentity = identity
            connectedHost = host
            phase = .needsCredentials(identity)
        } catch {
            httpClient = nil
            lastIdentity = nil
            phase = .failed(Self.message(for: error))
        }
    }

    func startSession() {
        guard let httpClient,
              let identity = lastIdentity,
              let connectedHost,
              case let .authenticated(_, authentication) = phase else {
            phase = .failed("The workstation session is no longer ready.")
            return
        }

        streamTask?.cancel()
        phase = .startingSession(identity, authentication)
        streamTask = Task { [weak self] in
            guard let self else { return }
            await runSession(
                httpClient: httpClient,
                identity: identity,
                authentication: authentication,
                connectedHost: connectedHost
            )
        }
    }

    private func runSession(
        httpClient: PlankHTTPClient,
        identity: PlankHostIdentity,
        authentication: PlankAuthentication,
        connectedHost: HostBookmark
    ) async {
        do {
            async let topologyRequest = httpClient.fetchTopology()
            async let applicationsRequest = httpClient.fetchApplications()
            let (topology, applications) = try await (topologyRequest, applicationsRequest)
            guard let desktop = applications.first(where: {
                $0.title.localizedCaseInsensitiveCompare("Desktop") == .orderedSame
            }) ?? applications.first else {
                throw PlankHTTPError.invalidResponse("The Host has no Desktop application.")
            }
            let launch = try await httpClient.launchDesktop(
                topology: topology,
                applicationID: desktop.id
            )
            try await PlankSessionEngine().stream(
                host: connectedHost.address.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
                topology: topology,
                launch: launch,
                inputQueue: inputQueue
            ) { [weak self] frame in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.latestFrame = frame
                    self.phase = .streaming(identity, authentication, frame.frameNumber)
                }
            } onCursor: { [weak self] cursor in
                Task { @MainActor [weak self] in
                    self?.remoteCursor = cursor
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(Self.message(for: error))
        }
    }

    func disconnectSession() {
        let resumable: (PlankHostIdentity, PlankAuthentication)?
        switch phase {
        case let .startingSession(identity, authentication),
             let .frameReceived(identity, authentication, _),
             let .streaming(identity, authentication, _):
            resumable = (identity, authentication)
        case let .authenticated(identity, authentication):
            resumable = (identity, authentication)
        default:
            resumable = nil
        }
        streamTask?.cancel()
        streamTask = nil
        inputQueue.removeAll()
        latestFrame = nil
        remoteCursor = nil
        if let resumable {
            phase = .authenticated(resumable.0, resumable.1)
        } else {
            phase = .idle
        }
    }

    func movePointer(x: Int, y: Int, width: Int, height: Int) {
        guard width > 1, height > 1 else { return }
        let maximumX = min(width - 1, Int(UInt16.max))
        let maximumY = min(height - 1, Int(UInt16.max))
        inputQueue.append(.pointer(
            x: UInt16(clamping: x),
            y: UInt16(clamping: y),
            maximumX: UInt16(maximumX),
            maximumY: UInt16(maximumY)
        ))
    }

    func setLeftButton(pressed: Bool) {
        inputQueue.append(.button(number: 1, pressed: pressed))
    }

    func sendText(_ text: String) {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return }
        inputQueue.append(.text(data))
    }

    func pressKey(code: UInt16, modifiers: UInt8 = 0) {
        inputQueue.append(.key(code: code, pressed: true, modifiers: modifiers))
        inputQueue.append(.key(code: code, pressed: false, modifiers: modifiers))
    }

    func authenticate(username: String, password: String) async {
        guard let httpClient,
              let identity = lastIdentity else {
            phase = .failed("The workstation connection is no longer ready.")
            return
        }

        phase = .authenticating(identity)
        do {
            let authentication = try await httpClient.authenticate(
                username: username,
                password: password
            )
            phase = .authenticated(identity, authentication)
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    func retryCredentials() {
        guard let identity = lastIdentity else { return }
        phase = .needsCredentials(identity)
    }

    func reset() {
        streamTask?.cancel()
        streamTask = nil
        inputQueue.removeAll()
        httpClient = nil
        lastIdentity = nil
        connectedHost = nil
        latestFrame = nil
        remoteCursor = nil
        phase = .idle
    }

    private static func message(for error: Error) -> String {
        if let error = error as? LocalizedError,
           let description = error.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
