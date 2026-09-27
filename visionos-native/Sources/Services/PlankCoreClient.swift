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

// A busy main actor only needs the newest decoded frame. Keep one pending
// delivery instead of scheduling a separate UI task for every video frame.
private final class PlankFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var newest: PlankRenderedFrame?
    private var deliveryScheduled = false

    func offer(_ frame: PlankRenderedFrame) -> Bool {
        lock.lock()
        newest = frame
        let shouldSchedule = !deliveryScheduled
        deliveryScheduled = true
        lock.unlock()
        return shouldSchedule
    }

    func takeNewest() -> PlankRenderedFrame? {
        lock.lock()
        let frame = newest
        newest = nil
        deliveryScheduled = false
        lock.unlock()
        return frame
    }
}

// The Relay will install a receiver here. Host control frames stay on the
// session worker and are never stored in UI state or copied to logs.
private final class PlankTabletControlReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private var receiver: (@Sendable (Data) -> Void)?

    func set(_ next: (@Sendable (Data) -> Void)?) {
        lock.lock()
        receiver = next
        lock.unlock()
    }

    func deliver(_ frame: Data) {
        lock.lock()
        let current = receiver
        lock.unlock()
        current?(frame)
    }
}

@MainActor
final class PlankCoreClient: ObservableObject {
    @Published private(set) var phase: ConnectionPhase = .idle
    @Published private(set) var frameDimensions: PlankFrameDimensions?
    @Published private(set) var activeHostID: HostBookmark.ID?
#if PLANK_TABLET_RELAY
    @Published private(set) var tabletRelayStatus = "Pair a Wacom Relay in Settings."
    @Published private(set) var tabletPreflightSummary = "No active Wacom preflight."
#endif

    private var latestFrame: PlankRenderedFrame?
    private var remoteCursor: PlankRemoteCursor?
    private var remoteCursorShape: PlankRemoteCursorShape?
    private var videoSurfaceID: UUID?
    private var presentFrame: ((PlankRenderedFrame?) -> Void)?
    private var presentCursor: ((PlankRemoteCursor?) -> Void)?
    private var presentCursorShape: ((PlankRemoteCursorShape?) -> Void)?

    private var httpClient: PlankHTTPClient?
    private var lastIdentity: PlankHostIdentity?
    private var connectedHost: HostBookmark?
    private var transitionCredentials: (username: String, password: String)?
    private var inputQueue = PlankInputQueue()
    private var streamTask: Task<Void, Never>?
    private var streamGeneration = UUID()
    private let tabletControlReceiver = PlankTabletControlReceiver()
    private var hostSupportsTabletRelay = false
#if PLANK_TABLET_RELAY
    private var tabletBridge: PlankRelaySessionBridge?
    private var tabletSceneActive = false
    private var tabletPreflightSequence: UInt64 = 0
#endif

    func setTabletControlReceiver(_ receiver: (@Sendable (Data) -> Void)?) {
        tabletControlReceiver.set(receiver)
    }

    func sendTabletFrame(_ frame: Data) {
        guard case .streaming = phase, hostSupportsTabletRelay else { return }
        inputQueue.append(.rawHid(frame))
    }

    func setTabletActive(_ active: Bool) {
#if PLANK_TABLET_RELAY
        tabletSceneActive = active
        tabletBridge?.setActive(active)
#endif
    }

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
            activeHostID = host.id
            phase = .needsCredentials(identity)
        } catch {
            httpClient = nil
            lastIdentity = nil
            phase = .failed(Self.message(for: error))
        }
    }

    func startSession(displaySize: SpatialDisplaySize) {
        guard let httpClient,
              let identity = lastIdentity,
              var connectedHost,
              case let .authenticated(_, authentication) = phase else {
            phase = .failed("The workstation session is no longer ready.")
            return
        }

        connectedHost.spatialDisplaySize = displaySize
        self.connectedHost = connectedHost

        streamTask?.cancel()
#if PLANK_TABLET_RELAY
        tabletBridge?.close()
        tabletBridge = nil
#endif
        inputQueue.stop()
        inputQueue = PlankInputQueue()
        remoteCursor = nil
        remoteCursorShape = nil
        hostSupportsTabletRelay = false
#if PLANK_TABLET_RELAY
        tabletRelayStatus = "Waiting for Host tablet support…"
        tabletPreflightSummary = "Waiting for Host and Relay checks…"
        tabletPreflightSequence = 0
#endif
        let sessionInputQueue = inputQueue
        streamGeneration = UUID()
        let generation = streamGeneration
        phase = .startingSession(identity, authentication)
        streamTask = Task { [weak self] in
            guard let self else { return }
            await runSession(
                httpClient: httpClient,
                identity: identity,
                authentication: authentication,
                connectedHost: connectedHost,
                inputQueue: sessionInputQueue,
                generation: generation
            )
        }
    }

    private func runSession(
        httpClient: PlankHTTPClient,
        identity: PlankHostIdentity,
        authentication: PlankAuthentication,
        connectedHost: HostBookmark,
        inputQueue: PlankInputQueue,
        generation: UUID
    ) async {
#if PLANK_TABLET_RELAY
        let preflight = PlankWacomPreflight(
            clientVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            hostVersion: identity.version,
            onChange: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    guard let self, self.streamGeneration == generation,
                          snapshot.sequence > self.tabletPreflightSequence else { return }
                    self.tabletPreflightSequence = snapshot.sequence
                    self.tabletPreflightSummary = snapshot.summary
                }
            }
        )
        let sessionTabletBridge = PlankRelaySessionBridge(
            inputQueue: inputQueue, preflight: preflight
        ) {
            [weak self] status in
            Task { @MainActor [weak self] in
                guard let self, self.streamGeneration == generation else { return }
                self.tabletRelayStatus = status
            }
        }
        tabletBridge = sessionTabletBridge
        sessionTabletBridge.setActive(tabletSceneActive)
        defer {
            sessionTabletBridge.close()
            if tabletBridge === sessionTabletBridge { tabletBridge = nil }
        }
#endif
        do {
            let frameMailbox = PlankFrameMailbox()
            async let topologyRequest = httpClient.fetchTopology()
            async let applicationsRequest = httpClient.fetchApplications()
            let (hostTopology, applications) = try await (topologyRequest, applicationsRequest)
            guard let desktop = applications.first(where: {
                $0.title.localizedCaseInsensitiveCompare("Desktop") == .orderedSame
            }) ?? applications.first else {
                throw PlankHTTPError.invalidResponse("The Host has no Desktop application.")
            }
            let requestedTopology = hostTopology.requesting(connectedHost.spatialDisplaySize)
            let (activeHTTPClient, activeAuthentication, topology, launch) = try await launchDesktop(
                httpClient: httpClient,
                authentication: authentication,
                connectedHost: connectedHost,
                applicationID: desktop.id,
                requestedTopology: requestedTopology
            )
            self.httpClient = activeHTTPClient
            try await PlankSessionEngine().stream(
                host: connectedHost.address.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
                topology: topology,
                launch: launch,
                inputQueue: inputQueue
            ) { [weak self] frame in
                if frameMailbox.offer(frame) {
                    Task { @MainActor [weak self] in
                        guard let self, let newest = frameMailbox.takeNewest(),
                              self.streamGeneration == generation else { return }
                        self.latestFrame = newest
                        let dimensions = PlankFrameDimensions(
                            width: newest.width, height: newest.height
                        )
                        if self.frameDimensions != dimensions {
                            self.frameDimensions = dimensions
                        }
                        self.presentFrame?(newest)
                        if case let .streaming(_, _, shownFrame) = self.phase {
                            if newest.frameNumber >= shownFrame + 60 {
                                self.phase = .streaming(
                                    identity, activeAuthentication, newest.frameNumber
                                )
                            }
                        } else {
                            self.phase = .streaming(identity, activeAuthentication, newest.frameNumber)
                        }
                    }
                }
            } onCursor: { [weak self] update in
                Task { @MainActor [weak self] in
                    guard let self, self.streamGeneration == generation else { return }
                    switch update {
                    case let .position(cursor):
                        self.remoteCursor = cursor
                        self.presentCursor?(cursor)
                    case let .shape(shape):
                        self.remoteCursorShape = shape
                        self.presentCursorShape?(shape)
                    }
                }
            } onHostFeatures: { [weak self] flags in
#if PLANK_TABLET_RELAY
                preflight.observeHostFeatures(
                    rawHid: flags & PlankHostFeature.rawHidTablet != 0,
                    focusSuspend: flags & PlankHostFeature.rawHidFocusSuspend != 0
                )
                sessionTabletBridge.startIfPaired(hostFeatures: flags)
#endif
                Task { @MainActor [weak self] in
                    guard let self, self.streamGeneration == generation else { return }
                    self.hostSupportsTabletRelay =
                        flags & PlankHostFeature.tabletRelayRequired ==
                        PlankHostFeature.tabletRelayRequired
                }
            } onRawHid: { [tabletControlReceiver] frame in
#if PLANK_TABLET_RELAY
                preflight.observeHostFrame(frame)
                sessionTabletBridge.forwardHostFrame(frame)
#else
                tabletControlReceiver.deliver(frame)
#endif
            } onTabletFrameSent: { frame in
#if PLANK_TABLET_RELAY
                preflight.observeSentTabletFrame(frame)
#endif
            }
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(Self.message(for: error))
        }
    }

    private func launchDesktop(
        httpClient initialClient: PlankHTTPClient,
        authentication initialAuthentication: PlankAuthentication,
        connectedHost: HostBookmark,
        applicationID: Int,
        requestedTopology: PlankTopology
    ) async throws -> (PlankHTTPClient, PlankAuthentication, PlankTopology, PlankLaunchCredentials) {
        do {
            let launch = try await initialClient.launchDesktop(
                topology: requestedTopology,
                applicationID: applicationID
            )
            return (initialClient, initialAuthentication, requestedTopology, launch)
        } catch let PlankHTTPError.rejected(code, _) where code == 425 {
            // A virtual display change replaces the Host worker. Mirror the
            // desktop Client's bounded wait, reauthentication and verification.
        }

        guard let credentials = transitionCredentials else {
            throw PlankHTTPError.invalidResponse(
                "The workstation changed its display layout, but the sign-in could not be resumed."
            )
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        var client = initialClient
        var authentication = initialAuthentication
        var needsAuthentication = false

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(500))

            do {
                if needsAuthentication {
                    let replacement = try PlankHTTPClient(host: connectedHost)
                    _ = try await replacement.fetchServerInfo()
                    authentication = try await replacement.authenticate(
                        username: credentials.username,
                        password: credentials.password
                    )
                    client = replacement
                    needsAuthentication = false
                }

                let currentTopology = try await client.fetchTopology()
                guard currentTopology.matches(connectedHost.spatialDisplaySize) else {
                    continue
                }
                let verifiedRequest = currentTopology.requesting(connectedHost.spatialDisplaySize)
                let launch = try await client.launchDesktop(
                    topology: verifiedRequest,
                    applicationID: applicationID
                )
                return (client, authentication, verifiedRequest, launch)
            } catch let PlankHTTPError.rejected(code, _) where code == 401 {
                needsAuthentication = true
            } catch let PlankHTTPError.rejected(code, _)
                where code == 409 || code == 425 || code == 503 {
                continue
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The replacement worker briefly drops HTTP while X restarts.
                needsAuthentication = true
            }
        }

        throw PlankHTTPError.invalidResponse(
            "The workstation display layout did not become ready within 45 seconds."
        )
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
#if PLANK_TABLET_RELAY
        tabletBridge?.close()
        tabletBridge = nil
        tabletSceneActive = false
        tabletPreflightSummary = "No active Wacom preflight."
#endif
        tabletControlReceiver.set(nil)
        streamGeneration = UUID()
        inputQueue.stop()
        latestFrame = nil
        remoteCursor = nil
        remoteCursorShape = nil
        frameDimensions = nil
        presentFrame?(nil)
        presentCursor?(nil)
        presentCursorShape?(nil)
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
        setMouseButton(number: 1, pressed: pressed)
    }

    func setMouseButton(number: UInt8, pressed: Bool) {
        inputQueue.append(.button(number: number, pressed: pressed))
    }

    func clickLeftButton() {
        clickMouseButton(number: 1)
    }

    func clickMouseButton(number: UInt8) {
        inputQueue.append(.button(number: number, pressed: true))
        inputQueue.append(.button(number: number, pressed: false))
    }

    func scroll(vertical: Int16, horizontal: Int16 = 0) {
        guard vertical != 0 || horizontal != 0 else { return }
        inputQueue.append(.scroll(vertical: vertical, horizontal: horizontal))
    }

    func sendText(_ text: String) {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return }
        inputQueue.append(.text(data))
    }

    func pressKey(code: UInt16, modifiers: UInt8 = 0) {
        sendKey(code: code, pressed: true, modifiers: modifiers)
        sendKey(code: code, pressed: false, modifiers: modifiers)
    }

    func sendKey(code: UInt16, pressed: Bool, modifiers: UInt8) {
        inputQueue.append(.key(code: code, pressed: pressed, modifiers: modifiers))
    }

    func authenticate(username: String, password: String) async {
        guard let httpClient,
              let identity = lastIdentity else {
            phase = .failed("The workstation connection is no longer ready.")
            return
        }

        phase = .authenticating(identity)
        do {
            transitionCredentials = (username, password)
            let authentication = try await httpClient.authenticate(
                username: username,
                password: password
            )
            phase = .authenticated(identity, authentication)
        } catch {
            transitionCredentials = nil
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
#if PLANK_TABLET_RELAY
        tabletBridge?.close()
        tabletBridge = nil
        tabletSceneActive = false
        tabletPreflightSummary = "No active Wacom preflight."
#endif
        tabletControlReceiver.set(nil)
        streamGeneration = UUID()
        inputQueue.stop()
        httpClient = nil
        lastIdentity = nil
        connectedHost = nil
        activeHostID = nil
        transitionCredentials = nil
        latestFrame = nil
        remoteCursor = nil
        remoteCursorShape = nil
        frameDimensions = nil
        presentFrame?(nil)
        presentCursor?(nil)
        presentCursorShape?(nil)
        phase = .idle
    }

    func registerVideoSurface(
        id: UUID,
        frame: @escaping (PlankRenderedFrame?) -> Void,
        cursor: @escaping (PlankRemoteCursor?) -> Void,
        cursorShape: @escaping (PlankRemoteCursorShape?) -> Void
    ) {
        videoSurfaceID = id
        presentFrame = frame
        presentCursor = cursor
        presentCursorShape = cursorShape
        frame(latestFrame)
        cursor(remoteCursor)
        cursorShape(remoteCursorShape)
    }

    func unregisterVideoSurface(id: UUID) {
        guard videoSurfaceID == id else { return }
        videoSurfaceID = nil
        presentFrame = nil
        presentCursor = nil
        presentCursorShape = nil
    }

    private static func message(for error: Error) -> String {
        if let error = error as? LocalizedError,
           let description = error.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
