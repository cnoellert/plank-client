import Foundation

// The registered-Relay list behind PLANK's single Tablet Relay picker.
// Foundation-only and dependency-injected so the standalone tests can exercise
// it without a Keychain or a device. Approval material never lives here: an
// entry is a drawing identity, a display name and public route hints, and the
// pinned identity itself stays in the existing Keychain service.

/// Which Relay a desktop session draws with.
enum PlankRelaySelection: Equatable {
    /// An install that predates the picker and was paired by address or by
    /// Bonjour service. It keeps using that saved pairing until changed.
    case earlierPairing
    /// No Relay: no preflight, no connection and no legacy fallback. Approvals
    /// are kept so choosing a Relay again needs no re-approval.
    case off
    /// A registered Relay, by drawing identity.
    case relay(String)
}

struct PlankRegisteredRelay: Equatable {
    let drawingIdentity: String
    var name: String
    var routes: [PlankDrawingRoute]
}

struct PlankRelayRegistry: Equatable {
    private(set) var relays: [PlankRegisteredRelay] = []
    private(set) var selection: PlankRelaySelection = .off
    /// A picker change made during a desktop session, applied at disconnect.
    private(set) var pendingSelection: PlankRelaySelection?

    enum Request: Equatable {
        case applied
        case deferredUntilDisconnect
        case unchanged
        /// The identity is not registered; nothing changed.
        case unknownRelay
    }

    init(relays: [PlankRegisteredRelay] = [], selection: PlankRelaySelection = .off,
         pendingSelection: PlankRelaySelection? = nil) {
        self.relays = relays
        self.selection = selection
        self.pendingSelection = pendingSelection
    }

    /// Upsert by drawing identity. A repeated handoff refreshes the name and
    /// route hints of the one existing entry; it never creates a duplicate.
    mutating func register(_ route: PlankDrawingRouteSelection) {
        guard PlankDrawingHandoffValidator.isCanonicalIdentity(route.drawingIdentity),
              !route.routes.isEmpty else { return }
        if let index = relays.firstIndex(where: { $0.drawingIdentity == route.drawingIdentity }) {
            relays[index].name = route.displayName
            relays[index].routes = route.routes
        } else {
            relays.append(PlankRegisteredRelay(drawingIdentity: route.drawingIdentity,
                                               name: route.displayName, routes: route.routes))
        }
    }

    /// Never switches the Relay of a live session. The latest request wins and
    /// is applied by `desktopSessionEnded()`.
    mutating func request(_ choice: PlankRelaySelection,
                          desktopSessionActive: Bool) -> Request {
        if case let .relay(identity) = choice,
           !relays.contains(where: { $0.drawingIdentity == identity }) {
            return .unknownRelay
        }
        if desktopSessionActive {
            if choice == selection {
                pendingSelection = nil
                return .unchanged
            }
            pendingSelection = choice
            return .deferredUntilDisconnect
        }
        pendingSelection = nil
        guard choice != selection else { return .unchanged }
        selection = choice
        return .applied
    }

    /// Applies a deferred picker change. Returns true when the selection moved.
    @discardableResult
    mutating func desktopSessionEnded() -> Bool {
        guard let pending = pendingSelection else { return false }
        pendingSelection = nil
        return request(pending, desktopSessionActive: false) == .applied
    }

    var isOff: Bool { selection == .off }

    /// The earlier address/service pairing is transitional: it is offered only
    /// while it is the selection or the pending selection. Its credentials are
    /// kept, but once the user moves away it is no longer offered.
    var offersEarlierPairing: Bool {
        selection == .earlierPairing || pendingSelection == .earlierPairing
    }

    var activeRelay: PlankRegisteredRelay? {
        guard case let .relay(identity) = selection else { return nil }
        return relays.first { $0.drawingIdentity == identity }
    }

    /// The route candidates for the selected Relay. Only hints: the caller
    /// still completes the authenticated drawing handshake against the pin.
    var activeRouteSelection: PlankDrawingRouteSelection? {
        activeRelay.map {
            PlankDrawingRouteSelection(drawingIdentity: $0.drawingIdentity,
                                       displayName: $0.name, routes: $0.routes)
        }
    }

    /// Distinct identities with identical names stay distinct and readable,
    /// numbered in registration order. Keys are never shown.
    func displayName(for drawingIdentity: String) -> String? {
        guard let relay = relays.first(where: { $0.drawingIdentity == drawingIdentity }) else {
            return nil
        }
        let sameName = relays.filter { $0.name == relay.name }
        guard sameName.count > 1,
              let position = sameName.firstIndex(where: { $0.drawingIdentity == drawingIdentity })
        else { return relay.name }
        return position == 0 ? relay.name : "\(relay.name) (\(position + 1))"
    }

    /// First launch with the picker. Adopts the identity-indexed selection a
    /// handoff already made; otherwise keeps an earlier address/service
    /// pairing working. Identities are never guessed from names or addresses.
    static func migrated(existingSelection: PlankDrawingRouteSelection?,
                         hasEarlierPairing: Bool) -> PlankRelayRegistry {
        var registry = PlankRelayRegistry()
        if let existing = existingSelection {
            registry.register(existing)
            if registry.relays.contains(where: { $0.drawingIdentity == existing.drawingIdentity }) {
                registry.selection = .relay(existing.drawingIdentity)
            } else if hasEarlierPairing {
                registry.selection = .earlierPairing
            }
        } else if hasEarlierPairing {
            registry.selection = .earlierPairing
        }
        return registry
    }
}

/// Plist persistence for the registry. Malformed entries are dropped rather
/// than trusted; a missing value means "not migrated yet".
enum PlankRelayRegistryCodec {
    static let key = "plank.vision.relayRegistry"

    static func encode(_ registry: PlankRelayRegistry) -> [String: Any] {
        var encoded: [String: Any] = [
            "version": 1,
            "relays": registry.relays.map { relay -> [String: Any] in
                ["identity": relay.drawingIdentity, "name": relay.name,
                 "routes": relay.routes.map(encode)]
            },
            "selection": encode(registry.selection),
        ]
        if let pending = registry.pendingSelection {
            encoded["pending"] = encode(pending)
        }
        return encoded
    }

    static func decode(_ value: Any?) -> PlankRelayRegistry? {
        guard let object = value as? [String: Any], object["version"] as? Int == 1 else {
            return nil
        }
        var seen = Set<String>()
        let relays = ((object["relays"] as? [[String: Any]]) ?? []).compactMap {
            entry -> PlankRegisteredRelay? in
            guard let identity = entry["identity"] as? String,
                  PlankDrawingHandoffValidator.isCanonicalIdentity(identity),
                  seen.insert(identity).inserted,
                  let name = entry["name"] as? String, !name.isEmpty else { return nil }
            let routes = ((entry["routes"] as? [[String: Any]]) ?? []).compactMap(decodeRoute)
            guard !routes.isEmpty else { return nil }
            return PlankRegisteredRelay(drawingIdentity: identity, name: name, routes: routes)
        }
        let registered = Set(relays.map(\.drawingIdentity))
        func selection(_ raw: Any?) -> PlankRelaySelection? {
            guard let text = raw as? String else { return nil }
            switch text {
            case "off": return .off
            case "earlier-pairing": return .earlierPairing
            default: return registered.contains(text) ? .relay(text) : nil
            }
        }
        return PlankRelayRegistry(relays: relays,
                                  selection: selection(object["selection"]) ?? .off,
                                  pendingSelection: selection(object["pending"]))
    }

    private static func encode(_ selection: PlankRelaySelection) -> String {
        switch selection {
        case .off: "off"
        case .earlierPairing: "earlier-pairing"
        case let .relay(identity): identity
        }
    }

    static func encode(_ route: PlankDrawingRoute) -> [String: Any] {
        var encoded: [String: Any] = ["address": route.address, "port": Int(route.port)]
        if let interface = route.interface { encoded["interface"] = interface }
        if let kind = route.kind { encoded["kind"] = kind.rawValue }
        return encoded
    }

    static func decodeRoute(_ entry: [String: Any]) -> PlankDrawingRoute? {
        guard let address = entry["address"] as? String, !address.isEmpty,
              let port = entry["port"] as? Int,
              let number = UInt16(exactly: port), number > 0 else { return nil }
        return PlankDrawingRoute(address: address, port: number,
                                 interface: entry["interface"] as? String,
                                 kind: (entry["kind"] as? String).flatMap(PlankDrawingRouteKind.init))
    }
}

/// Load/save against an injected UserDefaults so tests use a private suite.
struct PlankRelayRegistryStore {
    let defaults: UserDefaults

    /// Loads the registry, migrating once from pre-picker state.
    func load(existingSelection: @autoclosure () -> PlankDrawingRouteSelection?,
              hasEarlierPairing: @autoclosure () -> Bool) -> PlankRelayRegistry {
        if let stored = PlankRelayRegistryCodec.decode(defaults.object(forKey: PlankRelayRegistryCodec.key)) {
            return stored
        }
        let migrated = PlankRelayRegistry.migrated(existingSelection: existingSelection(),
                                                   hasEarlierPairing: hasEarlierPairing())
        save(migrated)
        return migrated
    }

    func save(_ registry: PlankRelayRegistry) {
        defaults.set(PlankRelayRegistryCodec.encode(registry), forKey: PlankRelayRegistryCodec.key)
    }
}

// MARK: - Truthful Relay status (Settings)

/// What the session actually observed about the drawing link.
enum PlankRelayLinkObservation: Equatable {
    case none
    case connecting
    /// The authenticated drawing handshake completed.
    case connected
    /// The last attempt failed or timed out.
    case unavailable
}

struct PlankRelayStatus: Equatable {
    let title: String
    let detail: String

    static func make(selection: PlankRelaySelection, relayName: String?,
                     approvalPending: Bool, link: PlankRelayLinkObservation,
                     deferredName: String?) -> PlankRelayStatus {
        if approvalPending {
            return PlankRelayStatus(title: "Approval required",
                detail: "Finish the one-time drawing approval to register this Relay.")
        }
        let deferred = deferredName.map { " \($0) will be used after you disconnect." } ?? ""
        switch selection {
        case .off:
            return PlankRelayStatus(title: "Off",
                detail: "Desktop sessions start without a tablet Relay." + deferred)
        case .earlierPairing, .relay:
            let name = relayName ?? "The Relay"
            switch link {
            case .none:
                return PlankRelayStatus(title: "Configured",
                    detail: "\(name) connects when a desktop session starts." + deferred)
            case .connecting:
                return PlankRelayStatus(title: "Connecting",
                    detail: "Verifying \(name)'s drawing identity." + deferred)
            case .connected:
                return PlankRelayStatus(title: "Connected",
                    detail: "\(name) is connected for drawing." + deferred)
            case .unavailable:
                return PlankRelayStatus(title: "Unavailable",
                    detail: "\(name) could not be reached. Check that it is powered and on the network, or open Relay Setup to test it." + deferred)
            }
        }
    }
}

// MARK: - First-time drawing approval (transient registration sheet)

/// Holds one validated descriptor while the user completes PLANK's existing
/// physical drawing approval. It decides; the caller performs Keychain writes.
struct PlankRelayRegistration: Equatable {
    private(set) var pending: PlankDrawingHandoffDescriptor?
    private(set) var approving = false
    /// Cancel pressed while an approval was running. Any result that arrives
    /// afterwards, even a matching key, is discarded.
    private(set) var cancelRequested = false

    enum Outcome: Equatable {
        /// The Relay proved the descriptor's drawing identity. The caller may
        /// save that pin and must re-evaluate the descriptor before selecting.
        case approved(PlankDrawingHandoffDescriptor)
        /// The approving Relay presented a different key. Nothing is saved.
        case identityMismatch(name: String)
        /// Canceled or failed. Prior selection and approvals are untouched.
        case abandoned
    }

    /// Returns true when a registration sheet should be shown. A repeated link
    /// for the pending request, or any link while an approval is running,
    /// never opens a second sheet or a second approval connection.
    mutating func offer(_ descriptor: PlankDrawingHandoffDescriptor) -> Bool {
        if approving { return false }
        if pending?.requestID == descriptor.requestID { return false }
        pending = descriptor
        return true
    }

    /// Marks the approval connection as started for the pending descriptor.
    mutating func beginApproval() -> PlankDrawingHandoffDescriptor? {
        guard let pending, !approving else { return nil }
        approving = true
        return pending
    }

    /// `relayKey` is the key the approving Relay proved, or nil on cancel or
    /// failure. Only an exact identity match is accepted.
    mutating func finish(relayKey: String?) -> Outcome {
        defer { approving = false; pending = nil; cancelRequested = false }
        guard let descriptor = pending, !cancelRequested else { return .abandoned }
        guard let relayKey else { return .abandoned }
        guard relayKey == descriptor.drawingIdentity else {
            return .identityMismatch(name: descriptor.displayName)
        }
        return .approved(descriptor)
    }

    /// Dismissing the sheet. A running approval cannot be abandoned silently:
    /// it is marked canceled and its eventual result is discarded.
    mutating func cancel() {
        if approving {
            cancelRequested = true
        } else {
            pending = nil
        }
    }
}

// MARK: - Drawing link status from session events

/// Structured events from the Relay session bridge. Status never comes from
/// parsing user-facing strings.
enum PlankRelayLinkEvent: Equatable {
    /// A desktop session began; `configured` is false for Off or no Relay.
    case sessionStarted(configured: Bool)
    /// The authenticated drawing handshake completed.
    case ready
    /// The link closed unexpectedly. `wasReady` says whether it had connected;
    /// the bridge retries either way.
    case closed(wasReady: Bool)
    /// An attempt could not start or the session gave up waiting.
    case failed
    case sessionEnded
}

struct PlankRelayLinkTracker: Equatable {
    private(set) var observation: PlankRelayLinkObservation = .none

    mutating func apply(_ event: PlankRelayLinkEvent) {
        switch event {
        case let .sessionStarted(configured):
            observation = configured ? .connecting : .none
        case .ready:
            observation = .connected
        case let .closed(wasReady):
            // A drop from a working link is a reconnect in progress; an
            // attempt that never connected is a failure until one succeeds.
            observation = wasReady ? .connecting : .unavailable
        case .failed:
            observation = .unavailable
        case .sessionEnded:
            // A finished link is idle again; a failure stays reported.
            if observation != .unavailable { observation = .none }
        }
    }
}
