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

    private var httpClient: PlankHTTPClient?
    private var lastIdentity: PlankHostIdentity?
    private var connectedHost: HostBookmark?

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

    func startSession() async {
        guard let httpClient,
              let identity = lastIdentity,
              let connectedHost,
              case let .authenticated(_, authentication) = phase else {
            phase = .failed("The workstation session is no longer ready.")
            return
        }

        phase = .startingSession(identity, authentication)
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
                launch: launch
            ) { [weak self] frame in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.latestFrame = frame
                    self.phase = .streaming(identity, authentication, frame.frameNumber)
                }
            }
        } catch {
            phase = .failed(Self.message(for: error))
        }
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
        httpClient = nil
        lastIdentity = nil
        connectedHost = nil
        latestFrame = nil
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
