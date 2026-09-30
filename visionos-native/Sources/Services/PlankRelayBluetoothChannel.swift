import Foundation
@preconcurrency import CoreBluetooth

// An ordered byte stream over the Relay's LE Credit Based L2CAP channel.
// Discovery is limited to the saved peripheral ID and PLANK service. The
// PLTR Client still verifies the saved Relay key using link type 1 before
// treating any bytes from this channel as tablet input.
@MainActor
final class PlankRelayBluetoothChannel: NSObject,
    @preconcurrency CBCentralManagerDelegate,
    @preconcurrency CBPeripheralDelegate,
    @preconcurrency StreamDelegate {
    private static let service = CBUUID(string: "462F3A10-7A31-4AB3-9E7F-C36AF495ECF0")
    private static let psm = CBUUID(string: "ABDD3056-28FA-441D-A470-55A75A52553A")
    private let identifier: UUID
    private let onReady: () -> Void
    private let onBytes: (Data) -> Void
    private let onClose: () -> Void
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var input: InputStream?
    private var output: OutputStream?
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var outputOffset = 0
    private var started = false
    private var closed = false
    private var ready = false
    private var finishing = false
    private var deadline: Task<Void, Never>?

    init(identifier: UUID, onReady: @escaping () -> Void,
         onBytes: @escaping (Data) -> Void, onClose: @escaping () -> Void) {
        self.identifier = identifier
        self.onReady = onReady
        self.onBytes = onBytes
        self.onClose = onClose
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func start() {
        guard !started, !closed else { return }
        started = true
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.stop()
        }
        centralManagerDidUpdateState(central)
    }

    func send(_ bytes: Data) {
        guard !closed, !finishing, !bytes.isEmpty,
              pendingBytes + bytes.count <= 64 * 1024 else {
            stop()
            return
        }
        pending.append(bytes)
        pendingBytes += bytes.count
        flush()
    }

    func finish() {
        guard !closed else { return }
        finishing = true
        if pending.isEmpty { stop(); return }
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            self?.stop()
        }
    }

    func stop() {
        guard !closed else { return }
        closed = true
        deadline?.cancel()
        deadline = nil
        if central.state == .poweredOn {
            central.stopScan()
            if let peripheral { central.cancelPeripheralConnection(peripheral) }
        }
        for stream in [input, output] {
            stream?.remove(from: .main, forMode: .common)
            stream?.close()
            stream?.delegate = nil
        }
        input = nil
        output = nil
        pending.removeAll()
        pendingBytes = 0
        onClose()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard started, !closed else { return }
        switch central.state {
        case .poweredOn:
            if peripheral == nil {
                central.scanForPeripherals(withServices: [Self.service])
            }
        case .unknown, .resetting:
            break
        default:
            stop()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover device: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard !closed, peripheral == nil, device.identifier == identifier else { return }
        central.stopScan()
        peripheral = device
        device.delegate = self
        central.connect(device)
    }

    func centralManager(_ central: CBCentralManager, didConnect device: CBPeripheral) {
        guard !closed, device.identifier == identifier else { return }
        device.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect device: CBPeripheral,
                        error: Error?) { stop() }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral device: CBPeripheral,
                        error: Error?) { stop() }

    func peripheral(_ device: CBPeripheral, didDiscoverServices error: Error?) {
        guard !closed, error == nil,
              let service = device.services?.first(where: { $0.uuid == Self.service }) else {
            stop(); return
        }
        device.discoverCharacteristics([Self.psm], for: service)
    }

    func peripheral(_ device: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard !closed, error == nil,
              let characteristic = service.characteristics?.first(where: { $0.uuid == Self.psm }),
              characteristic.properties.contains(.read) else { stop(); return }
        device.readValue(for: characteristic)
    }

    func peripheral(_ device: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard !closed, error == nil, characteristic.uuid == Self.psm,
              let bytes = characteristic.value, bytes.count == 2 else { stop(); return }
        let psm = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        guard (0x80...0xff).contains(psm) else { stop(); return }
        device.openL2CAPChannel(psm)
    }

    func peripheral(_ device: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard !closed, error == nil, let channel else { stop(); return }
        input = channel.inputStream
        output = channel.outputStream
        guard let input, let output else { stop(); return }
        input.delegate = self
        output.delegate = self
        input.schedule(in: .main, forMode: .common)
        output.schedule(in: .main, forMode: .common)
        input.open()
        output.open()
        ready = true
        deadline?.cancel()
        deadline = nil
        onReady()
        flush()
    }

    func stream(_ stream: Stream, handle event: Stream.Event) {
        guard !closed else { return }
        switch event {
        case .hasBytesAvailable:
            guard let input, stream === input else { stop(); return }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = input.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { stop(); return }
            onBytes(Data(bytes.prefix(count)))
        case .hasSpaceAvailable:
            flush()
        case .errorOccurred, .endEncountered:
            stop()
        default:
            break
        }
    }

    private func flush() {
        guard ready, !closed, let output else { return }
        while output.hasSpaceAvailable, let first = pending.first {
            let count = first.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return output.write(base.advanced(by: outputOffset),
                                    maxLength: first.count - outputOffset)
            }
            if count < 0 { stop(); return }
            if count == 0 { return }
            outputOffset += count
            if outputOffset == first.count {
                pendingBytes -= first.count
                pending.removeFirst()
                outputOffset = 0
            }
        }
        if finishing && pending.isEmpty { stop() }
    }
}
