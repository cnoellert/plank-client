import CryptoKit
import Foundation

// Harness 1: app-link validation (entry point 3) plus the trust and lifecycle
// outcomes of contract §10, driven entirely by the shared fixture files.
//
//   swiftc -Onone -DPLANK_TABLET_RELAY -parse-as-library \
//       visionos-native/Sources/Models/PlankDrawingHandoff.swift \
//       visionos-native/Sources/Services/PlankDrawingIdentityStore.swift \
//       visionos-native/Tests/PlankDrawingHandoffTests.swift -o <out> && <out>
//
// Assertions use `precondition`: Swift `assert` is stripped by -O, so an
// assert-based suite can pass while checking nothing.

private let fixtureRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Fixtures/plank-drawing-handoff-v1")

private let manifestSHA256 =
    "dd1125d8257f11431671fe116335c4e3c798c157207bdd576f3c44e724e95954"
private let contractRevision = "plank-drawing-handoff-v1+r3"
private let contractSHA256 =
    "1dce3dd079e26bc9d348d3fbea96e035c743e8ace390171862226c9a043545fc"

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func fixtureBytes(_ name: String, _ meta: [String: Any]) -> Data {
    guard let data = try? Data(contentsOf: fixtureRoot.appendingPathComponent(name)) else {
        preconditionFailure("missing fixture \(name)")
    }
    // Rule 3 of the fixture README: verify every fixture against the manifest
    // before using it, so a corrupted or locally edited mirror fails loudly.
    guard let expected = meta["sha256"] as? String else {
        preconditionFailure("manifest entry without sha256: \(name)")
    }
    precondition(sha256Hex(data) == expected, "fixture hash drift: \(name)")
    if let bytes = meta["bytes"] as? Int {
        precondition(data.count == bytes, "fixture byte count drift: \(name)")
    }
    return data
}

private func parse(_ name: String, _ data: Data) -> PlankDrawingHandoffParse {
    if name.hasSuffix(".url") {
        guard let text = String(data: data, encoding: .utf8) else {
            preconditionFailure("\(name) is not UTF-8 text")
        }
        return PlankDrawingHandoffValidator.validateAppLink(text)
    }
    // A `.json` or `.bin` fixture is the decoded payload itself, so it enters
    // at the payload stage (§7.1 step 10).
    return PlankDrawingHandoffValidator.validatePayload(data)
}

private let knownDrawingIdentity =
    "b4805f947954ddad8645c4a87d1bead9bcd2aceb3cacfa133dcdf10f1048191c"
private let unknownDrawingIdentity =
    "f490d12fcdb19b4c86c21f305ff4490f1fafe85d28134e0515f5f3c9be5543c4"
private let mismatchedDrawingIdentity =
    "6f830f05473e3b6d4654cce8a68af4a0d9c1f01e4701529d5f94eb4532f86b07"

@main
struct PlankDrawingHandoffTests {
    static func main() {
        let manifestData = try! Data(
            contentsOf: fixtureRoot.appendingPathComponent("MANIFEST.json")
        )
        // Contract drift must fail a test, not diverge quietly.
        precondition(sha256Hex(manifestData) == manifestSHA256,
                     "MANIFEST.json SHA-256 drift")
        let manifest = try! JSONSerialization.jsonObject(with: manifestData)
            as! [String: Any]
        precondition(manifest["revision"] as? String == contractRevision)
        let contract = manifest["contract"] as! [String: Any]
        precondition(contract["sha256"] as? String == contractSHA256)
        precondition(PlankDrawingHandoffContract.revision == contractRevision)

        let appLink = manifest["appLink"] as! [String: Any]
        precondition(appLink["scheme"] as? String == PlankDrawingHandoffContract.scheme)
        precondition(appLink["host"] as? String == PlankDrawingHandoffContract.host)
        precondition(appLink["path"] as? String == PlankDrawingHandoffContract.path)
        precondition(appLink["parameter"] as? String == PlankDrawingHandoffContract.parameter)
        precondition(appLink["maxUrlBytes"] as? Int == PlankDrawingHandoffContract.maxURLBytes)
        precondition(appLink["maxEncodedCharacters"] as? Int ==
            PlankDrawingHandoffContract.maxEncodedCharacters)
        precondition(appLink["maxDecodedBytes"] as? Int ==
            PlankDrawingHandoffContract.maxDecodedBytes)
        precondition(appLink["minDecodedBytes"] as? Int ==
            PlankDrawingHandoffContract.minDecodedBytes)

        let files = manifest["files"] as! [String: [String: Any]]

        var checkedAccept = 0
        var checkedReject = 0
        var checkedTrust = 0

        for name in files.keys.sorted() {
            guard name.hasPrefix("link/") else { continue }
            let meta = files[name]!
            precondition(meta["entryPoint"] as? String == "appLink", name)
            let expect = meta["expect"] as! String
            let data = fixtureBytes(name, meta)
            let result = parse(name, data)

            if name.hasPrefix("link/trust/") {
                // These parse cleanly; the expectation is a §10 trust outcome.
                guard let descriptor = result.descriptor else {
                    preconditionFailure("\(name) must parse: \(result)")
                }
                precondition(trustOutcome(for: descriptor) == expect,
                             "\(name) expected \(expect), got \(trustOutcome(for: descriptor))")
                checkedTrust += 1
                continue
            }

            if expect == "accept" {
                precondition(result.descriptor != nil,
                             "\(name) must be accepted, got \(result)")
                checkedAccept += 1
            } else {
                precondition(result.rejection == expect,
                             "\(name) expected \(expect), got \(String(describing: result.rejection))")
                checkedReject += 1
            }
        }

        precondition(checkedAccept >= 7, "accept fixtures not covered: \(checkedAccept)")
        precondition(checkedReject >= 100, "reject fixtures not covered: \(checkedReject)")
        precondition(checkedTrust == 5, "trust fixtures not covered: \(checkedTrust)")

        verifyCanonicalExampleIsSemantic(files)
        verifyRouteHandling(files)
        verifyDuplicateRequestScenario(files)
        verifyActiveSessionScenario(files)
        verifyUnknownIdentityScenario(files)
        verifyIdentityMismatchKeepsPin(files)
        verifyInterfaceLabelling()
        verifyScenariosMatchManifest(manifest, files)

        print("PlankDrawingHandoffTests: \(checkedAccept) accept, " +
              "\(checkedReject) reject, \(checkedTrust) trust fixtures verified")
    }

    // MARK: Trust evaluation used by the fixture sweep

    /// The state each `link/trust/` fixture describes, per its manifest note.
    private static func trustOutcome(
        for descriptor: PlankDrawingHandoffDescriptor
    ) -> String {
        var gate = PlankDrawingHandoffGate()
        var environment = PlankDrawingTrustEnvironment()
        environment.approvedDrawingIdentities = [knownDrawingIdentity]
        // A legacy address-keyed approval for the same relay, so an identity
        // change is distinguishable from a first sighting.
        environment.routeApprovals = ["192.0.2.10:28990": knownDrawingIdentity]

        if descriptor.drawingIdentity == unknownDrawingIdentity {
            // No saved pin and no route-keyed approval: the explicit physical
            // approval flow, never an auto-approval.
            environment.routeApprovals = [:]
        }
        if descriptor.drawingIdentity == knownDrawingIdentity {
            // The replayed request: the canonical link was accepted first.
            let canonical = PlankDrawingHandoffDescriptor(
                version: 1,
                requestID: descriptor.requestID,
                displayName: "Studio Relay",
                managementIdentity:
                    "c9a2bb1573de33196112f273d0f046d78093f41103b64f17ffcc3d2c3c054f0c",
                drawingIdentity: knownDrawingIdentity,
                routes: [PlankDrawingRoute(address: "192.0.2.10", port: 28990,
                                           interface: "eth0", kind: .wired)]
            )
            precondition(gate.evaluate(canonical, environment: environment) ==
                .verifyThenConnect(PlankDrawingRouteSelection(
                    drawingIdentity: knownDrawingIdentity,
                    displayName: "Studio Relay",
                    routes: canonical.routes
                )))
        }
        return gate.evaluate(descriptor, environment: environment).outcomeIdentifier
    }

    // MARK: Individual requirements

    private static func descriptor(_ name: String, _ files: [String: [String: Any]])
        -> PlankDrawingHandoffDescriptor {
        let data = fixtureBytes(name, files[name]!)
        guard let parsed = parse(name, data).descriptor else {
            preconditionFailure("\(name) must parse")
        }
        return parsed
    }

    private static func verifyCanonicalExampleIsSemantic(_ files: [String: [String: Any]]) {
        let fromURL = descriptor("link/valid/known-identity.url", files)
        let fromJSON = descriptor("link/valid/known-identity.json", files)
        // Compare parsed values, never file lengths and never raw bytes (§6.4).
        precondition(fromURL == fromJSON, "canonical example diverged")
        precondition(files["link/valid/known-identity.json"]!["bytes"] as? Int == 650)
        precondition(files["link/valid/known-identity.url"]!["bytes"] as? Int == 704)
        precondition(fromURL.routes.count == 2)
        precondition(fromURL.routes[0].address == "192.0.2.10")
        precondition(fromURL.routes[0].port == 28990)
        precondition(fromURL.routes[0].interface == "eth0")
        precondition(fromURL.routes[0].kind == .wired)
        precondition(fromURL.drawingIdentity == knownDrawingIdentity)
        precondition(fromURL.drawingIdentity != fromURL.managementIdentity)
    }

    private static func verifyRouteHandling(_ files: [String: [String: Any]]) {
        // Byte-identical routes deduplicate; two survive.
        let duplicated = descriptor("link/valid/duplicate-routes.json", files)
        precondition(duplicated.routes.count == 2, "routes did not deduplicate")
        let maxed = descriptor("link/valid/max-routes.json", files)
        precondition(maxed.routes.count == 8)
        let minimal = descriptor("link/valid/minimal.json", files)
        precondition(minimal.routes.count == 1)
        precondition(minimal.routes[0].interface == nil)
        precondition(minimal.routes[0].kind == nil)
        let minimalFromURL = descriptor("link/valid/minimal.url", files)
        precondition(minimal == minimalFromURL)

        // A pin matches across changed addresses: the same approved identity on
        // an entirely different route set is still the same relay.
        var gate = PlankDrawingHandoffGate()
        let environment = PlankDrawingTrustEnvironment(
            approvedDrawingIdentities: [knownDrawingIdentity],
            routeApprovals: [:],
            desktopSessionActive: false
        )
        let moved = PlankDrawingHandoffDescriptor(
            version: 1,
            requestID: "11111111-2222-3333-4444-555555555555",
            displayName: minimal.displayName,
            managementIdentity: minimal.managementIdentity,
            drawingIdentity: knownDrawingIdentity,
            routes: [PlankDrawingRoute(address: "203.0.113.30", port: 28990,
                                       interface: nil, kind: nil)]
        )
        guard case let .verifyThenConnect(selection) =
            gate.evaluate(moved, environment: environment) else {
            preconditionFailure("a pinned identity on a new address must still verify")
        }
        precondition(selection.drawingIdentity == knownDrawingIdentity)
        precondition(selection.routes == moved.routes)
        precondition(selection.route(forAttempt: 0)?.address == "203.0.113.30")
        precondition(selection.route(forAttempt: 7)?.address == "203.0.113.30")
    }

    private static func verifyDuplicateRequestScenario(_ files: [String: [String: Any]]) {
        var gate = PlankDrawingHandoffGate()
        let environment = PlankDrawingTrustEnvironment(
            approvedDrawingIdentities: [knownDrawingIdentity]
        )
        let first = descriptor("link/valid/known-identity.url", files)
        guard case let .verifyThenConnect(selection) =
            gate.evaluate(first, environment: environment) else {
            preconditionFailure("the canonical link must be accepted")
        }
        precondition(selection.routes.count == 2)
        precondition(gate.recentRequestIDCount == 1)

        let replayed = descriptor("link/trust/replayed-request.url", files)
        precondition(replayed.requestID == first.requestID)
        precondition(replayed.routes != first.routes, "the replay carries other content")
        precondition(gate.evaluate(replayed, environment: environment) == .duplicateRequest)
        // A repeated requestID is deduplicated, never treated as proof of trust.
        precondition(gate.recentRequestIDCount == 1)

        // The set is bounded at 16 and stays process-local.
        var bounded = PlankDrawingHandoffGate()
        for index in 0..<20 {
            let unique = PlankDrawingHandoffDescriptor(
                version: 1,
                requestID: String(format: "%08x-0000-4000-8000-000000000000", index),
                displayName: "Relay",
                managementIdentity: first.managementIdentity,
                drawingIdentity: knownDrawingIdentity,
                routes: first.routes
            )
            precondition(bounded.evaluate(unique, environment: environment) !=
                .duplicateRequest)
        }
        precondition(bounded.recentRequestIDCount ==
            PlankDrawingHandoffContract.recentRequestIDCapacity)
    }

    private static func verifyActiveSessionScenario(_ files: [String: [String: Any]]) {
        var gate = PlankDrawingHandoffGate()
        var environment = PlankDrawingTrustEnvironment(
            approvedDrawingIdentities: [knownDrawingIdentity]
        )
        environment.desktopSessionActive = true
        let canonical = descriptor("link/valid/known-identity.url", files)
        precondition(gate.evaluate(canonical, environment: environment) ==
            .desktopSessionActive)
        // Declining must not consume the requestID, so the deferred handoff can
        // be used after disconnect without looking like a replay.
        precondition(gate.recentRequestIDCount == 0)
        environment.desktopSessionActive = false
        guard case .verifyThenConnect = gate.evaluate(canonical, environment: environment) else {
            preconditionFailure("the deferred handoff must work after disconnect")
        }
    }

    private static func verifyUnknownIdentityScenario(_ files: [String: [String: Any]]) {
        var gate = PlankDrawingHandoffGate()
        let environment = PlankDrawingTrustEnvironment(
            approvedDrawingIdentities: [knownDrawingIdentity]
        )
        let unknown = descriptor("link/trust/unknown-drawing-identity.url", files)
        precondition(unknown.drawingIdentity == unknownDrawingIdentity)
        let decision = gate.evaluate(unknown, environment: environment)
        precondition(decision ==
            .needsExplicitApproval(drawingIdentity: unknownDrawingIdentity))
        precondition(decision.outcomeIdentifier == "trust.unknownDrawingIdentity")
        // Never auto-approved: no route and no link can make a key trusted.
        precondition(!environment.approvedDrawingIdentities.contains(unknownDrawingIdentity))
        precondition(gate.recentRequestIDCount == 0)
    }

    private static func verifyIdentityMismatchKeepsPin(_ files: [String: [String: Any]]) {
        var gate = PlankDrawingHandoffGate()
        let environment = PlankDrawingTrustEnvironment(
            approvedDrawingIdentities: [knownDrawingIdentity],
            routeApprovals: ["192.0.2.10:28990": knownDrawingIdentity]
        )
        let mismatched = descriptor("link/trust/mismatched-drawing-identity.json", files)
        precondition(mismatched.drawingIdentity == mismatchedDrawingIdentity)
        precondition(gate.evaluate(mismatched, environment: environment) ==
            .drawingIdentityMismatch(saved: knownDrawingIdentity,
                                     received: mismatchedDrawingIdentity))
        // The saved approval is untouched.
        precondition(environment.approvedDrawingIdentities == [knownDrawingIdentity])
        precondition(environment.routeApprovals["192.0.2.10:28990"] == knownDrawingIdentity)

        // A management identity can never stand in for a drawing pin.
        let managementAsDrawing = PlankDrawingTrustEnvironment(
            approvedDrawingIdentities: [mismatched.managementIdentity]
        )
        var second = PlankDrawingHandoffGate()
        precondition(second.evaluate(mismatched, environment: managementAsDrawing) ==
            .needsExplicitApproval(drawingIdentity: mismatchedDrawingIdentity))
    }

    private static func verifyInterfaceLabelling() {
        precondition(PlankDrawingRoute(address: "192.0.2.10", port: 1,
                                       interface: "eth0", kind: .wired)
            .displayLabel == "eth0")
        precondition(PlankDrawingRoute(address: "192.0.2.10", port: 1,
                                       interface: nil, kind: .wireless)
            .displayLabel == "Wireless")
        // Never infer Wi-Fi from the headset being wireless.
        precondition(PlankDrawingRoute(address: "192.0.2.10", port: 1,
                                       interface: nil, kind: nil)
            .displayLabel == "Network")
    }

    private static func verifyScenariosMatchManifest(
        _ manifest: [String: Any], _ files: [String: [String: Any]]
    ) {
        let scenarios = manifest["scenarios"] as! [[String: Any]]
        var covered = Set<String>()
        for scenario in scenarios {
            let name = scenario["name"] as! String
            guard name != "peer-credential-squat" else { continue } // relay-side
            let steps = scenario["steps"] as! [[String: Any]]
            for step in steps {
                let file = step["file"] as! String
                precondition(files[file] != nil, "scenario step \(file) not in manifest")
                _ = fixtureBytes(file, files[file]!)
            }
            covered.insert(name)
        }
        precondition(covered == ["duplicate-request", "active-desktop-session",
                                 "unknown-identity-approval"],
                     "scenario coverage changed: \(covered)")
    }
}
