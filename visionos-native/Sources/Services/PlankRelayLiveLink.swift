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
    private let connection: NWConnection?
    private let bluetoothIdentifier: UUID?
    private var bluetooth: PlankRelayBluetoothChannel?
    private var bluetoothWriteTail: Task<Void, Never>?
    private var bluetoothQueuedBytes = 0
    private let hostFeatures: UInt32
    private let preflight: PlankWacomPreflight
    private let deliverTabletFrame: @Sendable (Data) -> Void
    private let reportState: @Sendable (String) -> Void
    private let onReady: @Sendable () -> Void
    private let onUnexpectedClose: @Sendable () -> Void
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

    init(endpoint: NWEndpoint?, bluetoothIdentifier: UUID? = nil,
         hostFeatures: UInt32,
         preflight: PlankWacomPreflight,
         clientPrivateKey: Data, relayPublicKey: Data,
         deliverTabletFrame: @escaping @Sendable (Data) -> Void,
         reportState: @escaping @Sendable (String) -> Void,
         onReady: @escaping @Sendable () -> Void,
         onUnexpectedClose: @escaping @Sendable () -> Void,
         acceptGeneration: @escaping @Sendable (UInt16) -> Bool) throws {
        guard clientPrivateKey.count == 32, relayPublicKey.count == 32,
              (endpoint != nil) != (bluetoothIdentifier != nil) else {
            throw PlankRelayLiveError.invalidConfiguration
        }
        let created = clientPrivateKey.withUnsafeBytes { clientBytes in
            relayPublicKey.withUnsafeBytes { relayBytes in
                pltr_client_link_create(
                    clientBytes.bindMemory(to: UInt8.self).baseAddress,
                    relayBytes.bindMemory(to: UInt8.self).baseAddress,
                    bluetoothIdentifier == nil ? 2 : 1
                )
            }
        }
        guard let created else { throw PlankRelayLiveError.invalidConfiguration }
        codec = created
        connection = endpoint.map { NWConnection(to: $0, using: .tcp) }
        self.bluetoothIdentifier = bluetoothIdentifier
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
            if let bluetoothIdentifier {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let channel = PlankRelayBluetoothChannel(identifier: bluetoothIdentifier,
                        onReady: { [weak self] in
                            guard let self else { return }
                            self.queue.async { self.transportReady() }
                        }, onBytes: { [weak self] bytes in
                            guard let self else { return }
                            self.queue.async {
                                guard !self.closed else { return }
                                self.lastReceive = DispatchTime.now().uptimeNanoseconds
                                self.accept(bytes)
                            }
                        }, onClose: { [weak self] in
                            guard let self else { return }
                            self.queue.async {
                                if self.closed { self.completeClose() }
                                else { self.closeOnQueue() }
                            }
                        })
                    self.queue.async { [self] in
                        guard !closed else {
                            Task { @MainActor in channel.stop() }
                            return
                        }
                        bluetooth = channel
                        Task { @MainActor in channel.start() }
                    }
                }
            } else if let connection {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.transportReady()
                    self.receiveNext()
                case .failed, .cancelled:
                    self.closeOnQueue()
                default:
                    break
                }
            }
            connection.start(queue: queue)
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }
            heartbeat = timer
            timer.resume()
        }
    }

    private func transportReady() {
        guard !closed else { return }
        connectionReady = true
        reportState("Relay connected; verifying its identity…")
        lastReceive = DispatchTime.now().uptimeNanoseconds
        var bytes = [UInt8](repeating: 0, count: 256)
        var written = 0
        guard let codec,
              pltr_client_link_start(codec, &bytes, bytes.count, &written) == 0 else {
            closeOnQueue()
            return
        }
        write(Data(bytes.prefix(written)))
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
            guard valid == 1 else { closeOnQueue(); return }
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
                    closeOnQueue()
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

    func close() { queue.async { [self] in closeOnQueue(sendEnd: true) } }

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
        // Bonjour discovery on another subnet must fail over to the pinned
        // address promptly. Bluetooth setup can take longer than TCP.
        let timeoutSeconds = sessionReady ? (bluetoothIdentifier == nil ? 3 : 6) :
            (bluetoothIdentifier == nil ? (connectionReady ? 10 : 4) : 20)
        guard elapsed < UInt64(timeoutSeconds) * 1_000_000_000 else {
            closeOnQueue()
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
        guard !closed, let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.lastReceive = DispatchTime.now().uptimeNanoseconds
                self.accept(data)
            }
            if error != nil || complete { self.closeOnQueue() }
            else { self.receiveNext() }
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
            guard result >= 0, consumed > 0 else { closeOnQueue(); return }
            offset += consumed
            if responseSize > 0 { write(Data(response.prefix(responseSize))) }
            guard result == 1, type != 0 else { continue }
            let body = Data(payload.prefix(payloadSize))
            switch type {
            case Message.status:
                guard payloadSize >= 8 else { closeOnQueue(); return }
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
                guard sessionReady, body.count > 8 else { closeOnQueue(); return }
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
                            closeOnQueue()
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
                    if invalidTabletFrames >= 3 { closeOnQueue(); return }
                }
            case Message.ping:
                guard body.count == 16 else { closeOnQueue(); return }
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
                guard body.count == 32 else { closeOnQueue(); return }
            case Message.goodbye:
                closeOnQueue()
            default:
                closeOnQueue()
            }
        }
    }

    private func send(_ type: UInt16, _ payload: Data) {
        guard !closed, let record = encode(type, payload) else {
            closeOnQueue()
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
        if let connection {
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.closeOnQueue() }
            })
        } else if let bluetooth {
            guard bluetoothQueuedBytes + data.count <= 64 * 1024 else {
                closeOnQueue()
                return
            }
            bluetoothQueuedBytes += data.count
            let previous = bluetoothWriteTail
            bluetoothWriteTail = Task { @MainActor [weak self] in
                await previous?.value
                bluetooth.send(data)
                guard let self else { return }
                self.queue.async { [self] in
                    bluetoothQueuedBytes -= data.count
                }
            }
        } else {
            closeOnQueue()
        }
    }

    private func closeOnQueue(sendEnd: Bool = false) {
        guard !closed else { return }
        if !sendEnd, let attachedGeneration {
            var suspend = [UInt8](repeating: 0, count: 20)
            if plank_vision_raw_hid_make_suspend(
                attachedGeneration, &suspend, suspend.count
            ) == 1 {
                deliverTabletFrame(Data(suspend))
            }
        }
        attachedGeneration = nil
        var inactiveRecord: Data?
        var finalRecord: Data?
        if sendEnd && sessionReady {
            inactiveRecord = encode(Message.sessionActive, Data([0]))
            finalRecord = encode(Message.sessionEnd, Data([1]))
        }
        closed = true
        preflight.beginRelayConnection()
        reportState("Relay disconnected.")
        heartbeat?.cancel()
        heartbeat = nil
        pendingHostFrames.removeAll()
        pendingHostBytes = 0
        connection?.stateUpdateHandler = nil
        if let codec { pltr_client_link_destroy(codec) }
        codec = nil
        if let connection {
            if let finalRecord {
                if let inactiveRecord {
                    connection.send(content: inactiveRecord, completion: .contentProcessed { _ in })
                }
                connection.send(content: finalRecord, completion: .contentProcessed { [self] _ in
                    completeClose()
                })
                queue.asyncAfter(deadline: .now() + .seconds(1)) { [self] in
                    completeClose()
                }
            } else {
                completeClose()
            }
        } else if let bluetooth {
            let previous = bluetoothWriteTail
            Task { @MainActor in
                await previous?.value
                if let inactiveRecord { bluetooth.send(inactiveRecord) }
                if let finalRecord {
                    bluetooth.send(finalRecord)
                    bluetooth.finish()
                } else {
                    bluetooth.stop()
                }
            }
            if !sendEnd { completeClose() }
            else {
                queue.asyncAfter(deadline: .now() + .seconds(2)) { [self] in
                    completeClose()
                }
            }
        } else {
            completeClose()
        }
        if !sendEnd { onUnexpectedClose() }
    }

    private func completeClose() {
        guard !closeCompleted else { return }
        closeCompleted = true
        connection?.cancel()
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
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
    private var link: PlankRelayLiveLink?
    private var closingLink: PlankRelayLiveLink?
    private var linkID: UUID?
    private var lastGeneration: UInt16?
    private var retryCount = 0
    private var ended = false
    private var active = false

    init(inputQueue: PlankInputQueue,
         preflight: PlankWacomPreflight,
         reportState: @escaping @Sendable (String) -> Void) {
        self.inputQueue = inputQueue
        self.preflight = preflight
        self.reportState = reportState
    }

    func startIfPaired(hostFeatures: UInt32) {
        lock.lock()
        let canStart = !ended && link == nil
        let preferManualFallback = retryCount % 2 == 1
        lock.unlock()
        guard canStart else { return }
        guard hostFeatures & PlankHostFeature.tabletRelayRequired ==
              PlankHostFeature.tabletRelayRequired else {
            reportState("Host does not advertise the required tablet controls.")
            return
        }
        guard let saved = PlankRelayKeys.savedLiveConnection(
                  preferManualFallback: preferManualFallback
              ),
              let privateKey = try? PlankRelayKeys.clientPrivateKey(),
              let relayKey = try? PlankRelayKeys.read(saved.account) else {
            reportState("Pair the Wacom Relay in Settings before connecting.")
            return
        }
        let identifier = UUID()
        let candidate = try? PlankRelayLiveLink(
            endpoint: saved.endpoint, bluetoothIdentifier: saved.bluetoothIdentifier,
            hostFeatures: hostFeatures,
            preflight: preflight,
            clientPrivateKey: privateKey, relayPublicKey: relayKey,
            deliverTabletFrame: { [weak self] frame in
                self?.deliverTabletFrame(frame)
            }, reportState: reportState,
            onReady: { [weak self] in self?.relayReady(identifier) },
            onUnexpectedClose: { [weak self] in
                self?.relayClosed(identifier, hostFeatures: hostFeatures)
            }, acceptGeneration: { [weak self] generation in
                self?.acceptGeneration(generation) ?? false
            }
        )
        guard let candidate else {
            reportState("The paired Relay identity could not be loaded.")
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
            if saved.bluetoothIdentifier != nil {
                reportState("Connecting to the paired Bluetooth Wacom Relay…")
            } else if case .hostPort = saved.endpoint {
                reportState("Connecting to the paired Wacom Relay by address…")
            } else {
                reportState("Finding the paired Wacom Relay nearby…")
            }
            candidate.setActive(initialActive)
            candidate.start()
        } else {
            candidate.close()
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

    func setActive(_ next: Bool) {
        lock.lock()
        active = next
        let current = link
        lock.unlock()
        current?.setActive(next)
    }

    func close() {
        lock.lock()
        ended = true
        let current = link
        link = nil
        if let current { closingLink = current }
        lock.unlock()
        current?.close()
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
        if !ended && linkID == identifier { retryCount = 0 }
        lock.unlock()
    }

    private func acceptGeneration(_ generation: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !ended, lastGeneration != generation else { return false }
        lastGeneration = generation
        return true
    }

    private func relayClosed(_ identifier: UUID, hostFeatures: UInt32) {
        lock.lock()
        guard !ended, linkID == identifier else {
            lock.unlock()
            return
        }
        link = nil
        linkID = nil
        let delay = min(1 << min(retryCount, 4), 16)
        retryCount += 1
        lock.unlock()
        reportState("Tablet Relay disconnected; reconnecting…")
        retryQueue.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in
            self?.startIfPaired(hostFeatures: hostFeatures)
        }
    }
}
