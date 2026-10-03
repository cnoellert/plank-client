import Combine
import Foundation
import Network
import Security

enum PlankRelayKeys {
    // Shared with PlankDrawingIdentityStore so the identity-indexed records
    // live in the same service as the legacy address- and service-keyed ones.
    static let service = PlankDrawingIdentityAccounts.keychainService

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

/// PLANK's existing physical drawing approval, run once for a validated
/// handoff descriptor from the transient registration sheet. It proves the
/// Relay's key and returns it; it never selects a Relay, never writes route
/// defaults and never stores a pin. The inbox decides what to keep.
@MainActor
final class PlankRelayDrawingApproval: ObservableObject {
    @Published private(set) var code: [UInt8]?
    @Published private(set) var status = ""
    @Published private(set) var isApproving = false

    private var task: Task<String?, Never>?

    /// Returns the 64-character drawing identity the Relay proved, or nil when
    /// canceled or failed. Routes are tried in descriptor order.
    func approve(_ descriptor: PlankDrawingHandoffDescriptor) async -> String? {
        guard !isApproving else { return nil }
        var random = [UInt8](repeating: 0, count: 5)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            status = PlankRelayError.random.localizedDescription
            return nil
        }
        let digits = random.map { UInt8(49 + ($0 & 7)) }
        code = digits.map { $0 - 48 }
        isApproving = true
        status = "Connecting to \(descriptor.displayName)…"
        let task = Task { [weak self] () -> String? in
            guard let self else { return nil }
            let lastError: Error
            do {
                return try await PlankRelayApprovalRoutes.approve(routes: descriptor.routes) { route in
                    guard let port = NWEndpoint.Port(rawValue: route.port) else {
                        throw PlankRelayError.connectionTimedOut
                    }
                    let key = try await self.pair(
                        endpoint: .hostPort(host: NWEndpoint.Host(route.address), port: port),
                        digits: digits)
                    return key.hexadecimalText
                }
            } catch {
                lastError = error
            }
            if Task.isCancelled {
                self.status = "Approval canceled. Existing approvals and the selected Relay are unchanged."
            } else if let networkError = lastError as? NWError,
                      case .posix(.ECONNRESET) = networkError {
                self.status = "The Relay closed the approval window. Hold ExpressKeys 1 and 8 for five seconds, then try again. Nothing was changed."
            } else {
                self.status = lastError.localizedDescription + " Nothing was changed."
            }
            return nil
        }
        self.task = task
        let key = await task.value
        code = nil
        isApproving = false
        self.task = nil
        return key
    }

    func cancel() { task?.cancel() }

    func reset() {
        guard !isApproving else { return }
        status = ""
        code = nil
    }

    private func pair(endpoint: NWEndpoint, digits: [UInt8]) async throws -> Data {
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
        return try await withTaskCancellationHandler {
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
                    if result == 2 { return Data(relayKey) }
                }
            }
            throw PlankRelayError.pairingRejected
        } onCancel: {
            stream.cancel()
        }
    }
}

// MARK: - Identity-indexed drawing connections (contract §10.9, §10.4)

enum PlankDrawingDefaultsKeys {
    static let identity = "plank.vision.drawingIdentity"
    static let displayName = "plank.vision.drawingDisplayName"
    static let routes = "plank.vision.drawingRoutes"
    static let migrationVersion = "plank.vision.drawingIdentityMigrationVersion"
    static let migrationConflict = "plank.vision.drawingIdentityMigrationConflict"
}

extension PlankRelayKeys {
    /// Every record in the existing service, so migration can re-index values
    /// that are already stored. There is no delete here by design.
    static func allRecords() throws -> [(account: String, value: Data)] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = items as? [[String: Any]] else {
            throw PlankRelayError.keychain(status)
        }
        return rows.compactMap { row in
            guard let account = row[kSecAttrAccount as String] as? String,
                  let value = row[kSecValueData as String] as? Data else { return nil }
            return (account, value)
        }
    }

    /// Legacy, address- or service-keyed pins only. The Client private key and
    /// the identity-indexed records are excluded.
    static func legacyPinRecords() -> [PlankLegacyPinRecord] {
        guard let records = try? allRecords() else { return [] }
        return records.compactMap { record in
            guard record.account != PlankDrawingIdentityAccounts.clientPrivateAccount,
                  !PlankDrawingIdentityAccounts.isIdentityAccount(record.account),
                  record.value.count == 32 else { return nil }
            return PlankLegacyPinRecord(account: record.account,
                                        pinnedDrawingIdentity: record.value.hexadecimalText)
        }
    }

    static var drawingIdentityStore: PlankDrawingIdentityStore {
        PlankDrawingIdentityStore(read: { try read($0) },
                                  write: { try write($0, account: $1) })
    }

    static func routeDefaults() -> PlankLegacyRouteDefaults {
        let defaults = UserDefaults.standard
        let port = defaults.integer(forKey: "plank.vision.relayPort")
        return PlankLegacyRouteDefaults(
            mode: defaults.string(forKey: "plank.vision.relayMode"),
            serviceName: defaults.string(forKey: "plank.vision.relayServiceName"),
            serviceDomain: defaults.string(forKey: "plank.vision.relayServiceDomain"),
            address: defaults.string(forKey: "plank.vision.relayAddress"),
            port: port > 0 ? port : nil
        )
    }

    /// Additive migration, run at launch and before a handoff is evaluated. It
    /// never deletes, never overwrites and writes nothing at all on a conflict.
    @discardableResult
    static func migrateDrawingIdentityIndex() -> PlankDrawingMigrationEffect {
        let outcome = PlankDrawingMigrationPlanner.plan(
            legacyAccounts: legacyPinRecords(), defaults: routeDefaults()
        )
        let effect = (try? drawingIdentityStore.apply(outcome)) ?? .nothingToDo
        let defaults = UserDefaults.standard
        switch effect {
        case let .blockedByConflict(accounts):
            // Surfaced for the user to resolve; the version marker stays unset
            // so the conflict is re-reported until they choose.
            defaults.set(accounts, forKey: PlankDrawingDefaultsKeys.migrationConflict)
        case .created, .alreadyPresent, .nothingToDo:
            defaults.removeObject(forKey: PlankDrawingDefaultsKeys.migrationConflict)
            defaults.set(1, forKey: PlankDrawingDefaultsKeys.migrationVersion)
        }
        return effect
    }

    static func migrationConflictAccounts() -> [String] {
        UserDefaults.standard.stringArray(
            forKey: PlankDrawingDefaultsKeys.migrationConflict
        ) ?? []
    }

    /// What PLANK already knows. No pin is ever written from here.
    static func drawingTrustEnvironment(
        desktopSessionActive: Bool
    ) -> PlankDrawingTrustEnvironment {
        let records = (try? allRecords()) ?? []
        var approved = Set<String>()
        for record in records where record.value.count == 32 {
            if let identity = PlankDrawingIdentityAccounts
                .drawingIdentity(fromAccount: record.account),
                identity == record.value.hexadecimalText {
                approved.insert(identity)
            }
        }
        return PlankDrawingTrustEnvironment(
            approvedDrawingIdentities: approved,
            routeApprovals: PlankDrawingIdentityStore
                .routeApprovals(from: legacyPinRecords()),
            desktopSessionActive: desktopSessionActive
        )
    }

    // MARK: Registered Relays and the selected one

    static var registryStore: PlankRelayRegistryStore {
        PlankRelayRegistryStore(defaults: .standard)
    }

    /// The registered-Relay list. The first call after upgrading adopts the
    /// handoff-made selection, or keeps an earlier address/service pairing.
    static func relayRegistry() -> PlankRelayRegistry {
        registryStore.load(existingSelection: legacyDrawingSelection(),
                           hasEarlierPairing: hasSavedPairing())
    }

    static func saveRelayRegistry(_ registry: PlankRelayRegistry) {
        registryStore.save(registry)
        // Mirror the selected Relay into the pre-picker keys so an earlier
        // build still draws with it after a rollback. Nothing is deleted.
        if let selection = registry.activeRouteSelection {
            mirrorDrawingSelection(selection)
        }
    }

    /// Upserts and selects a Relay whose drawing approval PLANK already holds.
    /// Callers only reach this when no desktop session is live.
    static func storeDrawingSelection(_ selection: PlankDrawingRouteSelection) {
        var registry = relayRegistry()
        registry.register(selection)
        _ = registry.request(.relay(selection.drawingIdentity), desktopSessionActive: false)
        saveRelayRegistry(registry)
    }

    /// True when a desktop session should wait for and start a Relay link.
    /// Off never does, so no preflight or legacy fallback runs.
    static func sessionRelayConfigured() -> Bool {
        switch relayRegistry().selection {
        case .off: false
        case .relay: savedDrawingConnection(attempt: 0) != nil
        case .earlierPairing: hasSavedPairing()
        }
    }

    // MARK: Accepted route candidates

    /// Routes are public endpoint hints and are stored in UserDefaults; the
    /// pinned identity stays in the Keychain and is never written from a link.
    private static func mirrorDrawingSelection(_ selection: PlankDrawingRouteSelection) {
        let defaults = UserDefaults.standard
        defaults.set(selection.drawingIdentity, forKey: PlankDrawingDefaultsKeys.identity)
        defaults.set(selection.displayName, forKey: PlankDrawingDefaultsKeys.displayName)
        defaults.set(selection.routes.map { route -> [String: Any] in
            var encoded: [String: Any] = ["address": route.address,
                                          "port": Int(route.port)]
            if let interface = route.interface { encoded["interface"] = interface }
            if let kind = route.kind { encoded["kind"] = kind.rawValue }
            return encoded
        }, forKey: PlankDrawingDefaultsKeys.routes)
    }

    /// The selected registered Relay, or nil for Off or an earlier pairing.
    static func savedDrawingSelection() -> PlankDrawingRouteSelection? {
        relayRegistry().activeRouteSelection
    }

    /// The pre-picker identity selection, read only for the one-time migration.
    private static func legacyDrawingSelection() -> PlankDrawingRouteSelection? {
        let defaults = UserDefaults.standard
        guard let identity = defaults.string(forKey: PlankDrawingDefaultsKeys.identity),
              PlankDrawingHandoffValidator.isCanonicalIdentity(identity),
              let encoded = defaults.array(forKey: PlankDrawingDefaultsKeys.routes)
                  as? [[String: Any]], !encoded.isEmpty else { return nil }
        let routes = encoded.compactMap { entry -> PlankDrawingRoute? in
            guard let address = entry["address"] as? String,
                  let port = entry["port"] as? Int,
                  let number = UInt16(exactly: port), number > 0 else { return nil }
            return PlankDrawingRoute(
                address: address, port: number,
                interface: entry["interface"] as? String,
                kind: (entry["kind"] as? String).flatMap(PlankDrawingRouteKind.init)
            )
        }
        guard !routes.isEmpty else { return nil }
        return PlankDrawingRouteSelection(
            drawingIdentity: identity,
            displayName: defaults.string(forKey: PlankDrawingDefaultsKeys.displayName) ?? "Relay",
            routes: routes
        )
    }

    /// The identity-indexed selection point. The route is only a hint: the
    /// caller still completes the authenticated drawing handshake against this
    /// pin before reporting a connection or forwarding any input.
    static func savedDrawingConnection(attempt: Int) ->
        (endpoint: NWEndpoint, account: String, routeLabel: String)? {
        guard let selection = savedDrawingSelection(),
              let route = selection.route(forAttempt: attempt),
              let port = NWEndpoint.Port(rawValue: route.port) else { return nil }
        let account = PlankDrawingIdentityAccounts
            .identityAccount(selection.drawingIdentity)
        guard (try? read(account))?.count == 32 else { return nil }
        return (.hostPort(host: NWEndpoint.Host(route.address), port: port),
                account, route.displayLabel)
    }
}

// MARK: - App-link inbox

enum PlankDrawingHandoffState: Equatable {
    case idle
    /// The pin is approved; the next desktop session verifies it and connects.
    case ready(name: String, routeLabel: String)
    /// Declined during an active desktop session, offered after disconnect.
    case deferredUntilDisconnect(name: String)
    /// Routed to PLANK's existing explicit physical approval flow.
    case needsApproval(name: String)
    case identityChanged(name: String)
    case migrationConflict(accounts: [String])
    /// A validation or trust refusal, carrying the contract identifier.
    case refused(reason: String)

    var message: String {
        switch self {
        case .idle:
            ""
        case let .ready(name, routeLabel):
            "\(name) is registered and selected (\(routeLabel)). Start a desktop session to connect."
        case let .deferredUntilDisconnect(name):
            "A desktop session is active, so \(name) was not switched in. It will be used after you disconnect."
        case let .needsApproval(name):
            "\(name) needs a one-time drawing approval on this headset before PLANK can use it."
        case let .identityChanged(name):
            "\(name) presented a different drawing identity. Nothing was saved and existing approvals were kept. Check the Relay in Relay Setup."
        case .migrationConflict:
            "Two saved Relay approvals hold different identities. Nothing was changed. Use Relay Setup's Use in PLANK for the Relay this headset should draw with."
        case let .refused(reason):
            "The Relay handoff link was refused (\(reason))."
        }
    }
}

/// Receives app links independently of which screen is showing, so a link that
/// arrives while any window is front is still handled exactly once.
@MainActor
final class PlankRelayHandoffInbox: ObservableObject {
    /// One inbox per process. The request deduplication set is deliberately
    /// process-lifetime and non-persistent (contract 10.5).
    static let shared = PlankRelayHandoffInbox()

    @Published private(set) var state: PlankDrawingHandoffState = .idle
    /// The validated descriptor awaiting the one-time drawing approval. The
    /// registration sheet is shown exactly while this is pending.
    @Published private(set) var registration = PlankRelayRegistration()
    /// A picker change waiting for the live desktop session to end.
    @Published private(set) var registry = PlankRelayKeys.relayRegistry()

    private var gate = PlankDrawingHandoffGate()
    private var deferredDescriptor: PlankDrawingHandoffDescriptor?

    init() {
        let conflicts = PlankRelayKeys.migrationConflictAccounts()
        if !conflicts.isEmpty { state = .migrationConflict(accounts: conflicts) }
    }

    func receive(_ url: URL, desktopSessionActive: Bool) {
        // Validation is pure: no Keychain, socket, Bonjour or DNS work happens
        // before the descriptor is accepted.
        let parse = PlankDrawingHandoffValidator.validateAppLink(url.absoluteString)
        switch parse {
        case let .rejected(reason):
            state = .refused(reason: reason)
        case let .accepted(descriptor):
            evaluate(descriptor, desktopSessionActive: desktopSessionActive)
        }
    }

    /// Called when a desktop session ends, to honour the offer made in
    /// `deferredUntilDisconnect` without replaying anything.
    func desktopSessionEnded() {
        var current = PlankRelayKeys.relayRegistry()
        if current.desktopSessionEnded() { PlankRelayKeys.saveRelayRegistry(current) }
        registry = current
        guard let descriptor = deferredDescriptor else { return }
        deferredDescriptor = nil
        evaluate(descriptor, desktopSessionActive: false)
    }

    /// The picker. A change during a desktop session waits for disconnect.
    func select(_ choice: PlankRelaySelection, desktopSessionActive: Bool) {
        var current = PlankRelayKeys.relayRegistry()
        _ = current.request(choice, desktopSessionActive: desktopSessionActive)
        PlankRelayKeys.saveRelayRegistry(current)
        registry = current
    }

    func reloadRegistry() { registry = PlankRelayKeys.relayRegistry() }

    // MARK: One-time registration approval

    /// Runs PLANK's existing physical drawing approval for the pending
    /// descriptor. Only the exact drawing identity is saved, under its
    /// identity-indexed account; the descriptor is then re-evaluated by the
    /// same gate before the Relay is registered and selected.
    func approvePendingRegistration(with approval: PlankRelayDrawingApproval,
                                    desktopSessionActive: @escaping () -> Bool) async {
        guard let descriptor = registration.beginApproval() else { return }
        let relayKey = await approval.approve(descriptor)
        // Cancel wins over a late result: a key that arrives after the user
        // canceled is discarded before any Keychain write or registration.
        if registration.cancelRequested {
            _ = registration.finish(relayKey: nil)
            state = .idle
            return
        }
        var savedKey = relayKey
        if let relayKey, relayKey == descriptor.drawingIdentity {
            let account = PlankDrawingIdentityAccounts.identityAccount(relayKey)
            do {
                guard let pin = Data(hexadecimal: relayKey), pin.count == 32 else {
                    throw CancellationError()
                }
                try PlankRelayKeys.write(pin, account: account)
            } catch {
                savedKey = nil  // Nothing was saved; treat as a failed approval.
            }
        }
        switch registration.finish(relayKey: savedKey) {
        case let .approved(approved):
            evaluate(approved, desktopSessionActive: desktopSessionActive())
        case let .identityMismatch(name):
            state = .identityChanged(name: name)
        case .abandoned:
            // Keep the sheet open with the failure so the user can retry the
            // same link; nothing was saved or selected.
            _ = registration.offer(descriptor)
            state = .needsApproval(name: descriptor.displayName)
        }
    }

    /// Closes the registration sheet. A running approval is canceled first;
    /// the prior selection and every approval are left exactly as they were.
    func cancelRegistration(_ approval: PlankRelayDrawingApproval) {
        if registration.approving {
            registration.cancel()
            approval.cancel()
            return
        }
        registration.cancel()
        approval.reset()
        if case .needsApproval = state { state = .idle }
    }

    func dismiss() {
        if case .migrationConflict = state { return }
        state = .idle
    }

    private func evaluate(_ descriptor: PlankDrawingHandoffDescriptor,
                          desktopSessionActive: Bool) {
        if case let .blockedByConflict(accounts) =
            PlankRelayKeys.migrateDrawingIdentityIndex() {
            state = .migrationConflict(accounts: accounts)
            return
        }
        let environment = PlankRelayKeys.drawingTrustEnvironment(
            desktopSessionActive: desktopSessionActive
        )
        switch gate.evaluate(descriptor, environment: environment) {
        case let .verifyThenConnect(selection):
            // Register (upsert by identity) and select this exact Relay.
            PlankRelayKeys.storeDrawingSelection(selection)
            registry = PlankRelayKeys.relayRegistry()
            state = .ready(name: registry.displayName(for: selection.drawingIdentity)
                               ?? selection.displayName,
                           routeLabel: selection.routeLabel)
        case .duplicateRequest:
            // Raise the existing presentation; no second confirmation and no
            // second connection attempt. A repeat is never proof of trust.
            break
        case .desktopSessionActive:
            deferredDescriptor = descriptor
            state = .deferredUntilDisconnect(name: descriptor.displayName)
        case let .drawingIdentityMismatch(saved, received):
            // The pin is not replaced and the approval is not deleted.
            _ = (saved, received)
            state = .identityChanged(name: descriptor.displayName)
        case .needsExplicitApproval:
            // One transient registration sheet per link; a duplicate link or a
            // link during a running approval never opens a second one.
            if registration.offer(descriptor) {
                state = .needsApproval(name: descriptor.displayName)
            }
        }
    }
}
