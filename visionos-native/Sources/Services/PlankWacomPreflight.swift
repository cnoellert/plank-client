import Foundation

enum PlankWacomPreflightGate: String, CaseIterable, Sendable {
    case rawHid = "raw_hid"
    case focusSuspend = "focus_suspend"
    case relayLink = "relay_link"
    case deviceOwnership = "device_ownership"
    case attachSent = "attach_sent"
    case hostAcknowledgement = "host_acknowledgement"
}

enum PlankWacomPreflightState: String, Sendable {
    case pending
    case passed
    case failed
}

struct PlankWacomPreflightSnapshot: Sendable {
    let sequence: UInt64
    let gates: [PlankWacomPreflightGate: PlankWacomPreflightState]

    var ready: Bool {
        PlankWacomPreflightGate.allCases.allSatisfy { gates[$0] == .passed }
    }

    var summary: String {
        let passed = gates.values.filter { $0 == .passed }.count
        return ready ? "Wacom preflight passed (6/6)." :
            "Wacom preflight: \(passed)/6 checks passed."
    }
}

// Records only protocol facts. No pairing code, key, address, tablet serial,
// descriptor, report, or Host credential enters the preflight log.
final class PlankWacomPreflight: @unchecked Sendable {
    private let lock = NSLock()
    private let sessionID = UUID().uuidString
    private let clientVersion: String
    private let hostVersion: String
    private let emit: (String) -> Void
    private let onChange: @Sendable (PlankWacomPreflightSnapshot) -> Void
    private var relayVersion: String?
    private var relayReportsOwnership = false
    private var gates = Dictionary(uniqueKeysWithValues:
        PlankWacomPreflightGate.allCases.map { ($0, PlankWacomPreflightState.pending) })
    private var generation: UInt16 = 0
    private var expectedDescriptors = 0
    private var sentDescriptors = Set<UInt16>()
    private var sequence: UInt64 = 0
    private var lastRecord = ""

    init(clientVersion: String, hostVersion: String,
         emit: @escaping (String) -> Void = { NSLog("%@", $0) },
         onChange: @escaping @Sendable (PlankWacomPreflightSnapshot) -> Void = { _ in }) {
        self.clientVersion = clientVersion
        self.hostVersion = hostVersion
        self.emit = emit
        self.onChange = onChange
        changed()
    }

    func observeHostFeatures(rawHid: Bool, focusSuspend: Bool) {
        mutate {
            gates[.rawHid] = rawHid ? .passed : .failed
            gates[.focusSuspend] = focusSuspend ? .passed : .failed
        }
    }

    func beginRelayConnection() {
        mutate {
            relayVersion = nil
            relayReportsOwnership = false
            generation = 0
            expectedDescriptors = 0
            sentDescriptors.removeAll()
            for gate in [PlankWacomPreflightGate.relayLink, .deviceOwnership,
                         .attachSent, .hostAcknowledgement] {
                gates[gate] = .pending
            }
        }
    }

    func relayAuthenticated(version: String) {
        mutate {
            relayVersion = version.isEmpty ? nil : version
            let parts = version.split(separator: ".").compactMap { Int($0) }
            relayReportsOwnership = parts.count == 3 &&
                (parts[0], parts[1], parts[2]) >= (0, 1, 1)
            gates[.relayLink] = .passed
        }
    }

    func observeRelayStatus(_ status: Data) {
        guard status.count >= 8 else { return }
        mutate {
            let vendor = UInt16(status[1]) | UInt16(status[2]) << 8
            let product = UInt16(status[3]) | UInt16(status[4]) << 8
            let ownsRawWacom = relayReportsOwnership && status[0] == 3 && vendor == 0x056a &&
                product != 0 && status[5] > 0 && status[6] == 1
            gates[.deviceOwnership] = ownsRawWacom ? .passed :
                (status[0] == 3 || status[0] >= 5 ? .failed : .pending)
            if status[0] == 0 || status[0] >= 5 {
                generation = 0
                expectedDescriptors = 0
                sentDescriptors.removeAll()
                gates[.attachSent] = .pending
                gates[.hostAcknowledgement] = .pending
            }
        }
    }

    // Called only after the native transport confirms a complete PLWH frame
    // was accepted for sending to the Host.
    func observeSentTabletFrame(_ frame: Data) {
        guard let type = Self.read16(frame, at: 6), type == 1 || type == 2,
              let frameGeneration = Self.read16(frame, at: 10),
              frameGeneration != 0 else { return }
        mutate {
            if type == 1 {
                generation = frameGeneration
                expectedDescriptors = Int(Self.read16(frame, at: 20) ?? 0)
                sentDescriptors.removeAll()
                gates[.attachSent] = .pending
                gates[.hostAcknowledgement] = .pending
                gates[.deviceOwnership] = .pending
            } else if frameGeneration == generation,
                      let interfaceID = Self.read16(frame, at: 8),
                      Int(interfaceID) < expectedDescriptors {
                sentDescriptors.insert(interfaceID)
                if expectedDescriptors > 0 &&
                    sentDescriptors.count == expectedDescriptors {
                    gates[.attachSent] = .passed
                }
            }
        }
    }

    func observeHostFrame(_ frame: Data) {
        guard Self.read16(frame, at: 6) == 10,
              let frameGeneration = Self.read16(frame, at: 10),
              frameGeneration != 0,
              frame.count == 24 else { return }
        let accepted = frame[20..<24].allSatisfy { $0 == 0 }
        mutate {
            guard frameGeneration == generation else { return }
            gates[.hostAcknowledgement] = accepted &&
                gates[.attachSent] == .passed ? .passed : .failed
        }
    }

    var snapshot: PlankWacomPreflightSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return PlankWacomPreflightSnapshot(sequence: sequence, gates: gates)
    }

    private static func read16(_ data: Data, at offset: Int) -> UInt16? {
        guard data.count >= offset + 2 else { return nil }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private func mutate(_ change: () -> Void) {
        lock.lock()
        change()
        let result = recordIfChanged()
        if let result {
            emit(result.0)
            onChange(result.1)
        }
        lock.unlock()
    }

    private func changed() { mutate {} }

    private func recordIfChanged() -> (String, PlankWacomPreflightSnapshot)? {
        let states = Dictionary(uniqueKeysWithValues:
            gates.map { ($0.key.rawValue, $0.value.rawValue) })
        var object: [String: Any] = [
            "schema_version": 1,
            "session_id": sessionID,
            "client_version": clientVersion,
            "host_version": hostVersion,
            "relay_version": relayVersion.map { $0 as Any } ?? NSNull(),
            "gates": states,
            "ready": PlankWacomPreflightGate.allCases.allSatisfy {
                gates[$0] == .passed
            },
        ]
        guard let stableData = try? JSONSerialization.data(withJSONObject: object,
                                                            options: [.sortedKeys]),
              let stable = String(data: stableData, encoding: .utf8),
              stable != lastRecord else { return nil }
        lastRecord = stable
        sequence += 1
        let snapshot = PlankWacomPreflightSnapshot(sequence: sequence, gates: gates)
        object["sequence"] = sequence
        object["timestamp_utc"] = ISO8601DateFormatter().string(from: Date())
        guard let record = try? JSONSerialization.data(withJSONObject: object,
                                                       options: [.sortedKeys]),
              let json = String(data: record, encoding: .utf8) else { return nil }
        return ("PLANK Wacom preflight: \(json)", snapshot)
    }
}
