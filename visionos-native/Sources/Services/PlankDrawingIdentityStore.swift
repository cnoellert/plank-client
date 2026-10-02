import Foundation

// Identity-indexed drawing approvals and the additive, rollback-safe migration
// of contract §10.9. Foundation-only and dependency-injected so the standalone
// test harness can exercise it without a Keychain or a device.

/// A legacy, address- or service-keyed Keychain record. The stored value is a
/// pinned *public* drawing identity, never secret material.
struct PlankLegacyPinRecord: Equatable {
    let account: String
    /// 64 lowercase hexadecimal characters.
    let pinnedDrawingIdentity: String
}

/// The route state PLANK keeps in UserDefaults today (§1.7).
struct PlankLegacyRouteDefaults: Equatable {
    var mode: String?
    var serviceName: String?
    var serviceDomain: String?
    var address: String?
    var port: Int?

    static let empty = PlankLegacyRouteDefaults()
}

enum PlankDrawingMigrationOutcome: Equatable {
    /// Every legacy account that maps to this identity-indexed record holds the
    /// same key. Create the record; delete and overwrite nothing.
    case clean(identityAccount: String, drawingIdentity: String, legacyAccounts: [String])
    /// Legacy accounts that map to one record hold different keys. Surface an
    /// explicit conflict, write nothing, leave every record exactly as it was.
    case pinConflict(legacyAccounts: [String], drawingIdentities: [String])
    /// No legacy record matches the saved route state; nothing to re-index.
    case nothingToMigrate

    var identifier: String {
        switch self {
        case .clean: "migration.clean"
        case .pinConflict: "migration.pinConflict"
        case .nothingToMigrate: "migration.nothingToMigrate"
        }
    }
}

enum PlankDrawingIdentityAccounts {
    /// The existing Keychain service. Unchanged: migration is additive.
    static let keychainService = "la.instinctual.PLANK.Vision.tabletRelay.v1"
    static let identityPrefix = "relay-identity-v1:"
    static let clientPrivateAccount = "client-private"

    static func identityAccount(_ drawingIdentity: String) -> String {
        identityPrefix + drawingIdentity
    }

    static func isIdentityAccount(_ account: String) -> Bool {
        account.hasPrefix(identityPrefix)
    }

    static func drawingIdentity(fromAccount account: String) -> String? {
        guard account.hasPrefix(identityPrefix) else { return nil }
        return String(account.dropFirst(identityPrefix.count))
    }

    // The two legacy labels, reproduced here so the planner stays free of the
    // relay pairing unit (which links the relay C symbols).
    static func legacyAddressAccount(address: String, port: Int) -> String {
        "relay-\(address):\(port)"
    }

    static func legacyServiceAccount(name: String, domain: String) -> String {
        "relay-service-\(name).\(domain)"
    }
}

/// The pure part of §10.9. It decides, it never writes.
enum PlankDrawingMigrationPlanner {
    /// Legacy accounts that describe the one Relay the saved route state names.
    /// `useSavedPairing` and `useManualPairing` already copy a pinned key
    /// between these two labels, so they are exactly the accounts that must
    /// agree before a single identity-indexed record can represent them.
    static func candidateAccounts(for defaults: PlankLegacyRouteDefaults) -> [String] {
        var accounts: [String] = []
        if let name = defaults.serviceName, let domain = defaults.serviceDomain,
           !name.isEmpty, !domain.isEmpty {
            accounts.append(
                PlankDrawingIdentityAccounts.legacyServiceAccount(name: name, domain: domain)
            )
        }
        if let address = defaults.address, let port = defaults.port,
           !address.isEmpty, port > 0 {
            accounts.append(
                PlankDrawingIdentityAccounts.legacyAddressAccount(address: address, port: port)
            )
        }
        return accounts
    }

    static func plan(
        legacyAccounts: [PlankLegacyPinRecord],
        defaults: PlankLegacyRouteDefaults
    ) -> PlankDrawingMigrationOutcome {
        let candidates = candidateAccounts(for: defaults)
        let matching = legacyAccounts.filter { record in
            candidates.contains(record.account) &&
                PlankDrawingHandoffValidator.isCanonicalIdentity(record.pinnedDrawingIdentity)
        }
        guard !matching.isEmpty else { return .nothingToMigrate }
        let identities = matching.map(\.pinnedDrawingIdentity)
        let distinct = Set(identities)
        guard distinct.count == 1, let identity = distinct.first else {
            // Two different keys under two accounts means two different Relays
            // were approved. Stop and ask: never pick the newest, never prefer
            // the service over the address, never merge, never delete.
            return .pinConflict(
                legacyAccounts: matching.map(\.account),
                drawingIdentities: identities.sorted()
            )
        }
        return .clean(
            identityAccount: PlankDrawingIdentityAccounts.identityAccount(identity),
            drawingIdentity: identity,
            legacyAccounts: matching.map(\.account)
        )
    }
}

/// What a migration attempt actually did to the store.
enum PlankDrawingMigrationEffect: Equatable {
    case created(identityAccount: String)
    /// An identity-indexed record already existed. Never overwritten.
    case alreadyPresent(identityAccount: String)
    case blockedByConflict(legacyAccounts: [String])
    case nothingToDo
}

/// The thin, injectable Keychain face. Reads and writes 32-byte pinned public
/// identities only; the Client private key is never touched here, never
/// re-derived and never exported.
struct PlankDrawingIdentityStore {
    typealias Reader = (String) throws -> Data?
    typealias Writer = (Data, String) throws -> Void

    let read: Reader
    let write: Writer

    init(read: @escaping Reader, write: @escaping Writer) {
        self.read = read
        self.write = write
    }

    func hasApproval(for drawingIdentity: String) -> Bool {
        guard PlankDrawingHandoffValidator.isCanonicalIdentity(drawingIdentity) else {
            return false
        }
        let account = PlankDrawingIdentityAccounts.identityAccount(drawingIdentity)
        return (try? read(account))?.count == 32
    }

    /// Applies §10.9. Additive only: it writes at most the one identity-indexed
    /// record, never deletes a legacy record, never overwrites an existing
    /// approval, and writes nothing at all on a conflict.
    func apply(
        _ outcome: PlankDrawingMigrationOutcome
    ) throws -> PlankDrawingMigrationEffect {
        switch outcome {
        case .nothingToMigrate:
            return .nothingToDo
        case let .pinConflict(accounts, _):
            return .blockedByConflict(legacyAccounts: accounts)
        case let .clean(identityAccount, drawingIdentity, legacyAccounts):
            if let existing = try read(identityAccount), existing.count == 32 {
                return .alreadyPresent(identityAccount: identityAccount)
            }
            // Re-index a value that is already in the Keychain. Nothing is
            // derived, nothing is generated, and no legacy record is touched.
            var pin: Data?
            for account in legacyAccounts {
                if let value = try read(account), value.count == 32,
                   value.hexadecimalText == drawingIdentity {
                    pin = value
                    break
                }
            }
            guard let pin else { return .nothingToDo }
            try write(pin, identityAccount)
            return .created(identityAccount: identityAccount)
        }
    }

    /// Legacy route-keyed approvals, used only to tell an identity *change*
    /// from a first sighting. Never used to approve anything.
    static func routeApprovals(
        from legacyAccounts: [PlankLegacyPinRecord]
    ) -> [String: String] {
        var approvals: [String: String] = [:]
        for record in legacyAccounts {
            guard record.account.hasPrefix("relay-"),
                  !PlankDrawingIdentityAccounts.isIdentityAccount(record.account),
                  !record.account.hasPrefix("relay-service-") else { continue }
            let body = record.account.dropFirst("relay-".count)
            guard let separator = body.lastIndex(of: ":") else { continue }
            let address = String(body[body.startIndex..<separator])
            let port = String(body[body.index(after: separator)...])
            guard !address.isEmpty, Int(port) != nil else { continue }
            approvals["\(address):\(port)"] = record.pinnedDrawingIdentity
        }
        return approvals
    }
}

extension Data {
    init?(hexadecimal text: String) {
        let characters = [UInt8](text.utf8)
        guard characters.count % 2 == 0 else { return nil }
        var bytes = Data(capacity: characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let high = Data.hexDigit(characters[index]),
                  let low = Data.hexDigit(characters[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        self = bytes
    }

    var hexadecimalText: String {
        map { String(format: "%02x", $0) }.joined()
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
