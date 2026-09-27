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

    static func serviceAccount(name: String, domain: String) -> String {
        "relay-service-\(name).\(domain)"
    }

    static func savedConnection() -> (endpoint: NWEndpoint, account: String)? {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "plank.vision.relayMode") == "bonjour",
           let name = defaults.string(forKey: "plank.vision.relayServiceName"),
           let domain = defaults.string(forKey: "plank.vision.relayServiceDomain"),
           !name.isEmpty, !domain.isEmpty {
            return (
                .service(name: name, type: "_plank-tablet._tcp", domain: domain,
                         interface: nil),
                serviceAccount(name: name, domain: domain)
            )
        }
        guard let address = defaults.string(forKey: "plank.vision.relayAddress"),
              let port = UInt16(exactly: defaults.integer(forKey: "plank.vision.relayPort")),
              !address.isEmpty, port > 0,
              let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return (.hostPort(host: NWEndpoint.Host(address), port: endpointPort),
                relayAccount(address: address, port: port))
    }
}

struct PlankDiscoveredRelay: Identifiable, Equatable {
    let name: String
    let domain: String
    var id: String { name + "|" + domain }
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

    init(endpoint: NWEndpoint) {
        connection = NWConnection(to: endpoint, using: .tcp)
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
    @Published var address = ""
    @Published var port = "28990"
    @Published private(set) var nearbyRelays: [PlankDiscoveredRelay] = []
    @Published var selectedServiceID = ""
    @Published private(set) var code: [UInt8]?
    @Published private(set) var status = "Pair a Wacom tablet connected to a local Relay."
    @Published private(set) var isPairing = false
    @Published private(set) var paired = false

    private var task: Task<Void, Never>?
    private var browser: NWBrowser?

    init() {
        let defaults = UserDefaults.standard
        if let savedAddress = defaults.string(forKey: "plank.vision.relayAddress") {
            address = savedAddress
        }
        if let savedPort = UInt16(exactly: defaults.integer(forKey: "plank.vision.relayPort")),
           savedPort > 0 {
            port = String(savedPort)
        }
        if defaults.string(forKey: "plank.vision.relayMode") == "bonjour",
           let name = defaults.string(forKey: "plank.vision.relayServiceName"),
           let domain = defaults.string(forKey: "plank.vision.relayServiceDomain") {
            selectedServiceID = PlankDiscoveredRelay(name: name, domain: domain).id
        }
        refreshPairedState()
    }

    func startDiscovery() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: "_plank-tablet._tcp", domain: nil),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> PlankDiscoveredRelay? in
                guard case let .service(name, _, domain, _) = result.endpoint else {
                    return nil
                }
                return PlankDiscoveredRelay(name: name, domain: domain)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor in self?.nearbyRelays = found }
        }
        self.browser = browser
        browser.start(queue: .global(qos: .userInitiated))
    }

    func stopDiscovery() {
        browser?.cancel()
        browser = nil
        nearbyRelays = []
    }

    func refreshPairedState() {
        let defaults = UserDefaults.standard
        let account: String?
        if !selectedServiceID.isEmpty,
           let service = nearbyRelays.first(where: { $0.id == selectedServiceID }) {
            account = PlankRelayKeys.serviceAccount(name: service.name,
                                                     domain: service.domain)
        } else if !selectedServiceID.isEmpty,
                  defaults.string(forKey: "plank.vision.relayMode") == "bonjour" {
            account = PlankRelayKeys.savedConnection()?.account
        } else if let number = UInt16(port), number > 0 {
            account = PlankRelayKeys.relayAccount(address: address, port: number)
        } else {
            account = nil
        }
        paired = account.flatMap { try? PlankRelayKeys.read($0) }?.count == 32
        if paired { status = "Paired Wacom Relay. Start a PLANK desktop session to use it." }
    }

    func useSavedPairing() {
        guard !selectedServiceID.isEmpty,
              let service = nearbyRelays.first(where: { $0.id == selectedServiceID }),
              let manualPort = UInt16(port), manualPort > 0,
              let knownKey = try? PlankRelayKeys.read(
                  PlankRelayKeys.relayAccount(address: address, port: manualPort)
              ), knownKey.count == 32 else {
            status = "Select a nearby Relay with an existing manual pairing."
            return
        }
        do {
            try PlankRelayKeys.write(
                knownKey,
                account: PlankRelayKeys.serviceAccount(name: service.name,
                                                       domain: service.domain)
            )
            UserDefaults.standard.set(service.name,
                                      forKey: "plank.vision.relayServiceName")
            UserDefaults.standard.set(service.domain,
                                      forKey: "plank.vision.relayServiceDomain")
            UserDefaults.standard.set("bonjour", forKey: "plank.vision.relayMode")
            paired = true
            status = "Saved pairing selected. The Relay identity will be verified when you connect."
        } catch {
            status = error.localizedDescription
        }
    }

    func useManualPairing() {
        let manualAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !manualAddress.isEmpty, let manualPort = UInt16(port), manualPort > 0,
              let knownKey = try? PlankRelayKeys.read(
                  PlankRelayKeys.relayAccount(address: manualAddress, port: manualPort)
              ), knownKey.count == 32 else {
            status = "No saved pairing for that address."
            return
        }
        UserDefaults.standard.set(manualAddress, forKey: "plank.vision.relayAddress")
        UserDefaults.standard.set(Int(manualPort), forKey: "plank.vision.relayPort")
        UserDefaults.standard.set("manual", forKey: "plank.vision.relayMode")
        paired = true
        status = "Manual Relay connection selected."
    }

    func beginPairing() {
        guard !isPairing else { return }
        let endpoint: NWEndpoint
        let account: String
        let service: PlankDiscoveredRelay?
        let manual: (address: String, port: UInt16)?
        if !selectedServiceID.isEmpty {
            guard let found = nearbyRelays.first(where: { $0.id == selectedServiceID }) else {
                status = "Relay not nearby. Wait for discovery or use its address."
                return
            }
            service = found
            manual = nil
            endpoint = .service(name: found.name, type: "_plank-tablet._tcp",
                                domain: found.domain, interface: nil)
            account = PlankRelayKeys.serviceAccount(name: found.name,
                                                     domain: found.domain)
        } else {
            service = nil
            let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty, let number = UInt16(port), number != 0,
                  let endpointPort = NWEndpoint.Port(rawValue: number) else {
                status = PlankRelayError.invalidAddress.localizedDescription
                return
            }
            endpoint = .hostPort(host: NWEndpoint.Host(address), port: endpointPort)
            account = PlankRelayKeys.relayAccount(address: address, port: number)
            manual = (address, number)
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
                try await pair(endpoint: endpoint, account: account,
                               service: service, manual: manual, digits: digits)
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

    private func pair(endpoint: NWEndpoint, account: String,
                      service: PlankDiscoveredRelay?,
                      manual: (address: String, port: UInt16)?,
                      digits: [UInt8]) async throws {
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
        let stream = PlankRelayTCP(endpoint: endpoint)
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
                            Data(relayKey), account: account
                        )
                        if let service {
                            UserDefaults.standard.set("bonjour", forKey: "plank.vision.relayMode")
                            UserDefaults.standard.set(service.name,
                                                      forKey: "plank.vision.relayServiceName")
                            UserDefaults.standard.set(service.domain,
                                                      forKey: "plank.vision.relayServiceDomain")
                        } else if let manual {
                            UserDefaults.standard.set("manual", forKey: "plank.vision.relayMode")
                            UserDefaults.standard.set(manual.address,
                                                      forKey: "plank.vision.relayAddress")
                            UserDefaults.standard.set(Int(manual.port),
                                                      forKey: "plank.vision.relayPort")
                        }
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
