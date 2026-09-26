import Combine
import Foundation
import Network
import Security

private enum PlankRelayError: LocalizedError {
    case invalidAddress
    case keychain(OSStatus)
    case random
    case crypto
    case connectionClosed
    case pairingRejected

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter a Relay address and port from 1 to 65535."
        case let .keychain(status): "Tablet key storage failed (\(status))."
        case .random: "Could not generate a secure tablet pairing code."
        case .crypto: "The tablet pairing exchange failed verification."
        case .connectionClosed: "The tablet Relay closed the connection."
        case .pairingRejected: "The tablet Relay rejected pairing. Check the ExpressKey order and try again."
        }
    }
}

enum PlankRelayKeys {
    static let service = "la.instinctual.PLANK.Vision.tabletRelay.v1"

    static func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw PlankRelayError.keychain(status)
        }
        return data
    }

    static func write(_ value: Data, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        }
        guard status == errSecSuccess else { throw PlankRelayError.keychain(status) }
    }

    static func clientPrivateKey() throws -> Data {
        if let existing = try read("client-private") {
            guard existing.count == 32 else { throw PlankRelayError.crypto }
            return existing
        }
        var key = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, key.count, &key) == errSecSuccess else {
            throw PlankRelayError.random
        }
        let data = Data(key)
        try write(data, account: "client-private")
        return data
    }

    static func relayAccount(address: String, port: UInt16) -> String {
        "relay-\(address):\(port)"
    }
}

private final class PlankConnectWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

private final class PlankRelayTCP: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "la.instinctual.plank.tablet-relay")

    init(address: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(address),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let waiter = PlankConnectWaiter(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: waiter.finish(.success(()))
                case let .failed(error): waiter.finish(.failure(error))
                case .cancelled: waiter.finish(.failure(PlankRelayError.connectionClosed))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
                data, _, isComplete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if isComplete { continuation.resume(throwing: PlankRelayError.connectionClosed) }
                else { continuation.resume(throwing: PlankRelayError.connectionClosed) }
            }
        }
    }

    func cancel() { connection.cancel() }
}

@MainActor
final class PlankRelayPairing: ObservableObject {
    @Published var address = "192.168.86.2"
    @Published var port = "28990"
    @Published private(set) var code: [UInt8]?
    @Published private(set) var status = "Pair a Wacom tablet connected to a local Relay."
    @Published private(set) var isPairing = false
    @Published private(set) var paired = false

    private var task: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        if let savedAddress = defaults.string(forKey: "plank.vision.relayAddress") {
            address = savedAddress
        }
        if let savedPort = UInt16(exactly: defaults.integer(forKey: "plank.vision.relayPort")),
           savedPort > 0 {
            port = String(savedPort)
            if let savedKey = try? PlankRelayKeys.read(
                PlankRelayKeys.relayAccount(address: address, port: savedPort)
            ), savedKey.count == 32 {
                paired = true
                status = "Paired Wacom Relay. Start a PLANK desktop session to use it."
            }
        }
    }

    func beginPairing() {
        guard !isPairing else { return }
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty, let number = UInt16(port), number != 0 else {
            status = PlankRelayError.invalidAddress.localizedDescription
            return
        }
        var random = [UInt8](repeating: 0, count: 5)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            status = PlankRelayError.random.localizedDescription
            return
        }
        let digits = random.map { UInt8(49 + ($0 & 7)) }
        code = digits.map { $0 - 48 }
        paired = false
        isPairing = true
        status = "Connecting to the Relay pairing window…"
        task = Task {
            do {
                try await pair(address: address, port: number, digits: digits)
                paired = true
                status = "Wacom Relay paired and its identity verified."
            } catch {
                status = Task.isCancelled ? "Tablet pairing canceled." : error.localizedDescription
            }
            code = nil
            isPairing = false
            task = nil
        }
    }

    func cancelPairing() { task?.cancel() }

    private func pair(address: String, port: UInt16, digits: [UInt8]) async throws {
        let privateKey = try PlankRelayKeys.clientPrivateKey()
        let name = Array("Apple Vision Pro".utf8)
        let pair: OpaquePointer? = privateKey.withUnsafeBytes { privateBytes in
            digits.withUnsafeBufferPointer { codeBytes in
                name.withUnsafeBufferPointer { nameBytes in
                    pltr_client_pair_create(
                        privateBytes.bindMemory(to: UInt8.self).baseAddress,
                        codeBytes.baseAddress, nameBytes.baseAddress,
                        nameBytes.count, 2
                    )
                }
            }
        }
        guard let pair else { throw PlankRelayError.crypto }
        defer { pltr_client_pair_destroy(pair) }
        let stream = PlankRelayTCP(address: address, port: port)
        defer { stream.cancel() }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(70))
            if !Task.isCancelled { stream.cancel() }
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await stream.connect()
            var outgoing = [UInt8](repeating: 0, count: 256)
            var written = 0
            guard pltr_client_pair_start(pair, &outgoing, outgoing.count, &written) == 0 else {
                throw PlankRelayError.crypto
            }
            try await stream.send(Data(outgoing.prefix(written)))
            status = "Press the five displayed ExpressKeys on the tablet."
            let deadline = ContinuousClock.now.advanced(by: .seconds(65))
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                let data = try await stream.receive()
                var offset = 0
                while offset < data.count {
                    var consumed = 0
                    var replySize = 0
                    var relayKey = [UInt8](repeating: 0, count: 32)
                    let result = data.withUnsafeBytes { bytes in
                        pltr_client_pair_receive(
                            pair,
                            bytes.bindMemory(to: UInt8.self).baseAddress?.advanced(by: offset),
                            data.count - offset, &consumed,
                            &outgoing, outgoing.count, &replySize, &relayKey
                        )
                    }
                    guard result >= 0, consumed > 0 else { throw PlankRelayError.pairingRejected }
                    offset += consumed
                    if replySize > 0 { try await stream.send(Data(outgoing.prefix(replySize))) }
                    if result == 2 {
                        try PlankRelayKeys.write(
                            Data(relayKey),
                            account: PlankRelayKeys.relayAccount(address: address, port: port)
                        )
                        UserDefaults.standard.set(address, forKey: "plank.vision.relayAddress")
                        UserDefaults.standard.set(Int(port), forKey: "plank.vision.relayPort")
                        return
                    }
                }
            }
            throw PlankRelayError.pairingRejected
        } onCancel: {
            stream.cancel()
        }
    }
}
