// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
@preconcurrency import CoreBluetooth

// Setup supplies a peripheral route hint; discovery never selects another Relay. The raw Noise
// handshake must still authenticate the selected Relay's pinned public key.
enum PlankDrawingBluetoothError: Error, LocalizedError {
    case invalidState, timedOut, protocolError
    case network(String)
    var errorDescription: String? {
        switch self {
        case .invalidState: "Bluetooth drawing stream is not ready."
        case .timedOut: "Bluetooth drawing connection timed out."
        case .protocolError: "Bluetooth drawing protocol failed."
        case let .network(message): message
        }
    }
}

final class PlankRelayBluetoothTransport: PlankRelayByteTransport, @unchecked Sendable {
    @MainActor private var session: PlankDrawingBluetoothSession?
    private let outbox = PlankRelayWriteQueue()
    private let identifier: UUID
    init(identifier: UUID) { self.identifier = identifier }
    func start(queue: DispatchQueue, ready: @escaping @Sendable () -> Void,
               failed: @escaping @Sendable (any Error) -> Void) {
        Task { @MainActor in
            guard !outbox.isCancelled else { return }
            let candidate = PlankDrawingBluetoothSession(identifier: identifier,
                ready: { queue.async(execute: ready) },
                failed: { error in queue.async { failed(error) } })
            session = candidate
            candidate.start()
        }
    }
    func receive(_ completion: @escaping @Sendable (Data?, Bool, (any Error)?) -> Void) {
        Task { @MainActor in
            guard let stream = session?.stream else {
                completion(nil, true, PlankDrawingBluetoothError.invalidState); return
            }
            do { completion(try await stream.receive(), false, nil) }
            catch { completion(nil, true, error) }
        }
    }
    func send(_ data: Data, completion: @escaping @Sendable ((any Error)?) -> Void) {
        switch outbox.append(data, completion: completion) {
        case .rejected: completion(PlankDrawingBluetoothError.invalidState)
        case .queued: break
        case .startPump:
            Task { @MainActor in
                while let item = outbox.next() {
                    guard let session else { item.completion(PlankDrawingBluetoothError.invalidState); continue }
                    session.enqueue(item.data, completion: item.completion)
                }
            }
        }
    }
    func cancel() {
        for item in outbox.cancel() { item.completion(CancellationError()) }
        Task { @MainActor in session?.close(CancellationError()); session = nil }
    }
}

@MainActor
private final class PlankDrawingBluetoothSession: NSObject,
    @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private static let service = CBUUID(string: "462F3A10-7A31-4AB3-9E7F-C36AF495ECF0")
    private static let psm = CBUUID(string: "462F3A17-7A31-4AB3-9E7F-C36AF495ECF0")
    private let identifier: UUID
    private let ready: @Sendable () -> Void
    private let failed: @Sendable (any Error) -> Void
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var candidates: [UUID: CBPeripheral] = [:]
    private var deadline: Task<Void, Never>?
    private var scanDeadline: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var pending: [(Data, @Sendable ((any Error)?) -> Void)] = []
    private var pendingBytes = 0
    private var closed = false
    private var scanning = false
    private var channel: CBL2CAPChannel?
    fileprivate var stream: PlankDrawingL2CAPStream?

    init(identifier: UUID, ready: @escaping @Sendable () -> Void, failed: @escaping @Sendable (any Error) -> Void) {
        self.identifier = identifier; self.ready = ready; self.failed = failed
    }
    func start() {
        central = CBCentralManager(delegate: self, queue: .main)
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(PlankRelayConnectionTiming.bluetoothDiscoverySeconds)) } catch { return }
            self?.close(PlankDrawingBluetoothError.timedOut)
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard !closed else { return }
        if central.state == .poweredOn && !scanning && peripheral == nil {
            scanning = true
            // Alan's qualified Setup path handles a system connection that
            // outlives its L2CAP stream and suppresses fresh advertisements.
            // These peripherals are route hints; the saved Noise pin remains
            // the only authority. Still collect nearby advertising candidates
            // so this spike fails closed when the choice is ambiguous.
            for connected in central.retrievePeripherals(withIdentifiers: [identifier]) +
                central.retrieveConnectedPeripherals(withServices: [Self.service]) where connected.identifier == identifier {
                candidates[connected.identifier] = connected
            }
            NSLog("PLANK Bluetooth discovery: systemConnected=%d", candidates.count)
            central.scanForPeripherals(withServices: [Self.service])
            if !candidates.isEmpty { scheduleCandidateSelection() }
        } else if [.poweredOff, .unauthorized, .unsupported].contains(central.state) {
            close(PlankDrawingBluetoothError.network("Bluetooth is unavailable on this headset."))
        }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !closed, scanning, peripheral.identifier == identifier else { return }
        candidates[peripheral.identifier] = peripheral
        scheduleCandidateSelection()
    }
    private func scheduleCandidateSelection() {
        if scanDeadline == nil {
            scanDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, !closed else { return }
                self.central.stopScan(); scanning = false
                guard let found = candidates[identifier] else {
                    close(PlankDrawingBluetoothError.network("The registered Bluetooth Relay is not nearby. Open Relay Setup to refresh its connection.")); return
                }
                self.peripheral = found
                found.delegate = self
                NSLog("PLANK Bluetooth discovery: connecting candidate state=%d", found.state.rawValue)
                self.central.connect(found)
            }
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard !closed else { return }
        peripheral.discoverServices([Self.service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        close(error ?? PlankDrawingBluetoothError.network("Bluetooth Relay could not connect."))
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        close(error ?? PlankDrawingBluetoothError.network("Bluetooth Relay disconnected."))
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !closed else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            close(error ?? PlankDrawingBluetoothError.protocolError); return
        }
        peripheral.discoverCharacteristics([Self.psm], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard !closed else { return }
        guard error == nil, let characteristic = service.characteristics?.first(where: { $0.uuid == Self.psm }) else {
            close(error ?? PlankDrawingBluetoothError.protocolError); return
        }
        peripheral.readValue(for: characteristic)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !closed else { return }
        guard error == nil, characteristic.uuid == Self.psm,
              let value = characteristic.value, value.count == 3, value[0] == 1 else {
            close(error ?? PlankDrawingBluetoothError.protocolError); return
        }
        let psm = UInt16(value[1]) | UInt16(value[2]) << 8
        guard (0x80...0xff).contains(psm) else { close(PlankDrawingBluetoothError.protocolError); return }
        peripheral.openL2CAPChannel(psm)
    }
    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard !closed else { return }
        guard error == nil, let channel else { close(error ?? PlankDrawingBluetoothError.protocolError); return }
        self.channel = channel
        let stream = PlankDrawingL2CAPStream(input: channel.inputStream, output: channel.outputStream,
                                           onFailure: { [weak self] in self?.close($0) })
        self.stream = stream
        Task { [weak self] in
            do {
                try await stream.open()
                try await stream.send(Data("PLTRLEC1".utf8) + Data([3]))
                guard let self, !closed else { return }
                deadline?.cancel(); deadline = nil
                NSLog("PLANK Bluetooth raw drawing channel open; authenticating selected Relay identity")
                ready()
            } catch { self?.close(error) }
        }
    }
    func enqueue(_ data: Data, completion: @escaping @Sendable ((any Error)?) -> Void) {
        guard !closed, stream != nil, pending.count < 64, data.count <= 16384 - pendingBytes else {
            let error = PlankDrawingBluetoothError.network("Bluetooth drawing output exceeded its bounded buffer.")
            completion(error); close(error); return
        }
        pending.append((data, completion)); pendingBytes += data.count
        guard sendTask == nil else { return }
        sendTask = Task { [weak self] in
            guard let self else { return }
            while !pending.isEmpty && !closed {
                let item = pending.removeFirst()
                // Keep the in-flight bytes in the bound until the OS consumes them.
                do { try await stream!.send(item.0); pendingBytes -= item.0.count; item.1(nil) }
                catch { item.1(error); close(error); break }
            }
            sendTask = nil
        }
    }
    func close(_ error: any Error) {
        guard !closed else { return }
        closed = true
        deadline?.cancel(); scanDeadline?.cancel(); sendTask?.cancel()
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        stream?.close(error); stream = nil; channel = nil
        let waiters = pending; pending.removeAll(); pendingBytes = 0
        for (_, callback) in waiters { callback(error) }
        failed(error)
    }
}
