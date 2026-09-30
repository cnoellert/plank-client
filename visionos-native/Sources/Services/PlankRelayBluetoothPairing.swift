import Foundation
@preconcurrency import CoreBluetooth

// Bounded GATT byte transport for the Relay's existing CPace/Noise enrollment.
// Production pen reports use the separate LE CoC channel after pairing.
@MainActor
final class PlankRelayBluetoothPairing: NSObject,
    @preconcurrency CBCentralManagerDelegate,
    @preconcurrency CBPeripheralDelegate {
    private static let service = CBUUID(string: "462F3A10-7A31-4AB3-9E7F-C36AF495ECF0")
    private static let rxID = CBUUID(string: "462F3A11-7A31-4AB3-9E7F-C36AF495ECF0")
    private static let txID = CBUUID(string: "462F3A12-7A31-4AB3-9E7F-C36AF495ECF0")
    private let identifier: UUID
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var connecting: CheckedContinuation<Void, Error>?
    private var writing: CheckedContinuation<Void, Error>?
    private var reading: CheckedContinuation<Data, Error>?
    private var inbox: [Data] = []
    private var inboxBytes = 0
    private var started = false
    private var stopped = false

    init(identifier: UUID) {
        self.identifier = identifier
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func connect() async throws {
        if stopped { throw CancellationError() }
        try await withCheckedThrowingContinuation { continuation in
            connecting = continuation
            centralManagerDidUpdateState(central)
        }
    }

    func send(_ data: Data) async throws {
        guard !stopped, let peripheral, let rx, tx?.isNotifying == true else {
            throw CancellationError()
        }
        let maximum = min(512, peripheral.maximumWriteValueLength(for: .withResponse))
        guard maximum > 0 else { throw CancellationError() }
        for offset in stride(from: 0, to: data.count, by: maximum) {
            let fragment = data.subdata(in: offset..<min(offset + maximum, data.count))
            try await withCheckedThrowingContinuation { continuation in
                writing = continuation
                peripheral.writeValue(fragment, for: rx, type: .withResponse)
            }
        }
    }

    func receive() async throws -> Data {
        guard !stopped else { throw CancellationError() }
        if !inbox.isEmpty {
            let data = inbox.removeFirst()
            inboxBytes -= data.count
            return data
        }
        return try await withCheckedThrowingContinuation { reading = $0 }
    }

    func cancel() {
        guard !stopped else { return }
        stopped = true
        if central.state == .poweredOn {
            central.stopScan()
            if let peripheral { central.cancelPeripheralConnection(peripheral) }
        }
        let error = CancellationError()
        connecting?.resume(throwing: error); connecting = nil
        writing?.resume(throwing: error); writing = nil
        reading?.resume(throwing: error); reading = nil
        inbox.removeAll(); inboxBytes = 0
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard connecting != nil, !stopped else { return }
        if central.state == .poweredOn, !started {
            started = true
            central.scanForPeripherals(withServices: [Self.service])
        } else if central.state != .unknown && central.state != .resetting &&
                    central.state != .poweredOn { cancel() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover device: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !stopped, connecting != nil, peripheral == nil,
              device.identifier == identifier else { return }
        central.stopScan()
        peripheral = device
        device.delegate = self
        central.connect(device)
    }

    func centralManager(_ central: CBCentralManager, didConnect device: CBPeripheral) {
        guard !stopped else { return }
        device.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect device: CBPeripheral,
                        error: Error?) { cancel() }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral device: CBPeripheral,
                        error: Error?) { cancel() }

    func peripheral(_ device: CBPeripheral, didDiscoverServices error: Error?) {
        guard !stopped, error == nil,
              let service = device.services?.first(where: { $0.uuid == Self.service }) else {
            cancel(); return
        }
        device.discoverCharacteristics([Self.rxID, Self.txID], for: service)
    }

    func peripheral(_ device: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard !stopped, error == nil else { cancel(); return }
        rx = service.characteristics?.first { $0.uuid == Self.rxID }
        tx = service.characteristics?.first { $0.uuid == Self.txID }
        guard let rx, let tx, rx.properties.contains(.write),
              tx.properties.contains(.indicate) else { cancel(); return }
        device.setNotifyValue(true, for: tx)
    }

    func peripheral(_ device: CBPeripheral, didUpdateNotificationStateFor item: CBCharacteristic,
                    error: Error?) {
        guard !stopped, item.uuid == Self.txID else { return }
        guard error == nil, item.isNotifying else { cancel(); return }
        connecting?.resume(); connecting = nil
    }

    func peripheral(_ device: CBPeripheral, didWriteValueFor item: CBCharacteristic,
                    error: Error?) {
        guard !stopped, item.uuid == Self.rxID else { return }
        let waiter = writing; writing = nil
        if let error { waiter?.resume(throwing: error) }
        else { waiter?.resume() }
    }

    func peripheral(_ device: CBPeripheral, didUpdateValueFor item: CBCharacteristic,
                    error: Error?) {
        guard !stopped, item.uuid == Self.txID else { return }
        guard error == nil, let data = item.value, !data.isEmpty,
              data.count <= 512 else { cancel(); return }
        if let waiter = reading {
            reading = nil
            waiter.resume(returning: data)
        } else {
            guard inboxBytes + data.count <= 16 * 1024 else { cancel(); return }
            inbox.append(data)
            inboxBytes += data.count
        }
    }
}
