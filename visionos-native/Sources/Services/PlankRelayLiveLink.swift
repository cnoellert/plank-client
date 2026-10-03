import Foundation
import Network

// All codec calls and socket writes run on one serial queue. Host control
// callbacks only enqueue work here, preserving their arrival order.
final class PlankRelayLiveLink: @unchecked Sendable {
    private enum Message {
        static let sessionReady: UInt16 = 2
        static let sessionActive: UInt16 = 3
        static let sessionEnd: UInt16 = 6
        static let hostFrame: UInt16 = 7
        static let clientFrame: UInt16 = 8
        static let status: UInt16 = 9
        static let ping: UInt16 = 10
        static let pong: UInt16 = 11
        static let goodbye: UInt16 = 12
    }

    private let queue = DispatchQueue(label: "la.instinctual.plank.tablet-relay.session")
    private let connection: any PlankRelayByteTransport
    private let bluetooth: Bool
    private let hostFeatures: UInt32
    private let preflight: PlankWacomPreflight
    private let deliverTabletFrame: @Sendable (Data) -> Void
    private let reportState: @Sendable (String) -> Void
    private let onReady: @Sendable () -> Void
    private let onUnexpectedClose: @Sendable (PlankRelayCloseReason) -> Void
    private let acceptGeneration: @Sendable (UInt16) -> Bool
    private var codec: OpaquePointer?
    private var heartbeat: DispatchSourceTimer?
    private var connectionReady = false
    private var sessionReady = false
    private var active = false
    private var closed = false
    private var closeCompleted = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastReceive = DispatchTime.now().uptimeNanoseconds
    private var pendingHostFrames: [Data] = []
    private var pendingHostBytes = 0
    private var invalidTabletFrames = 0
    private var attachedGeneration: UInt16?

    init(endpoint: NWEndpoint, hostFeatures: UInt32, bluetooth: Bool = false,
         preflight: PlankWacomPreflight,
         clientPrivateKey: Data, relayPublicKey: Data,
         deliverTabletFrame: @escaping @Sendable (Data) -> Void,
         reportState: @escaping @Sendable (String) -> Void,
         onReady: @escaping @Sendable () -> Void,
         onUnexpectedClose: @escaping @Sendable (PlankRelayCloseReason) -> Void,
         acceptGeneration: @escaping @Sendable (UInt16) -> Bool) throws {
        guard clientPrivateKey.count == 32, relayPublicKey.count == 32 else {
            throw PlankRelayLiveError.invalidConfiguration
        }
        let created = clientPrivateKey.withUnsafeBytes { clientBytes in
            relayPublicKey.withUnsafeBytes { relayBytes in
                pltr_client_link_create(
                    clientBytes.bindMemory(to: UInt8.self).baseAddress,
                    relayBytes.bindMemory(to: UInt8.self).baseAddress,
                    bluetooth ? 1 : 2 // Transport is part of the authenticated Noise prologue.
                )
            }
        }
        guard let created else { throw PlankRelayLiveError.invalidConfiguration }
        codec = created
        connection = bluetooth ? PlankRelayBluetoothTransport() : PlankRelayTCPTransport(endpoint: endpoint)
        self.bluetooth = bluetooth
        self.hostFeatures = hostFeatures
        self.preflight = preflight
        self.deliverTabletFrame = deliverTabletFrame
        self.reportState = reportState
        self.onReady = onReady
        self.onUnexpectedClose = onUnexpectedClose
        self.acceptGeneration = acceptGeneration
    }

    func start() {
        queue.async { [self] in
            guard !closed else { return }
            connection.start(queue: queue, ready: { [weak self] in
                guard let self, !self.closed else { return }
                self.connectionReady = true
                self.reportState(self.bluetooth ? "Bluetooth Relay connected; verifying its identity…" : "Relay connected; verifying its identity…")
                self.lastReceive = DispatchTime.now().uptimeNanoseconds
                var bytes = [UInt8](repeating: 0, count: 256)
                var written = 0
                guard let codec = self.codec,
                      pltr_client_link_start(codec, &bytes, bytes.count, &written) == 0 else {
                    self.closeOnQueue(reason: .handshakeStartFailed); return
                }
                self.write(Data(bytes.prefix(written)))
                self.receiveNext()
            }, failed: { [weak self] error in
                guard let self else { return }
                NSLog("PLANK Relay transport failed: %@", String(describing: error))
                self.closeOnQueue(reason: .connectionEnded)
            })
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }
            heartbeat = timer
            timer.resume()
        }
    }

    func forwardHostFrame(_ frame: Data) {
        queue.async { [self] in
            guard !closed else { return }
            let valid = frame.withUnsafeBytes { bytes in
                plank_vision_raw_hid_frame_valid(
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    frame.count, PLANK_VISION_RAW_HID_FROM_HOST
                )
            }
            guard valid == 1 else { closeOnQueue(reason: .invalidHostFrame); return }
            if frame.count >= 24, frame[6] == 10 {
                let generation = UInt16(frame[10]) | (UInt16(frame[11]) << 8)
                let result = frame[20..<24].contains { $0 != 0 }
                if result && attachedGeneration == generation {
                    attachedGeneration = nil
                }
            }
            if sessionReady {
                send(Message.hostFrame, frame)
            } else {
                guard pendingHostFrames.count < 64,
                      frame.count <= 64 * 1024 - pendingHostBytes else {
                    closeOnQueue(reason: .pendingHostOverflow)
                    return
                }
                pendingHostFrames.append(frame)
                pendingHostBytes += frame.count
            }
        }
    }

    func setActive(_ next: Bool) {
        queue.async { [self] in
            guard !closed else { return }
            active = next
            if sessionReady { send(Message.sessionActive, Data([next ? 1 : 0])) }
        }
    }

    func close(reason: PlankRelayCloseReason) {
        queue.async { [self] in closeOnQueue(reason: reason, sendEnd: true) }
    }

    func waitForClose() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if closeCompleted { continuation.resume() }
                else { closeWaiters.append(continuation) }
            }
        }
    }

    private func tick() {
        guard !closed else { return }
        let elapsed = DispatchTime.now().uptimeNanoseconds - lastReceive
        // A service name on another subnet can remain unresolved without ever
        // reaching the Relay. Move to the pinned address promptly in that case.
        let timeoutSeconds = sessionReady ? 3 : (connectionReady ? 10 : (bluetooth ? 50 : 4))
        guard elapsed < UInt64(timeoutSeconds) * 1_000_000_000 else {
            closeOnQueue(reason: .heartbeatTimeout)
            return
        }
        guard connectionReady else { return }
        guard sessionReady else { return }
        var payload = Data(repeating: 0, count: 16)
        let now = DispatchTime.now().uptimeNanoseconds / 1_000
        for index in 0..<8 {
            payload[index] = UInt8(truncatingIfNeeded: now >> (index * 8))
            payload[8 + index] = payload[index]
        }
        send(Message.ping, payload)
    }

    private func receiveNext() {
        guard !closed else { return }
        connection.receive { [weak self] data, complete, error in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                if let data, !data.isEmpty {
                    self.lastReceive = DispatchTime.now().uptimeNanoseconds
                    self.accept(data)
                }
                if error != nil { self.closeOnQueue(reason: .receiveError) }
                else if complete { self.closeOnQueue(reason: .relayClosedStream) }
                else { self.receiveNext() }
            }
        }
    }

    private func accept(_ data: Data) {
        guard let codec, !closed else { return }
        var offset = 0
        var response = [UInt8](repeating: 0, count: 256)
        var payload = [UInt8](repeating: 0, count: 8192)
        while offset < data.count && !closed {
            var consumed = 0, responseSize = 0, payloadSize = 0
            var type: UInt16 = 0
            let result = data.withUnsafeBytes { bytes in
                pltr_client_link_receive(
                    codec,
                    bytes.bindMemory(to: UInt8.self).baseAddress?.advanced(by: offset),
                    data.count - offset, &consumed,
                    &response, response.count, &responseSize,
                    &type, &payload, payload.count, &payloadSize
                )
            }
            guard result >= 0, consumed > 0 else { closeOnQueue(reason: .decodeFailed); return }
            offset += consumed
            if responseSize > 0 { write(Data(response.prefix(responseSize))) }
            guard result == 1, type != 0 else { continue }
            let body = Data(payload.prefix(payloadSize))
            switch type {
            case Message.status:
                guard payloadSize >= 8 else { closeOnQueue(reason: .invalidStatus); return }
                if !sessionReady {
                    let version = pltr_client_link_peer_version(codec).map {
                        String(cString: $0)
                    } ?? ""
                    preflight.relayAuthenticated(version: version)
                }
                preflight.observeRelayStatus(body)
                switch body[0] {
                case 0: reportState("Relay authenticated; waiting for the tablet.")
                case 1: reportState("Relay owns the tablet; attaching to the Host…")
                case 2: reportState("Tablet attachment in progress…")
                case 3: reportState("Wacom tablet attached to the Host.")
                case 4: reportState("Tablet suspended while PLANK is inactive.")
                default: reportState("Relay reported a tablet error (\(body[0])).")
                }
                if !sessionReady {
                    var ready = Data(repeating: 0, count: 5)
                    for i in 0..<4 {
                        ready[i] = UInt8(truncatingIfNeeded: hostFeatures >> (i * 8))
                    }
                    ready[4] = active ? 1 : 0
                    send(Message.sessionReady, ready)
                    sessionReady = true
                    onReady()
                    for frame in pendingHostFrames { send(Message.hostFrame, frame) }
                    pendingHostFrames.removeAll()
                    pendingHostBytes = 0
                }
            case Message.clientFrame:
                guard sessionReady, body.count > 8 else { closeOnQueue(reason: .invalidClientFrame); return }
                let frame = Data(body.dropFirst(8))
                let valid = frame.withUnsafeBytes { bytes in
                    plank_vision_raw_hid_frame_valid(
                        bytes.bindMemory(to: UInt8.self).baseAddress,
                        frame.count, PLANK_VISION_RAW_HID_TO_HOST
                    )
                }
                if valid == 1 {
                    let type = UInt16(frame[6]) | (UInt16(frame[7]) << 8)
                    let generation = UInt16(frame[10]) | (UInt16(frame[11]) << 8)
                    if type == 1 {
                        guard generation != 0, acceptGeneration(generation) else {
                            closeOnQueue(reason: .generationRejected)
                            return
                        }
                        attachedGeneration = generation
                    } else if (type == 9 || type == 13),
                              attachedGeneration == generation {
                        attachedGeneration = nil
                    }
                    deliverTabletFrame(frame)
                }
                else {
                    invalidTabletFrames += 1
                    if invalidTabletFrames >= 3 { closeOnQueue(reason: .invalidTabletFrames); return }
                }
            case Message.ping:
                guard body.count == 16 else { closeOnQueue(reason: .invalidPing); return }
                var pong = Data(body)
                pong.append(Data(repeating: 0, count: 16))
                let now = DispatchTime.now().uptimeNanoseconds / 1_000
                for i in 0..<8 {
                    let byte = UInt8(truncatingIfNeeded: now >> (i * 8))
                    pong[16 + i] = byte
                    pong[24 + i] = byte
                }
                send(Message.pong, pong)
            case Message.pong:
                guard body.count == 32 else { closeOnQueue(reason: .invalidPong); return }
            case Message.goodbye:
                closeOnQueue(reason: .relayGoodbye)
            default:
                closeOnQueue(reason: .unknownMessage)
            }
        }
    }

    private func send(_ type: UInt16, _ payload: Data) {
        guard !closed, let record = encode(type, payload) else {
            closeOnQueue(reason: .encodeFailed)
            return
        }
        write(record)
    }

    private func encode(_ type: UInt16, _ payload: Data) -> Data? {
        guard let codec else { return nil }
        var output = [UInt8](repeating: 0, count: 2 + 8192 + 16 + 16)
        var written = 0
        let result = payload.withUnsafeBytes { bytes in
            pltr_client_link_send(codec, type,
                                  bytes.bindMemory(to: UInt8.self).baseAddress,
                                  payload.count, &output, output.count, &written)
        }
        return result == 0 ? Data(output.prefix(written)) : nil
    }

    private func write(_ data: Data) {
        connection.send(data) { [weak self] error in
            guard let self, error != nil else { return }
            self.queue.async { self.closeOnQueue(reason: .writeFailed) }
        }
    }

    private func closeOnQueue(reason: PlankRelayCloseReason, sendEnd: Bool = false) {
        guard !closed else { return }
        // One line per link, recorded before teardown changes the state.
        NSLog("PLANK Relay link closed: reason=%@ sessionReady=%d active=%d attached=%d sinceReceive=%.0fms",
              reason.rawValue, sessionReady ? 1 : 0, active ? 1 : 0,
              attachedGeneration == nil ? 0 : 1,
              Double(DispatchTime.now().uptimeNanoseconds - lastReceive) / 1_000_000)
        if !sendEnd, let attachedGeneration {
            var suspend = [UInt8](repeating: 0, count: 20)
            if plank_vision_raw_hid_make_suspend(
                attachedGeneration, &suspend, suspend.count
            ) == 1 {
                deliverTabletFrame(Data(suspend))
            }
        }
        attachedGeneration = nil
        var finalRecord: Data?
        if sendEnd && sessionReady {
            if let suspend = encode(Message.sessionActive, Data([0])) {
                write(suspend)
            }
            finalRecord = encode(Message.sessionEnd, Data([1]))
        }
        closed = true
        preflight.beginRelayConnection()
        reportState("Relay disconnected.")
        heartbeat?.cancel()
        heartbeat = nil
        pendingHostFrames.removeAll()
        pendingHostBytes = 0
        if let codec { pltr_client_link_destroy(codec) }
        codec = nil
        if let finalRecord {
            connection.send(finalRecord) { [self] _ in
                queue.async { self.completeClose() }
            }
            queue.asyncAfter(deadline: .now() + .seconds(1)) { [self] in
                completeClose()
            }
        } else {
            completeClose()
        }
        if !sendEnd { onUnexpectedClose(reason) }
    }

    private func completeClose() {
        guard !closeCompleted else { return }
        closeCompleted = true
        connection.cancel()
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

/// Why the Client ended a Relay link or made it inactive. Diagnostic only;
/// the Relay wire protocol is unchanged.
enum PlankRelayCloseReason: String, Sendable {
    // Local decisions.
    case focusChange
    case userDisconnect
    case upstreamSessionFailure
    case sessionEnded
    case sessionReplaced
    case continueWithoutTablet
    // Relay link failures.
    case connectionEnded
    case handshakeStartFailed
    case heartbeatTimeout
    case receiveError
    case relayClosedStream
    case decodeFailed
    case invalidStatus
    case invalidClientFrame
    case generationRejected
    case invalidTabletFrames
    case invalidPing
    case invalidPong
    case relayGoodbye
    case unknownMessage
    case encodeFailed
    case writeFailed
    case invalidHostFrame
    case pendingHostOverflow
}

enum PlankRelayLiveError: Error {
    case invalidConfiguration
}

// The Host transport invokes its feature and control callbacks on a worker
// thread. This bridge owns exactly one Relay link for that Host stream.
final class PlankRelaySessionBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let retryQueue = DispatchQueue(label: "la.instinctual.plank.tablet-relay.retry")
    private let inputQueue: PlankInputQueue
    private let preflight: PlankWacomPreflight
    private let reportState: @Sendable (String) -> Void
    private let reportLink: @Sendable (PlankRelayLinkEvent) -> Void
    private var link: PlankRelayLiveLink?
    private var closingLink: PlankRelayLiveLink?
    private var linkID: UUID?
    /// The link whose authenticated handshake completed, if any.
    private var readyLinkID: UUID?
    private var lastGeneration: UInt16?
    private var retryCount = 0
    private var ended = false
    private var active = false
    private var lastCloseReason: PlankRelayCloseReason?
    private var lastCloseTime: UInt64 = 0

    init(inputQueue: PlankInputQueue,
         preflight: PlankWacomPreflight,
         reportLink: @escaping @Sendable (PlankRelayLinkEvent) -> Void = { _ in },
         reportState: @escaping @Sendable (String) -> Void) {
        self.inputQueue = inputQueue
        self.preflight = preflight
        self.reportLink = reportLink
        self.reportState = reportState
    }

    func startIfPaired(hostFeatures: UInt32) {
        lock.lock()
        let canStart = !ended && link == nil
        let preferManualFallback = retryCount % 2 == 1
        lock.unlock()
        guard canStart else { return }
        // The picker's selection decides, before anything else runs. Off
        // starts no preflight, no connection and no legacy fallback.
        let selection = PlankRelayKeys.relayRegistry().selection
        if selection == .off {
            reportState("Tablet Relay is off. Choose a Relay in Settings to draw with a tablet.")
            return
        }
        guard hostFeatures & PlankHostFeature.tabletRelayRequired ==
              PlankHostFeature.tabletRelayRequired else {
            reportState("Host does not advertise the required tablet controls.")
            return
        }
        // A registered Relay uses only its own pinned identity; each route
        // candidate is a hint that must still pass the authenticated drawing
        // handshake. Only an install still on its earlier address/service
        // pairing uses that legacy lookup.
        let resolved: (endpoint: NWEndpoint, account: String, routeLabel: String?)
        switch selection {
        case .off:
            return
        case .relay:
            guard let drawing = PlankRelayKeys.savedDrawingConnection(attempt: retryCount) else {
                reportState("The selected Relay is not approved on this headset. Open Relay Setup and choose Use in PLANK.")
                reportLink(.failed)
                return
            }
            resolved = (drawing.endpoint, drawing.account, drawing.routeLabel)
        case .earlierPairing:
            guard let saved = PlankRelayKeys.savedConnection(
                preferManualFallback: preferManualFallback
            ) else {
                reportState("Choose a Tablet Relay in Settings before connecting.")
                reportLink(.failed)
                return
            }
            resolved = (saved.endpoint, saved.account, nil)
        }
        guard let privateKey = try? PlankRelayKeys.clientPrivateKey(),
              let relayKey = try? PlankRelayKeys.read(resolved.account),
              relayKey.count == 32 else {
            reportState("The selected Relay's approval could not be loaded. Choose it again in Settings.")
            reportLink(.failed)
            return
        }
        let bluetooth = UserDefaults.standard.bool(forKey: "plank.vision.bluetoothDrawingTest")
        let identifier = UUID()
        let candidate = try? PlankRelayLiveLink(
            endpoint: resolved.endpoint, hostFeatures: hostFeatures, bluetooth: bluetooth,
            preflight: preflight,
            clientPrivateKey: privateKey, relayPublicKey: relayKey,
            deliverTabletFrame: { [weak self] frame in
                self?.deliverTabletFrame(frame)
            }, reportState: reportState,
            onReady: { [weak self] in self?.relayReady(identifier) },
            onUnexpectedClose: { [weak self] reason in
                self?.relayClosed(identifier, hostFeatures: hostFeatures, reason: reason)
            }, acceptGeneration: { [weak self] generation in
                self?.acceptGeneration(generation) ?? false
            }
        )
        guard let candidate else {
            reportState("The paired Relay identity could not be loaded.")
            reportLink(.failed)
            return
        }
        lock.lock()
        let shouldStart = !ended && link == nil
        if shouldStart {
            link = candidate
            linkID = identifier
        }
        let initialActive = active
        lock.unlock()
        if shouldStart {
            preflight.beginRelayConnection()
            if bluetooth {
                reportState("Finding the approved Relay for Bluetooth drawing…")
            } else if let routeLabel = resolved.routeLabel {
                // The actual route when it is known; never an inferred one.
                reportState("Connecting to the approved Wacom Relay over \(routeLabel)…")
            } else if case .hostPort = resolved.endpoint {
                reportState("Connecting to the paired Wacom Relay by address…")
            } else {
                reportState("Finding the paired Wacom Relay nearby…")
            }
            candidate.setActive(initialActive)
            candidate.start()
        } else {
            candidate.close(reason: .sessionReplaced)
        }
    }

    func forwardHostFrame(_ frame: Data) {
        lock.lock()
        let current = link
        lock.unlock()
        current?.forwardHostFrame(frame)
    }

    private func deliverTabletFrame(_ frame: Data) {
        lock.lock()
        let canDeliver = !ended
        let canForwardReports = active
        lock.unlock()
        guard canDeliver, frame.count >= 8 else { return }
        let type = UInt16(frame[6]) | UInt16(frame[7]) << 8
        // Attachment and control messages must pass to make the tablet ready.
        // Pen reports are user input and wait for the Host's attach result.
        guard type != 3 || (canForwardReports && preflight.snapshot.ready) else { return }
        inputQueue.append(.rawHid(frame))
    }

    func setActive(_ next: Bool, reason: PlankRelayCloseReason = .focusChange) {
        lock.lock()
        let changed = active != next
        active = next
        let current = link
        lock.unlock()
        if changed {
            NSLog("PLANK Relay activity: active=%d reason=%@ link=%d",
                  next ? 1 : 0, reason.rawValue, current == nil ? 0 : 1)
        }
        current?.setActive(next)
    }

    func close(reason: PlankRelayCloseReason) {
        lock.lock()
        let firstClose = !ended
        ended = true
        let current = link
        link = nil
        if let current { closingLink = current }
        if firstClose {
            lastCloseReason = reason
            lastCloseTime = DispatchTime.now().uptimeNanoseconds
        }
        lock.unlock()
        if firstClose {
            NSLog("PLANK Relay close requested: reason=%@ link=%d",
                  reason.rawValue, current == nil ? 0 : 1)
        }
        current?.close(reason: reason)
    }

    /// A bounded, content-free summary for the session failure snapshot.
    func diagnosticSummary() -> String {
        lock.lock()
        defer { lock.unlock() }
        let state = ended ? "ended" : link == nil ? "none" :
            readyLinkID == linkID ? "ready" : "connecting"
        var summary = "link=\(state) active=\(active) retries=\(retryCount)"
        if let lastGeneration { summary += " generation=\(lastGeneration)" }
        if let lastCloseReason {
            let age = Double(DispatchTime.now().uptimeNanoseconds - lastCloseTime) / 1_000_000_000
            summary += String(format: " lastClose=%@ %.1fs ago", lastCloseReason.rawValue, age)
        }
        return summary
    }

    func waitForClose() async {
        let current = lock.withLock { closingLink }
        await current?.waitForClose()
        lock.withLock {
            if closingLink === current { closingLink = nil }
        }
    }

    private func relayReady(_ identifier: UUID) {
        lock.lock()
        let current = !ended && linkID == identifier
        if current {
            retryCount = 0
            readyLinkID = identifier
        }
        lock.unlock()
        if current { reportLink(.ready) }
    }

    private func acceptGeneration(_ generation: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !ended, lastGeneration != generation else { return false }
        lastGeneration = generation
        return true
    }

    private func relayClosed(_ identifier: UUID, hostFeatures: UInt32,
                             reason: PlankRelayCloseReason) {
        lock.lock()
        guard !ended, linkID == identifier else {
            lock.unlock()
            return
        }
        lastCloseReason = reason
        lastCloseTime = DispatchTime.now().uptimeNanoseconds
        link = nil
        linkID = nil
        let wasReady = readyLinkID == identifier
        readyLinkID = nil
        let delay = min(1 << min(retryCount, 4), 16)
        retryCount += 1
        lock.unlock()
        reportLink(.closed(wasReady: wasReady))
        reportState("Tablet Relay disconnected; reconnecting…")
        retryQueue.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in
            self?.startIfPaired(hostFeatures: hostFeatures)
        }
    }
}
