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
    case connectionTimedOut
    case pairingRejected

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "Enter a Relay address and port from 1 to 65535."
        case let .keychain(status): "Relay trust storage failed (\(status))."
        case .random: "Could not generate a secure headset approval code."
        case .crypto: "The Relay approval exchange failed verification."
        case .connectionClosed: "The tablet Relay closed the connection."
        case .connectionTimedOut: "The Relay could not be reached. Choose Manual Address if it is on another subnet."
        case .pairingRejected: "The Relay rejected headset approval. Check the ExpressKey order and try again."
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

    static func savedConnection(preferManualFallback: Bool = false) ->
        (endpoint: NWEndpoint, account: String)? {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "plank.vision.relayMode") == "bonjour",
           let name = defaults.string(forKey: "plank.vision.relayServiceName"),
           let domain = defaults.string(forKey: "plank.vision.relayServiceDomain"),
           !name.isEmpty, !domain.isEmpty {
            let account = serviceAccount(name: name, domain: domain)
            // Discovery is local-subnet only. A previously verified address may
            // still be routable when the selected Bonjour service is not.
            // Keep the service's pinned key so a stale/reassigned IP cannot
            // silently change the Relay identity.
            if preferManualFallback,
               let address = defaults.string(forKey: "plank.vision.relayAddress"),
               let port = UInt16(exactly: defaults.integer(forKey: "plank.vision.relayPort")),
               !address.isEmpty, port > 0,
               let endpointPort = NWEndpoint.Port(rawValue: port) {
                return (.hostPort(host: NWEndpoint.Host(address), port: endpointPort),
                        account)
            }
            return (
                .service(name: name, type: "_plank-tablet._tcp", domain: domain,
                         interface: nil),
                account
            )
        }
        guard let address = defaults.string(forKey: "plank.vision.relayAddress"),
              let port = UInt16(exactly: defaults.integer(forKey: "plank.vision.relayPort")),
              !address.isEmpty, port > 0,
              let endpointPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return (.hostPort(host: NWEndpoint.Host(address), port: endpointPort),
                relayAccount(address: address, port: port))
    }

    static func hasSavedPairing() -> Bool {
        guard let saved = savedConnection() else { return false }
        return (try? read(saved.account))?.count == 32
    }
}

struct PlankDiscoveredRelay: Identifiable, Equatable {
    let name: String
    let domain: String
    var id: String { name + "|" + domain }
}

enum PlankRelaySetupMethod: String, CaseIterable, Identifiable {
    case nearby
    case manual

    var id: String { rawValue }
}

private final class PlankConnectWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func finish(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
        return pending != nil
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
            queue.asyncAfter(deadline: .now() + .seconds(6)) { [weak self] in
                if waiter.finish(.failure(PlankRelayError.connectionTimedOut)) {
                    self?.connection.cancel()
                }
            }
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
    @Published var setupMethod: PlankRelaySetupMethod = .manual
    @Published var selectedServiceID = ""
    @Published private(set) var discoveryStatus = "Searching the local network for Relays…"
    @Published private(set) var code: [UInt8]?
    @Published private(set) var status = ""
    @Published private(set) var isPairing = false
    @Published private(set) var paired = false

    private var task: Task<Void, Never>?
    private var browser: NWBrowser?
    private var discoveryGeneration = UUID()

    var hasSavedConnection: Bool {
        PlankRelayKeys.hasSavedPairing()
    }

    var selectedNearbyRelayAvailable: Bool {
        nearbyRelays.contains { $0.id == selectedServiceID }
    }

    var selectedConnectionIsActive: Bool {
        let defaults = UserDefaults.standard
        if setupMethod == .manual {
            return defaults.string(forKey: "plank.vision.relayMode") != "bonjour" &&
                address.trimmingCharacters(in: .whitespacesAndNewlines) ==
                    defaults.string(forKey: "plank.vision.relayAddress") &&
                UInt16(port).map { Int($0) } == defaults.object(forKey: "plank.vision.relayPort") as? Int
        }
        guard defaults.string(forKey: "plank.vision.relayMode") == "bonjour",
              let name = defaults.string(forKey: "plank.vision.relayServiceName"),
              let domain = defaults.string(forKey: "plank.vision.relayServiceDomain") else {
            return false
        }
        return selectedServiceID == PlankDiscoveredRelay(name: name, domain: domain).id
    }

    var activeConnectionDescription: String {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "plank.vision.relayMode") == "bonjour",
           let name = defaults.string(forKey: "plank.vision.relayServiceName") {
            return "Selected Relay: \(name)"
        }
        if let savedAddress = defaults.string(forKey: "plank.vision.relayAddress"),
           !savedAddress.isEmpty {
            let savedPort = defaults.integer(forKey: "plank.vision.relayPort")
            return "Selected Relay address: \(savedAddress):\(savedPort)"
        }
        return "No Relay selected"
    }

    var savedRelayNotNearby: PlankDiscoveredRelay? {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: "plank.vision.relayMode") == "bonjour",
              let name = defaults.string(forKey: "plank.vision.relayServiceName"),
              let domain = defaults.string(forKey: "plank.vision.relayServiceDomain") else {
            return nil
        }
        let saved = PlankDiscoveredRelay(name: name, domain: domain)
        return nearbyRelays.contains(saved) ? nil : saved
    }

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
            setupMethod = .nearby
            selectedServiceID = PlankDiscoveredRelay(name: name, domain: domain).id
        }
        refreshPairedState()
    }

    func startDiscovery() {
        guard browser == nil else { return }
        let generation = UUID()
        discoveryGeneration = generation
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: "_plank-tablet._tcp", domain: nil),
            using: parameters
        )
        discoveryStatus = "Searching the local network for Relays…"
        browser.stateUpdateHandler = { [weak self] state in
            let message: String
            switch state {
            case .ready:
                message = "Searching the local network for Relays…"
            case let .waiting(error), let .failed(error):
                message = "Local discovery unavailable: \(error.localizedDescription)"
            case .cancelled:
                message = "Local discovery stopped."
            default:
                return
            }
            Task { @MainActor in
                guard self?.discoveryGeneration == generation else { return }
                self?.discoveryStatus = message
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var seen = Set<String>()
            let found = results.compactMap { result -> PlankDiscoveredRelay? in
                guard case let .service(name, _, domain, _) = result.endpoint else {
                    return nil
                }
                let relay = PlankDiscoveredRelay(name: name, domain: domain)
                return seen.insert(relay.id).inserted ? relay : nil
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { @MainActor in
                guard self?.discoveryGeneration == generation else { return }
                self?.nearbyRelays = found
                if self?.setupMethod == .nearby,
                   self?.selectedServiceID.isEmpty == true,
                   found.count == 1 {
                    self?.selectedServiceID = found[0].id
                    self?.refreshPairedState()
                }
                self?.discoveryStatus = found.isEmpty ?
                    "No Relay found on this network. Manual address is available." :
                    "\(found.count) nearby Relay\(found.count == 1 ? "" : "s") found."
            }
        }
        self.browser = browser
        browser.start(queue: .global(qos: .userInitiated))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.discoveryGeneration == generation,
                  self.nearbyRelays.isEmpty,
                  self.discoveryStatus == "Searching the local network for Relays…" else {
                return
            }
            self.discoveryStatus = "No Relay found on this network. Manual address is available."
        }
    }

    func stopDiscovery() {
        discoveryGeneration = UUID()
        browser?.cancel()
        browser = nil
        nearbyRelays = []
    }

    func refreshPairedState() {
        let defaults = UserDefaults.standard
        let account: String?
        if setupMethod == .nearby {
            if let service = nearbyRelays.first(where: { $0.id == selectedServiceID }) {
                account = PlankRelayKeys.serviceAccount(name: service.name,
                                                         domain: service.domain)
            } else if !selectedServiceID.isEmpty,
                      defaults.string(forKey: "plank.vision.relayMode") == "bonjour",
                      selectedConnectionIsActive {
                account = PlankRelayKeys.savedConnection()?.account
            } else {
                account = nil
            }
        } else if let number = UInt16(port), number > 0 {
            account = PlankRelayKeys.relayAccount(address: address, port: number)
        } else {
            account = nil
        }
        paired = account.flatMap { try? PlankRelayKeys.read($0) }?.count == 32
        status = paired ? "" :
            (account == nil ? "Choose a Relay to approve this headset." :
             "Approve this headset for the selected Relay.")
    }

    func useSavedPairing() {
        guard !selectedServiceID.isEmpty,
              let service = nearbyRelays.first(where: { $0.id == selectedServiceID }) else {
            status = "Choose a nearby Relay first."
            return
        }
        do {
            let serviceAccount = PlankRelayKeys.serviceAccount(name: service.name,
                                                               domain: service.domain)
            if try PlankRelayKeys.read(serviceAccount)?.count != 32 {
                guard let manualPort = UInt16(port), manualPort > 0,
                      let knownKey = try PlankRelayKeys.read(
                          PlankRelayKeys.relayAccount(address: address, port: manualPort)
                      ), knownKey.count == 32 else {
                    status = "Approve this headset for the nearby Relay first."
                    return
                }
                try PlankRelayKeys.write(knownKey, account: serviceAccount)
            }
            UserDefaults.standard.set(service.name,
                                      forKey: "plank.vision.relayServiceName")
            UserDefaults.standard.set(service.domain,
                                      forKey: "plank.vision.relayServiceDomain")
            UserDefaults.standard.set("bonjour", forKey: "plank.vision.relayMode")
            paired = true
            status = "Relay selected. Its identity will be verified when you connect."
        } catch {
            status = error.localizedDescription
        }
    }

    func useManualPairing() {
        let manualAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !manualAddress.isEmpty, let manualPort = UInt16(port), manualPort > 0 else {
            status = "Enter a Relay address and valid port."
            return
        }
        let manualAccount = PlankRelayKeys.relayAccount(
            address: manualAddress, port: manualPort
        )
        do {
            var knownKey = try PlankRelayKeys.read(manualAccount)
            if knownKey == nil,
               let saved = PlankRelayKeys.savedConnection(),
               let existing = try PlankRelayKeys.read(saved.account),
               existing.count == 32 {
                // Only the authenticated link can accept this address. A
                // different Relay at the same IP will fail key verification.
                try PlankRelayKeys.write(existing, account: manualAccount)
                knownKey = existing
            }
            guard knownKey?.count == 32 else {
                status = "Approve this headset for that address first."
                return
            }
        } catch {
            status = error.localizedDescription
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
        if setupMethod == .nearby {
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
        let previouslyPaired = paired
        isPairing = true
        status = "Connecting to the Relay approval window…"
        task = Task {
            do {
                try await pair(endpoint: endpoint, account: account,
                               service: service, manual: manual, digits: digits)
                paired = true
                status = "Headset approved; Relay identity verified."
            } catch {
                paired = previouslyPaired
                if Task.isCancelled {
                    status = "Headset approval canceled. Existing trust is unchanged."
                } else if let networkError = error as? NWError,
                          case .posix(.ECONNRESET) = networkError {
                    status = "The Relay closed headset approval. Hold ExpressKeys 1 and 8 for five seconds before trying again. Existing trust is unchanged."
                } else {
                    status = error.localizedDescription
                }
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
