import CryptoKit
import Foundation

// Harness 2: the additive, rollback-safe Keychain migration of contract §10.9,
// driven by the shared migration fixtures.
//
//   swiftc -Onone -DPLANK_TABLET_RELAY -parse-as-library \
//       visionos-native/Sources/Models/PlankDrawingHandoff.swift \
//       visionos-native/Sources/Services/PlankDrawingIdentityStore.swift \
//       visionos-native/Tests/PlankDrawingMigrationTests.swift -o <out> && <out>
//
// `precondition`, never bare `assert`: -O strips `assert` entirely.

private let fixtureRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/plank-drawing-handoff-v1")

private let manifestSHA256 =
    "dd1125d8257f11431671fe116335c4e3c798c157207bdd576f3c44e724e95954"
private let contractRevision = "plank-drawing-handoff-v1+r3"

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// A recording stand-in for the Keychain. There is no delete operation at all,
/// which is how "migration never deletes" is enforced structurally.
private final class RecordingStore {
    private(set) var values: [String: Data]
    private(set) var writes: [String] = []
    private(set) var reads: [String] = []

    init(_ values: [String: Data]) { self.values = values }

    func read(_ account: String) throws -> Data? {
        reads.append(account)
        return values[account]
    }

    func write(_ value: Data, _ account: String) throws {
        writes.append(account)
        values[account] = value
    }

    var store: PlankDrawingIdentityStore {
        PlankDrawingIdentityStore(read: read, write: write)
    }
}

private struct MigrationFixture {
    let keychainService: String
    let legacyAccounts: [PlankLegacyPinRecord]
    let defaults: PlankLegacyRouteDefaults
    let descriptorDrawingIdentity: String
    let expectedIdentityIndexedAccount: String?
}

@main
struct PlankDrawingMigrationTests {
    static func main() {
        let manifestData = try! Data(
            contentsOf: fixtureRoot.appendingPathComponent("MANIFEST.json")
        )
        precondition(sha256Hex(manifestData) == manifestSHA256,
                     "MANIFEST.json SHA-256 drift")
        let manifest = try! JSONSerialization.jsonObject(with: manifestData)
            as! [String: Any]
        precondition(manifest["revision"] as? String == contractRevision)
        let schema = manifest["migrationSchema"] as! [String: Any]
        precondition(schema["legacyAccounts[]"] as? [String] ==
            ["account", "pinnedDrawingIdentity"],
            "the migration schema member names changed")
        let outcomes = manifest["migrationOutcomes"] as! [String: Any]
        precondition(outcomes["migration.clean"] != nil)
        precondition(outcomes["migration.pinConflict"] != nil)

        let files = manifest["files"] as! [String: [String: Any]]
        var covered = 0
        for name in files.keys.sorted() where name.hasPrefix("migration/") {
            let meta = files[name]!
            precondition(meta["entryPoint"] as? String == "migration", name)
            let expect = meta["expect"] as! String
            let fixture = load(name, meta)
            precondition(fixture.keychainService ==
                PlankDrawingIdentityAccounts.keychainService,
                "\(name) names a different Keychain service")

            let outcome = PlankDrawingMigrationPlanner.plan(
                legacyAccounts: fixture.legacyAccounts, defaults: fixture.defaults
            )
            precondition(outcome.identifier == expect,
                         "\(name) expected \(expect), got \(outcome.identifier)")

            switch outcome {
            case let .clean(identityAccount, drawingIdentity, legacy):
                precondition(identityAccount == fixture.expectedIdentityIndexedAccount,
                             "\(name) identity account mismatch: \(identityAccount)")
                precondition(drawingIdentity == fixture.descriptorDrawingIdentity,
                             "\(name) the migrated pin is not the arriving identity")
                precondition(!legacy.isEmpty)
                verifyCleanIsAdditive(name, fixture, identityAccount, drawingIdentity, legacy)
            case let .pinConflict(accounts, identities):
                precondition(fixture.expectedIdentityIndexedAccount == nil,
                             "\(name) must not name an identity record")
                precondition(accounts.count >= 2, "\(name) needs two accounts to conflict")
                precondition(identities.count >= 2)
                precondition(Set(identities).count >= 2, "\(name) keys are not divergent")
                verifyConflictWritesNothing(name, fixture, outcome)
            case .nothingToMigrate:
                preconditionFailure("\(name) produced no migration")
            }
            covered += 1
        }
        precondition(covered == 3, "migration fixtures not covered: \(covered)")

        verifyNoCandidateMeansNoMigration()
        verifyExistingApprovalIsNeverSuperseded()
        verifyLegacyRouteApprovalsAreAddressKeyedOnly()
        verifyIdentityAccountRoundTrip()

        print("PlankDrawingMigrationTests: \(covered) migration fixtures verified")
    }

    // MARK: Fixture loading

    private static func load(_ name: String, _ meta: [String: Any]) -> MigrationFixture {
        let url = fixtureRoot.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            preconditionFailure("missing fixture \(name)")
        }
        precondition(sha256Hex(data) == meta["sha256"] as! String,
                     "fixture hash drift: \(name)")
        if let bytes = meta["bytes"] as? Int {
            precondition(data.count == bytes, "fixture byte count drift: \(name)")
        }
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let accounts = (object["legacyAccounts"] as! [[String: Any]]).map {
            PlankLegacyPinRecord(
                account: $0["account"] as! String,
                // r3 renamed this member: it is a pinned public identity.
                pinnedDrawingIdentity: $0["pinnedDrawingIdentity"] as! String
            )
        }
        let defaultsObject = object["defaults"] as! [String: Any]
        let defaults = PlankLegacyRouteDefaults(
            mode: defaultsObject["plank.vision.relayMode"] as? String,
            serviceName: defaultsObject["plank.vision.relayServiceName"] as? String,
            serviceDomain: defaultsObject["plank.vision.relayServiceDomain"] as? String,
            address: defaultsObject["plank.vision.relayAddress"] as? String,
            port: defaultsObject["plank.vision.relayPort"] as? Int
        )
        let descriptor = object["descriptor"] as! [String: Any]
        return MigrationFixture(
            keychainService: object["keychainService"] as! String,
            legacyAccounts: accounts,
            defaults: defaults,
            descriptorDrawingIdentity: descriptor["drawingIdentity"] as! String,
            expectedIdentityIndexedAccount:
                object["expectedIdentityIndexedAccount"] as? String
        )
    }

    private static func seeded(_ fixture: MigrationFixture) -> RecordingStore {
        var values: [String: Data] = [:]
        for record in fixture.legacyAccounts {
            values[record.account] = Data(hexadecimal: record.pinnedDrawingIdentity)!
        }
        // The Client private key is device-local and must never be read,
        // re-derived or exported by migration.
        values[PlankDrawingIdentityAccounts.clientPrivateAccount] =
            Data(repeating: 0x5A, count: 32)
        return RecordingStore(values)
    }

    // MARK: Requirements

    private static func verifyCleanIsAdditive(
        _ name: String, _ fixture: MigrationFixture,
        _ identityAccount: String, _ drawingIdentity: String, _ legacy: [String]
    ) {
        let recorder = seeded(fixture)
        let before = recorder.values
        let effect = try! recorder.store.apply(
            PlankDrawingMigrationPlanner.plan(
                legacyAccounts: fixture.legacyAccounts, defaults: fixture.defaults
            )
        )
        precondition(effect == .created(identityAccount: identityAccount), "\(name)")
        precondition(recorder.writes == [identityAccount],
                     "\(name) wrote more than the identity record: \(recorder.writes)")
        precondition(recorder.values[identityAccount] ==
            Data(hexadecimal: drawingIdentity),
            "\(name) re-indexed the wrong bytes")
        // Every legacy record is still present, unchanged and readable, so a
        // rollback to the previous Client build still finds its pins.
        for account in before.keys {
            precondition(recorder.values[account] == before[account],
                         "\(name) altered \(account)")
        }
        precondition(recorder.values.count == before.count + 1,
                     "\(name) changed the record count beyond one addition")
        precondition(!recorder.reads.contains(
            PlankDrawingIdentityAccounts.clientPrivateAccount
        ), "\(name) touched the Client private key")
        precondition(!recorder.writes.contains(
            PlankDrawingIdentityAccounts.clientPrivateAccount
        ), "\(name) wrote the Client private key")

        // The identity-indexed record is what the connection path now keys on.
        precondition(recorder.store.hasApproval(for: drawingIdentity), "\(name)")
        precondition(legacy.allSatisfy { recorder.values[$0] != nil }, "\(name)")

        // Running it a second time must not overwrite or supersede anything.
        let replayed = try! recorder.store.apply(
            PlankDrawingMigrationPlanner.plan(
                legacyAccounts: fixture.legacyAccounts, defaults: fixture.defaults
            )
        )
        precondition(replayed == .alreadyPresent(identityAccount: identityAccount),
                     "\(name) re-ran destructively")
        precondition(recorder.writes == [identityAccount],
                     "\(name) wrote twice: \(recorder.writes)")
    }

    private static func verifyConflictWritesNothing(
        _ name: String, _ fixture: MigrationFixture,
        _ outcome: PlankDrawingMigrationOutcome
    ) {
        let recorder = seeded(fixture)
        let before = recorder.values
        let effect = try! recorder.store.apply(outcome)
        guard case let .blockedByConflict(accounts) = effect else {
            preconditionFailure("\(name) must be blocked, got \(effect)")
        }
        precondition(accounts.count >= 2, "\(name)")
        // Nothing written, nothing deleted, nothing merged, nothing preferred.
        precondition(recorder.writes.isEmpty,
                     "\(name) wrote during a conflict: \(recorder.writes)")
        precondition(recorder.values == before, "\(name) altered the store")
        for record in fixture.legacyAccounts {
            precondition(recorder.values[record.account] ==
                Data(hexadecimal: record.pinnedDrawingIdentity), "\(name)")
            precondition(!recorder.store.hasApproval(for: record.pinnedDrawingIdentity),
                         "\(name) created an approval despite the conflict")
        }
    }

    private static func verifyNoCandidateMeansNoMigration() {
        let orphan = [PlankLegacyPinRecord(
            account: "relay-203.0.113.30:28990",
            pinnedDrawingIdentity:
                "b4805f947954ddad8645c4a87d1bead9bcd2aceb3cacfa133dcdf10f1048191c"
        )]
        let outcome = PlankDrawingMigrationPlanner.plan(
            legacyAccounts: orphan, defaults: .empty
        )
        precondition(outcome == .nothingToMigrate)
        let recorder = RecordingStore([:])
        precondition(try! recorder.store.apply(outcome) == .nothingToDo)
        precondition(recorder.writes.isEmpty)

        // A record whose stored value is not a canonical identity is ignored
        // rather than re-indexed under a guessed account name.
        let malformed = [PlankLegacyPinRecord(
            account: "relay-192.0.2.10:28990", pinnedDrawingIdentity: "NOTHEX"
        )]
        precondition(PlankDrawingMigrationPlanner.plan(
            legacyAccounts: malformed,
            defaults: PlankLegacyRouteDefaults(
                mode: "manual", serviceName: nil, serviceDomain: nil,
                address: "192.0.2.10", port: 28990
            )
        ) == .nothingToMigrate)
    }

    private static func verifyExistingApprovalIsNeverSuperseded() {
        let identity =
            "b4805f947954ddad8645c4a87d1bead9bcd2aceb3cacfa133dcdf10f1048191c"
        let account = PlankDrawingIdentityAccounts.identityAccount(identity)
        let existing = Data(hexadecimal: identity)!
        let recorder = RecordingStore([
            "relay-192.0.2.10:28990": existing,
            account: existing,
        ])
        let outcome = PlankDrawingMigrationPlanner.plan(
            legacyAccounts: [PlankLegacyPinRecord(
                account: "relay-192.0.2.10:28990", pinnedDrawingIdentity: identity
            )],
            defaults: PlankLegacyRouteDefaults(
                mode: "manual", serviceName: nil, serviceDomain: nil,
                address: "192.0.2.10", port: 28990
            )
        )
        precondition(try! recorder.store.apply(outcome) ==
            .alreadyPresent(identityAccount: account))
        precondition(recorder.writes.isEmpty, "an existing approval was rewritten")
    }

    private static func verifyLegacyRouteApprovalsAreAddressKeyedOnly() {
        let known =
            "b4805f947954ddad8645c4a87d1bead9bcd2aceb3cacfa133dcdf10f1048191c"
        let approvals = PlankDrawingIdentityStore.routeApprovals(from: [
            PlankLegacyPinRecord(account: "relay-192.0.2.10:28990",
                                 pinnedDrawingIdentity: known),
            PlankLegacyPinRecord(account: "relay-service-PLANK Wacom Relay.local.",
                                 pinnedDrawingIdentity: known),
            PlankLegacyPinRecord(
                account: PlankDrawingIdentityAccounts.identityAccount(known),
                pinnedDrawingIdentity: known
            ),
        ])
        precondition(approvals == ["192.0.2.10:28990": known], "\(approvals)")
    }

    private static func verifyIdentityAccountRoundTrip() {
        let identity =
            "b4805f947954ddad8645c4a87d1bead9bcd2aceb3cacfa133dcdf10f1048191c"
        let account = PlankDrawingIdentityAccounts.identityAccount(identity)
        precondition(account ==
            "relay-identity-v1:b4805f947954ddad8645c4a87d1bead9bcd2aceb3cacfa133dcdf10f1048191c")
        precondition(PlankDrawingIdentityAccounts.isIdentityAccount(account))
        precondition(PlankDrawingIdentityAccounts.drawingIdentity(fromAccount: account) ==
            identity)
        precondition(!PlankDrawingIdentityAccounts
            .isIdentityAccount("relay-192.0.2.10:28990"))
        precondition(Data(hexadecimal: identity)?.count == 32)
        precondition(Data(hexadecimal: identity)?.hexadecimalText == identity)
    }
}
