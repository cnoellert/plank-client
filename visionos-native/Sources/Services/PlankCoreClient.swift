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
    @Published private(set) var isClosingSession = false
    @Published private(set) var frameDimensions: PlankFrameDimensions?
    @Published private(set) var videoDiagnosticText = "Video starting…"
    @Published private(set) var activeHostID: HostBookmark.ID?
    var canRetrySession: Bool {
        httpClient != nil && lastIdentity != nil && lastAuthentication != nil
    }
#if PLANK_TABLET_RELAY
    @Published private(set) var tabletRelayStatus = "Pair a Wacom Relay in Settings."
    @Published private(set) var tabletPreflightSummary = "No active Wacom preflight."
    @Published private(set) var waitingForTablet = false
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
    private var lastAuthentication: PlankAuthentication?
    private var inputQueue = PlankInputQueue()
    private var streamTask: Task<Void, Never>?
    private var stoppingStreamTask: Task<Void, Never>?
    private var streamGeneration = UUID()
    private let tabletControlReceiver = PlankTabletControlReceiver()
    private var hostSupportsTabletRelay = false
#if PLANK_TABLET_RELAY
    private var tabletBridge: PlankRelaySessionBridge?
    private var stoppingTabletBridge: PlankRelaySessionBridge?
    private var tabletSceneActive = false
    private var tabletPreflightSequence: UInt64 = 0
    private var tabletInputPolicy = PlankTabletInputPolicy()
#endif

    func setTabletControlReceiver(_ receiver: (@Sendable (Data) -> Void)?) {
        tabletControlReceiver.set(receiver)
    }

    func sendTabletFrame(_ frame: Data) {
        guard case .streaming = phase, hostSupportsTabletRelay else { return }
#if PLANK_TABLET_RELAY
        if rawTabletMessageType(frame) == 3 && !tabletInputPolicy.forwardsTabletReports { return }
#endif
        inputQueue.append(.rawHid(frame))
    }

#if PLANK_TABLET_RELAY
    private func rawTabletMessageType(_ frame: Data) -> UInt16? {
        guard frame.count >= 8 else { return nil }
        return UInt16(frame[6]) | UInt16(frame[7]) << 8
    }

    private func updateTabletPreflight(ready: Bool) {
        // A Relay can disappear while a drag or key is held. Release what the
        // Host has already seen before blocking new user input.
        for release in tabletInputPolicy.updatePreflight(ready: ready) {
            switch release {
            case let .mouse(number):
                inputQueue.append(.button(number: number, pressed: false))
            case let .key(code, modifiers):
                inputQueue.append(.key(code: code, pressed: false, modifiers: modifiers))
            }
        }
        waitingForTablet = tabletInputPolicy.waitsForTablet
    }

    func continueWithoutTablet() {
        guard tabletInputPolicy.waitsForTablet else { return }
        tabletInputPolicy.continueWithoutTablet()
        tabletBridge?.close()
        stoppingTabletBridge = tabletBridge
        tabletBridge = nil
        tabletRelayStatus = "Continuing this session without Wacom."
        waitingForTablet = false
    }
#endif

    func setTabletActive(_ active: Bool) {
#if PLANK_TABLET_RELAY
        tabletSceneActive = active
        tabletBridge?.setActive(active)
#endif
    }

    func connect(to host: HostBookmark) async {
        guard !isClosingSession else { return }
        switch phase {
        case .probing, .authenticating, .startingSession, .frameReceived, .streaming:
            return
        default:
            break
        }
        if activeHostID != host.id {
            transitionCredentials = nil
            lastAuthentication = nil
        }
        activeHostID = host.id
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

    func startSession(displaySize: SpatialDisplaySize, frameRate: Int) {
        guard !isClosingSession else { return }
        guard let httpClient,
              let identity = lastIdentity,
              var connectedHost,
              case let .authenticated(_, authentication) = phase else {
            phase = .failed("The workstation session is no longer ready.")
            return
        }

        connectedHost.spatialDisplaySize = displaySize
        connectedHost.streamFrameRate = StreamFrameRate.normalized(frameRate)
        self.connectedHost = connectedHost

        let previousStreamTask = streamTask ?? stoppingStreamTask
        previousStreamTask?.cancel()
#if PLANK_TABLET_RELAY
        let previousTabletBridge = tabletBridge ?? stoppingTabletBridge
        previousTabletBridge?.close()
        stoppingTabletBridge = previousTabletBridge
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
#if PLANK_TABLET_RELAY
        // GNOME may bind its first pointer interaction before the redirected
        // tablet appears. Present the video immediately, but let a saved Relay
        // attach before forwarding mouse input into that desktop session.
        tabletInputPolicy.begin(hasPairedTablet: PlankRelayKeys.savedConnection() != nil)
        waitingForTablet = tabletInputPolicy.waitsForTablet
#endif
        phase = .startingSession(identity, authentication)
        streamTask = Task { [weak self] in
            guard let self else { return }
            // Wait for the previous transport to send its disconnect and
            // release the Host reservation and the old Relay link before
            // opening another data plane.
            await previousStreamTask?.value
#if PLANK_TABLET_RELAY
            await previousTabletBridge?.waitForClose()
            if self.stoppingTabletBridge === previousTabletBridge {
                self.stoppingTabletBridge = nil
            }
#endif
            guard !Task.isCancelled, self.streamGeneration == generation else { return }
            await runSession(
                httpClient: httpClient,
                identity: identity,
                authentication: authentication,
                connectedHost: connectedHost,
                inputQueue: sessionInputQueue,
                generation: generation
            )
        }
        stoppingStreamTask = nil
    }

    func retrySession(displaySize: SpatialDisplaySize, frameRate: Int) {
        guard !isClosingSession else { return }
        guard let identity = lastIdentity, let authentication = lastAuthentication else { return }
        phase = .authenticated(identity, authentication)
        startSession(displaySize: displaySize, frameRate: frameRate)
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
                    self.updateTabletPreflight(ready: snapshot.ready)
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
            stoppingTabletBridge = sessionTabletBridge
            if tabletBridge === sessionTabletBridge { tabletBridge = nil }
        }
#endif
        do {
            let frameMailbox = PlankFrameMailbox()
            let (readyAuthentication, hostTopology, applications) =
                try await loadSessionMetadata(
                    httpClient: httpClient,
                    authentication: authentication
                )
            try Task.checkCancellation()
            guard let desktop = applications.first(where: {
                $0.title.localizedCaseInsensitiveCompare("Desktop") == .orderedSame
            }) ?? applications.first else {
                throw PlankHTTPError.invalidResponse("The Host has no Desktop application.")
            }
            let requestedTopology = hostTopology.requesting(connectedHost.spatialDisplaySize)
            let (activeHTTPClient, activeAuthentication, topology, launch) = try await launchDesktop(
                httpClient: httpClient,
                authentication: readyAuthentication,
                connectedHost: connectedHost,
                applicationID: desktop.id,
                requestedTopology: requestedTopology
            )
            if self.streamGeneration == generation {
                self.httpClient = activeHTTPClient
                self.lastAuthentication = activeAuthentication
            }
            // Once launch has reserved the Host, enter the transport even if
            // cancellation arrived with the HTTP response. Its cancellation
            // handler then closes that fresh reservation cleanly.
            try await PlankSessionEngine().stream(
                host: connectedHost.address.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
                topology: topology,
                frameRate: connectedHost.streamFrameRate,
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
            } onVideoProgress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    guard let self, self.streamGeneration == generation else { return }
                    let shown = self.latestFrame?.frameNumber ?? 0
                    self.videoDiagnosticText =
                        "Received \(progress.received) · decoded \(progress.decoded) · shown \(shown)\n" +
                        "keys \(progress.keyFrames) · drops \(progress.receiveDrops) · " +
                        "gaps \(progress.frameGaps) · FEC \(progress.fecUnrecovered) · " +
                        String(format: "decode %.1f ms", progress.averageDecodeMilliseconds) +
                        " · \(progress.decoder)"
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
                    // Keep the input barrier in place until the Host confirms
                    // the tablet attachment, or the user explicitly continues
                    // without it. A timeout must not silently open input.
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
#if PLANK_TABLET_RELAY
            tabletRelayStatus = "Tablet link idle; start a desktop session to connect."
            tabletPreflightSummary = "No active Wacom preflight."
            waitingForTablet = false
#endif
            phase = .failed(Self.message(for: error))
        }
    }

    private func loadSessionMetadata(
        httpClient: PlankHTTPClient,
        authentication: PlankAuthentication
    ) async throws -> (PlankAuthentication, PlankTopology, [PlankApplication]) {
        func renewAuthentication() async throws -> PlankAuthentication {
            guard let credentials = transitionCredentials else {
                throw PlankHTTPError.invalidResponse(
                    "The Host restarted and needs a new sign-in."
                )
            }
            let renewed = try await httpClient.refreshAuthentication(
                username: credentials.username,
                password: credentials.password
            )
            lastAuthentication = renewed
            return renewed
        }

        func load() async throws -> (PlankTopology, [PlankApplication]) {
            async let topology = httpClient.fetchTopology()
            async let applications = httpClient.fetchApplications()
            return try await (topology, applications)
        }

        let currentAuthentication = httpClient.sessionToken == nil ?
            try await renewAuthentication() : authentication
        do {
            let (topology, applications) = try await load()
            return (currentAuthentication, topology, applications)
        } catch let PlankHTTPError.rejected(code, _) where code == 401 {
            let renewed = try await renewAuthentication()
            let (topology, applications) = try await load()
            return (renewed, topology, applications)
        }
    }

    private func launchDesktop(
        httpClient initialClient: PlankHTTPClient,
        authentication initialAuthentication: PlankAuthentication,
        connectedHost: HostBookmark,
        applicationID: Int,
        requestedTopology: PlankTopology
    ) async throws -> (PlankHTTPClient, PlankAuthentication, PlankTopology, PlankLaunchCredentials) {
        try Task.checkCancellation()
        var needsAuthentication = false
        var waitingForRelease = false
        do {
            let launch = try await initialClient.launchDesktop(
                topology: requestedTopology,
                applicationID: applicationID,
                frameRate: connectedHost.streamFrameRate
            )
            return (initialClient, initialAuthentication, requestedTopology, launch)
        } catch let PlankHTTPError.rejected(code, _) where code == 425 {
            // A virtual display change replaces the Host worker. Mirror the
            // desktop Client's bounded wait, reauthentication and verification.
        } catch let PlankHTTPError.rejected(code, _) where code == 401 {
            needsAuthentication = true
        } catch let PlankHTTPError.rejected(code, _)
            where code == 409 || code == 503 {
            // A previous local stream can still be STOPPING at the Host even
            // after its Vision Pro window has closed. Encoder teardown can
            // also make the Host temporarily busy. Give either state a short
            // grace period; a persistent conflict is still reported.
            waitingForRelease = true
        }

        guard let credentials = transitionCredentials else {
            throw PlankHTTPError.invalidResponse(
                "The workstation changed its display layout, but the sign-in could not be resumed."
            )
        }

        var deadline = ContinuousClock.now.advanced(
            by: .seconds(waitingForRelease ? 12 : 45)
        )
        let client = initialClient
        var authentication = initialAuthentication

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(500))

            do {
                if needsAuthentication {
                    authentication = try await client.refreshAuthentication(
                        username: credentials.username,
                        password: credentials.password
                    )
                    lastAuthentication = authentication
                    needsAuthentication = false
                }

                let currentTopology = try await client.fetchTopology()
                guard currentTopology.matches(connectedHost.spatialDisplaySize) else {
                    continue
                }
                let verifiedRequest = currentTopology.requesting(connectedHost.spatialDisplaySize)
                let launch = try await client.launchDesktop(
                    topology: verifiedRequest,
                    applicationID: applicationID,
                    frameRate: connectedHost.streamFrameRate
                )
                return (client, authentication, verifiedRequest, launch)
            } catch let PlankHTTPError.rejected(code, _) where code == 401 {
                needsAuthentication = true
            } catch let PlankHTTPError.rejected(code, _) where code == 409 {
                waitingForRelease = true
                continue
            } catch let PlankHTTPError.rejected(code, _) where code == 425 {
                waitingForRelease = false
                deadline = ContinuousClock.now.advanced(by: .seconds(45))
                continue
            } catch let PlankHTTPError.rejected(code, _) where code == 503 {
                waitingForRelease = true
                continue
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The replacement worker briefly drops HTTP while X restarts.
                needsAuthentication = true
            }
        }

        throw PlankHTTPError.invalidResponse(waitingForRelease ?
            "The previous workstation session is still closing. Please try again shortly." :
            "The workstation display layout did not become ready within 45 seconds."
        )
    }

    func disconnectSession() {
        guard !isClosingSession else { return }
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
        let taskToStop = streamTask ?? stoppingStreamTask
        streamTask?.cancel()
        if let taskToStop { stoppingStreamTask = taskToStop }
        streamTask = nil
#if PLANK_TABLET_RELAY
        let closingTabletBridge = tabletBridge ?? stoppingTabletBridge
        closingTabletBridge?.close()
        stoppingTabletBridge = closingTabletBridge
        tabletBridge = nil
        tabletSceneActive = false
        tabletRelayStatus = "Tablet link idle; start a desktop session to connect."
        tabletPreflightSummary = "No active Wacom preflight."
        tabletInputPolicy.begin(hasPairedTablet: false)
        waitingForTablet = false
#endif
        tabletControlReceiver.set(nil)
        hostSupportsTabletRelay = false
        streamGeneration = UUID()
        let closingGeneration = streamGeneration
        inputQueue.stop()
        latestFrame = nil
        remoteCursor = nil
        remoteCursorShape = nil
        frameDimensions = nil
        videoDiagnosticText = "Video starting…"
        presentFrame?(nil)
        presentCursor?(nil)
        presentCursorShape?(nil)
        if let resumable {
            phase = .authenticated(resumable.0, resumable.1)
        } else {
            phase = .idle
        }
        awaitStreamClosure(taskToStop, generation: closingGeneration)
    }

    private func awaitStreamClosure(_ task: Task<Void, Never>?, generation: UUID) {
#if PLANK_TABLET_RELAY
        let closingBridge = stoppingTabletBridge
        isClosingSession = task != nil || closingBridge != nil
        guard task != nil || closingBridge != nil else { return }
#else
        isClosingSession = task != nil
        guard task != nil else { return }
#endif
        Task { [weak self] in
            // Closing the window never makes the Host session reusable. Wait
            // until the worker and Relay link have both released their sessions.
            await task?.value
#if PLANK_TABLET_RELAY
            await closingBridge?.waitForClose()
#endif
            guard let self, self.streamGeneration == generation else { return }
            self.stoppingStreamTask = nil
#if PLANK_TABLET_RELAY
            if self.stoppingTabletBridge === closingBridge {
                self.stoppingTabletBridge = nil
            }
#endif
            self.isClosingSession = false
        }
    }

    func movePointer(x: Int, y: Int, width: Int, height: Int) {
#if PLANK_TABLET_RELAY
        guard !waitingForTablet else { return }
#endif
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
#if PLANK_TABLET_RELAY
        guard tabletInputPolicy.allowsMouseButton(number, pressed: pressed) else { return }
#endif
        inputQueue.append(.button(number: number, pressed: pressed))
    }

    func clickLeftButton() {
        clickMouseButton(number: 1)
    }

    func clickMouseButton(number: UInt8) {
        setMouseButton(number: number, pressed: true)
        setMouseButton(number: number, pressed: false)
    }

    func scroll(vertical: Int16, horizontal: Int16 = 0) {
#if PLANK_TABLET_RELAY
        guard !waitingForTablet else { return }
#endif
        guard vertical != 0 || horizontal != 0 else { return }
        inputQueue.append(.scroll(vertical: vertical, horizontal: horizontal))
    }

    func sendText(_ text: String) {
#if PLANK_TABLET_RELAY
        guard !waitingForTablet else { return }
#endif
        guard let data = text.data(using: .utf8), !data.isEmpty else { return }
        inputQueue.append(.text(data))
    }

    func pressKey(code: UInt16, modifiers: UInt8 = 0) {
        sendKey(code: code, pressed: true, modifiers: modifiers)
        sendKey(code: code, pressed: false, modifiers: modifiers)
    }

    func sendKey(code: UInt16, pressed: Bool, modifiers: UInt8) {
#if PLANK_TABLET_RELAY
        guard tabletInputPolicy.allowsKey(code, pressed: pressed, modifiers: modifiers) else { return }
#endif
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
            lastAuthentication = authentication
            phase = .authenticated(identity, authentication)
        } catch {
            transitionCredentials = nil
            lastAuthentication = nil
            phase = .failed(Self.message(for: error))
        }
    }

    func retryCredentials() {
        guard let identity = lastIdentity else { return }
        phase = .needsCredentials(identity)
    }

    func reset() {
        let taskToStop = streamTask ?? stoppingStreamTask
        taskToStop?.cancel()
        if let taskToStop { stoppingStreamTask = taskToStop }
        streamTask = nil
#if PLANK_TABLET_RELAY
        let closingTabletBridge = tabletBridge ?? stoppingTabletBridge
        closingTabletBridge?.close()
        stoppingTabletBridge = closingTabletBridge
        tabletBridge = nil
        tabletSceneActive = false
        tabletRelayStatus = "Tablet link idle; start a desktop session to connect."
        tabletPreflightSummary = "No active Wacom preflight."
        tabletInputPolicy.begin(hasPairedTablet: false)
        waitingForTablet = false
#endif
        tabletControlReceiver.set(nil)
        hostSupportsTabletRelay = false
        streamGeneration = UUID()
        let closingGeneration = streamGeneration
        inputQueue.stop()
        httpClient = nil
        lastIdentity = nil
        connectedHost = nil
        activeHostID = nil
        transitionCredentials = nil
        lastAuthentication = nil
        awaitStreamClosure(taskToStop, generation: closingGeneration)
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
