import Foundation

// Entry point 3 of plank-drawing-handoff-v1+r3: the app-link descriptor that
// Setup hands to PLANK. Contract SHA-256
// 1dce3dd079e26bc9d348d3fbea96e035c743e8ace390171862226c9a043545fc.
//
// This file is deliberately Foundation-only and free of SwiftUI, Network,
// Security and the relay C symbols so the standalone test harness can compile
// it. Validation is pure: no socket, no Keychain, no Bonjour, no DNS.

enum PlankDrawingHandoffContract {
    static let revision = "plank-drawing-handoff-v1+r3"
    static let scheme = "plank-vision"
    static let host = "handoff"
    static let path = "/v1"
    static let parameter = "d"
    static let maxURLBytes = 5490
    static let maxEncodedCharacters = 5462
    static let maxDecodedBytes = 4096
    static let minDecodedBytes = 2
    static let version = 1
    static let protocolName = "pltr-raw-hid"
    static let protocolVersion = 1
    static let protocolRawHID = 1
    static let protocolLinkTypeTCP = 2
    static let minRoutes = 1
    static let maxRoutes = 8
    static let identityHexLength = 64
    static let maxDisplayNameBytes = 64
    static let maxRouteAddressBytes = 64
    static let maxInterfaceBytes = 15
    /// Contract §10.5: bounded, process-lifetime, non-persistent.
    static let recentRequestIDCapacity = 16
}

// MARK: - Descriptor model

enum PlankDrawingRouteKind: String, Equatable, Hashable {
    case wired
    case wireless
    case other

    var title: String {
        switch self {
        case .wired: "Wired"
        case .wireless: "Wireless"
        case .other: "Other"
        }
    }
}

struct PlankDrawingRoute: Equatable, Hashable {
    let address: String
    let port: UInt16
    /// Contract §7.7: advisory and display-only. Never influences acceptance,
    /// ordering, preference, retry policy, trust or storage.
    let interface: String?
    let kind: PlankDrawingRouteKind?

    /// Contract §7.7: show the interface when known, the coarse kind when
    /// known, and otherwise "Network". Never infer Wi-Fi from the headset.
    var displayLabel: String {
        if let interface, !interface.isEmpty { return interface }
        if let kind { return kind.title }
        return "Network"
    }
}

struct PlankDrawingHandoffDescriptor: Equatable {
    let version: Int
    let requestID: String
    /// Display only. Never used for trust, matching or storage keys (§6.5).
    let displayName: String
    let managementIdentity: String
    let drawingIdentity: String
    /// Validated and deduplicated in descriptor order (§7.6).
    let routes: [PlankDrawingRoute]
    var bluetoothIdentifier: UUID? = nil

    // drawingProtocol carries only frozen values (name pltr-raw-hid, version 1,
    // rawHID 1, linkType 2). It is validated and then has nothing left to
    // carry, so it is intentionally not stored.
}

enum PlankDrawingHandoffParse: Equatable {
    case accepted(PlankDrawingHandoffDescriptor)
    /// The first failing ordered check's reason identifier (§7.1).
    case rejected(String)

    var rejection: String? {
        if case let .rejected(reason) = self { return reason }
        return nil
    }

    var descriptor: PlankDrawingHandoffDescriptor? {
        if case let .accepted(descriptor) = self { return descriptor }
        return nil
    }
}

// MARK: - Minimal JSON model

struct PlankJSONMember: Equatable {
    let name: String
    let value: PlankJSON
}

indirect enum PlankJSON: Equatable {
    case null
    case bool(Bool)
    /// The raw source text is kept so integrality is decided by the contract's
    /// grammar and not by a lossy Double round-trip.
    case number(String)
    case string(String)
    case array([PlankJSON])
    /// Members in source order with duplicates preserved, so the duplicate
    /// scan can observe them before any dictionary decode (§7.2).
    case object([PlankJSONMember])

    var isObject: Bool { if case .object = self { return true }; return false }

    var members: [PlankJSONMember]? {
        if case let .object(members) = self { return members }
        return nil
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var arrayValue: [PlankJSON]? {
        if case let .array(values) = self { return values }
        return nil
    }

    var isNull: Bool { if case .null = self { return true }; return false }

    /// An integral JSON number, or nil for a non-number or a non-integral one.
    var integerValue: Int? {
        guard case let .number(text) = self else { return nil }
        if text.contains(".") || text.contains("e") || text.contains("E") {
            return nil
        }
        return Int(text)
    }
}

/// A recursive-descent JSON reader over raw bytes. It preserves duplicate
/// member names, rejects trailing content, and unescapes member names so two
/// escaped-equivalent names compare equal (§7.2).
struct PlankJSONReader {
    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0
    private static let maxDepth = 64

    private init(_ bytes: [UInt8]) { self.bytes = bytes }

    /// Returns nil for a syntax error, excessive nesting, or trailing content.
    static func parse(_ data: Data) -> PlankJSON? {
        var reader = PlankJSONReader([UInt8](data))
        reader.skipWhitespace()
        guard let value = reader.readValue() else { return nil }
        reader.skipWhitespace()
        guard reader.index == reader.bytes.count else { return nil }
        return value
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private mutating func readValue() -> PlankJSON? {
        guard index < bytes.count, depth < Self.maxDepth else { return nil }
        switch bytes[index] {
        case UInt8(ascii: "{"): return readObject()
        case UInt8(ascii: "["): return readArray()
        case UInt8(ascii: "\""): return readString().map { .string($0) }
        case UInt8(ascii: "t"): return readLiteral("true").map { _ in .bool(true) }
        case UInt8(ascii: "f"): return readLiteral("false").map { _ in .bool(false) }
        case UInt8(ascii: "n"): return readLiteral("null").map { _ in .null }
        default: return readNumber()
        }
    }

    private mutating func readLiteral(_ text: String) -> Bool? {
        let expected = [UInt8](text.utf8)
        guard index + expected.count <= bytes.count else { return nil }
        for offset in 0..<expected.count where bytes[index + offset] != expected[offset] {
            return nil
        }
        index += expected.count
        return true
    }

    private mutating func readObject() -> PlankJSON? {
        index += 1 // '{'
        depth += 1
        defer { depth -= 1 }
        var members: [PlankJSONMember] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\""),
                  let name = readString() else { return nil }
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
            index += 1
            skipWhitespace()
            guard let value = readValue() else { return nil }
            members.append(PlankJSONMember(name: name, value: value))
            skipWhitespace()
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            }
            return nil
        }
    }

    private mutating func readArray() -> PlankJSON? {
        index += 1 // '['
        depth += 1
        defer { depth -= 1 }
        var values: [PlankJSON] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(values)
        }
        while true {
            skipWhitespace()
            guard let value = readValue() else { return nil }
            values.append(value)
            skipWhitespace()
            guard index < bytes.count else { return nil }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            if bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(values)
            }
            return nil
        }
    }

    private mutating func readString() -> String? {
        guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
        index += 1
        var scalars = String.UnicodeScalarView()
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                return String(scalars)
            }
            if byte < 0x20 { return nil }
            if byte == UInt8(ascii: "\\") {
                index += 1
                guard index < bytes.count else { return nil }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append(Unicode.Scalar(0x08)!)
                case UInt8(ascii: "f"): scalars.append(Unicode.Scalar(0x0C)!)
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    guard let first = readHex4() else { return nil }
                    if first >= 0xD800, first <= 0xDBFF {
                        guard index + 1 < bytes.count,
                              bytes[index] == UInt8(ascii: "\\"),
                              bytes[index + 1] == UInt8(ascii: "u") else { return nil }
                        index += 2
                        guard let second = readHex4(), second >= 0xDC00, second <= 0xDFFF,
                              let scalar = Unicode.Scalar(
                                  0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                              ) else { return nil }
                        scalars.append(scalar)
                    } else if first >= 0xDC00, first <= 0xDFFF {
                        return nil
                    } else if let scalar = Unicode.Scalar(first) {
                        scalars.append(scalar)
                    } else {
                        return nil
                    }
                default: return nil
                }
                continue
            }
            // Multi-byte UTF-8 sequences reach here already validated by the
            // separate well-formedness pass, so copy the scalar through.
            guard let scalar = readUTF8Scalar() else { return nil }
            scalars.append(scalar)
        }
        return nil
    }

    private mutating func readHex4() -> UInt32? {
        guard index + 4 <= bytes.count else { return nil }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"):
                digit = UInt32(byte - UInt8(ascii: "a")) + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"):
                digit = UInt32(byte - UInt8(ascii: "A")) + 10
            default: return nil
            }
            value = value << 4 | digit
            index += 1
        }
        return value
    }

    private mutating func readUTF8Scalar() -> Unicode.Scalar? {
        let first = bytes[index]
        let length: Int
        var value: UInt32
        switch first {
        case 0x00...0x7F: length = 1; value = UInt32(first)
        case 0xC2...0xDF: length = 2; value = UInt32(first & 0x1F)
        case 0xE0...0xEF: length = 3; value = UInt32(first & 0x0F)
        case 0xF0...0xF4: length = 4; value = UInt32(first & 0x07)
        default: return nil
        }
        guard index + length <= bytes.count else { return nil }
        for offset in 1..<max(length, 1) {
            let byte = bytes[index + offset]
            guard byte & 0xC0 == 0x80 else { return nil }
            value = value << 6 | UInt32(byte & 0x3F)
        }
        index += length
        return Unicode.Scalar(value)
    }

    private mutating func readNumber() -> PlankJSON? {
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count else { return nil }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else if bytes[index] >= UInt8(ascii: "1"), bytes[index] <= UInt8(ascii: "9") {
            while index < bytes.count, bytes[index] >= UInt8(ascii: "0"),
                  bytes[index] <= UInt8(ascii: "9") { index += 1 }
        } else {
            return nil
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            var digits = 0
            while index < bytes.count, bytes[index] >= UInt8(ascii: "0"),
                  bytes[index] <= UInt8(ascii: "9") { index += 1; digits += 1 }
            guard digits > 0 else { return nil }
        }
        if index < bytes.count,
           bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count,
               bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            var digits = 0
            while index < bytes.count, bytes[index] >= UInt8(ascii: "0"),
                  bytes[index] <= UInt8(ascii: "9") { index += 1; digits += 1 }
            guard digits > 0 else { return nil }
        }
        guard let text = String(bytes: bytes[start..<index], encoding: .utf8) else {
            return nil
        }
        return .number(text)
    }
}

// MARK: - Byte-level helpers

enum PlankDrawingHandoffBytes {
    private static let alphabet = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8
    )

    static func isBase64URLAlphabet(_ characters: [UInt8]) -> Bool {
        characters.allSatisfy { alphabet.contains($0) }
    }

    static func decodeBase64URL(_ characters: [UInt8]) -> Data? {
        var accumulator: UInt32 = 0
        var bits = 0
        var output = Data()
        for character in characters {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            accumulator = accumulator << 6 | UInt32(index)
            bits += 6
            if bits >= 8 {
                bits -= 8
                output.append(UInt8(truncatingIfNeeded: accumulator >> UInt32(bits)))
            }
        }
        return output
    }

    static func encodeBase64URL(_ data: Data) -> [UInt8] {
        var output: [UInt8] = []
        var accumulator: UInt32 = 0
        var bits = 0
        for byte in data {
            accumulator = accumulator << 8 | UInt32(byte)
            bits += 8
            while bits >= 6 {
                bits -= 6
                output.append(alphabet[Int((accumulator >> UInt32(bits)) & 0x3F)])
            }
        }
        if bits > 0 {
            output.append(alphabet[Int((accumulator << UInt32(6 - bits)) & 0x3F)])
        }
        return output
    }

    /// Deterministic UTF-8 well-formedness: rejects overlong forms, surrogates
    /// and out-of-range scalars rather than trusting a platform decoder.
    static func isWellFormedUTF8(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let first = bytes[index]
            let length: Int
            var value: UInt32
            switch first {
            case 0x00...0x7F: length = 1; value = UInt32(first)
            case 0xC2...0xDF: length = 2; value = UInt32(first & 0x1F)
            case 0xE0...0xEF: length = 3; value = UInt32(first & 0x0F)
            case 0xF0...0xF4: length = 4; value = UInt32(first & 0x07)
            default: return false
            }
            guard index + length <= bytes.count else { return false }
            if length > 1 {
                for offset in 1..<length {
                    let byte = bytes[index + offset]
                    guard byte & 0xC0 == 0x80 else { return false }
                    value = value << 6 | UInt32(byte & 0x3F)
                }
            }
            switch length {
            case 2 where value < 0x80: return false
            case 3 where value < 0x800: return false
            case 4 where value < 0x10000: return false
            default: break
            }
            if value >= 0xD800, value <= 0xDFFF { return false }
            if value > 0x10FFFF { return false }
            index += length
        }
        return true
    }

    /// Contract §7.2: every object at every depth, names compared after
    /// unescaping, siblings never conflated.
    static func containsDuplicateMember(_ value: PlankJSON) -> Bool {
        switch value {
        case let .object(members):
            var seen = Set<String>()
            for member in members {
                if !seen.insert(member.name).inserted { return true }
            }
            return members.contains { containsDuplicateMember($0.value) }
        case let .array(values):
            return values.contains { containsDuplicateMember($0) }
        default:
            return false
        }
    }
}

// MARK: - Address literals (contract §7.4a)

enum PlankDrawingAddressFamily: Equatable {
    case ipv4([UInt8])
    case ipv6([UInt8])
}

enum PlankDrawingAddressCheck: Equatable {
    case literal(PlankDrawingAddressFamily)
    case notLiteral
    case nonCanonical
    case mapped
}

enum PlankDrawingAddressClass: String, Equatable {
    case unspecified
    case loopback
    case linkLocal
    case multicast
    case broadcast
    case unicast
}

enum PlankDrawingAddress {
    /// The deterministic pre-checks of §7.4a, applied to the raw text and raw
    /// bytes so no platform parser can change the reported reason.
    static func classify(_ text: String) -> PlankDrawingAddressCheck {
        let scalars = Array(text.unicodeScalars)
        let digitsAndDotsOnly = !scalars.isEmpty && scalars.allSatisfy {
            ($0.value >= 48 && $0.value <= 57) || $0 == "."
        }
        if digitsAndDotsOnly {
            let groups = text.split(separator: ".", omittingEmptySubsequences: false)
            guard groups.count == 4 else { return .notLiteral }
            var octets: [UInt8] = []
            for group in groups {
                guard group.count >= 1, group.count <= 3 else { return .notLiteral }
                guard let value = Int(group), value <= 255 else { return .notLiteral }
                if group.count > 1, group.hasPrefix("0") { return .nonCanonical }
                octets.append(UInt8(value))
            }
            return .literal(.ipv4(octets))
        }
        guard text.contains(":") else { return .notLiteral }
        if scalars.contains(where: { $0.value >= 65 && $0.value <= 90 }) {
            return .nonCanonical
        }
        var raw = [UInt8](repeating: 0, count: 16)
        let parsed = text.withCString { pointer -> Bool in
            raw.withUnsafeMutableBytes { buffer in
                inet_pton(AF_INET6, pointer, buffer.baseAddress) == 1
            }
        }
        guard parsed else { return .notLiteral }
        // Byte tests before the round-trip: a mapped address is refused in any
        // textual form and the two platforms render it differently.
        let leadingZeros = raw[0..<10].allSatisfy { $0 == 0 }
        if leadingZeros, raw[10] == 0xFF, raw[11] == 0xFF { return .mapped }
        if raw[0..<12].allSatisfy({ $0 == 0 }) {
            let tail = (UInt32(raw[12]) << 24) | (UInt32(raw[13]) << 16) |
                (UInt32(raw[14]) << 8) | UInt32(raw[15])
            if tail > 1 { return .mapped }
        }
        var rendered = [CChar](repeating: 0, count: 46)
        let roundTrip = raw.withUnsafeBytes { source -> String? in
            guard inet_ntop(AF_INET6, source.baseAddress, &rendered, 46) != nil else {
                return nil
            }
            return String(cString: rendered)
        }
        guard let roundTrip, roundTrip == text else { return .nonCanonical }
        return .literal(.ipv6(raw))
    }

    static func classification(of family: PlankDrawingAddressFamily) -> PlankDrawingAddressClass {
        switch family {
        case let .ipv4(octets):
            if octets[0] == 0 { return .unspecified }
            if octets[0] == 127 { return .loopback }
            if octets[0] == 169, octets[1] == 254 { return .linkLocal }
            if octets[0] >= 224, octets[0] <= 239 { return .multicast }
            if octets[0] >= 240 { return .broadcast }
            return .unicast
        case let .ipv6(raw):
            if raw.allSatisfy({ $0 == 0 }) { return .unspecified }
            if raw[0..<15].allSatisfy({ $0 == 0 }), raw[15] == 1 { return .loopback }
            if raw[0] == 0xFE, raw[1] & 0xC0 == 0x80 { return .linkLocal }
            if raw[0] == 0xFF { return .multicast }
            return .unicast
        }
    }
}

/// A validation result that carries a contract reason identifier rather than an
/// Error, because the identifiers are contract vocabulary and not failures.
enum PlankValidated<Value> {
    case value(Value)
    case rejection(String)
}

// MARK: - App-link validator

enum PlankDrawingHandoffValidator {
    /// Entry point 3, from the raw app-link text (§7.1 URL stage onward).
    static func validateAppLink(_ raw: String) -> PlankDrawingHandoffParse {
        // A `.url` fixture stores exactly one link plus a single LF.
        var text = raw
        if text.hasSuffix("\n") { text.removeLast() }

        guard text.utf8.count <= PlankDrawingHandoffContract.maxURLBytes else {
            return .rejected("url.length")
        }
        guard let separator = text.range(of: "://") else { return .rejected("url.scheme") }
        let scheme = String(text[text.startIndex..<separator.lowerBound])
        guard scheme.lowercased() == PlankDrawingHandoffContract.scheme else {
            return .rejected("url.scheme")
        }
        let remainder = String(text[separator.upperBound...])
        let authorityEnd = remainder.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" }
            ?? remainder.endIndex
        let authority = String(remainder[remainder.startIndex..<authorityEnd])
        guard authority == PlankDrawingHandoffContract.host else {
            // Covers a different host, any user info and any port.
            return .rejected("url.host")
        }
        let afterAuthority = String(remainder[authorityEnd...])
        let pathEnd = afterAuthority.firstIndex { $0 == "?" || $0 == "#" }
            ?? afterAuthority.endIndex
        let path = String(afterAuthority[afterAuthority.startIndex..<pathEnd])
        guard path == PlankDrawingHandoffContract.path || path == "/v2" else { return .rejected("url.path") }
        let tail = String(afterAuthority[pathEnd...])
        guard !tail.contains("#") else { return .rejected("url.fragment") }
        guard tail.hasPrefix("?") else { return .rejected("url.query") }
        let query = String(tail.dropFirst())
        let items = query.split(separator: "&", omittingEmptySubsequences: false)
        guard items.count == 1 else { return .rejected("url.query") }
        let item = String(items[0])
        guard let equals = item.firstIndex(of: "=") else { return .rejected("url.query") }
        guard String(item[item.startIndex..<equals]) ==
            PlankDrawingHandoffContract.parameter else { return .rejected("url.query") }
        let encoded = String(item[item.index(after: equals)...])
        guard !encoded.isEmpty else { return .rejected("url.query") }

        let characters = [UInt8](encoded.utf8)
        guard characters.count == encoded.unicodeScalars.count,
              characters.count <= PlankDrawingHandoffContract.maxEncodedCharacters,
              characters.count % 4 != 1 else { return .rejected("encoding.length") }
        guard PlankDrawingHandoffBytes.isBase64URLAlphabet(characters) else {
            return .rejected("encoding.alphabet")
        }
        guard let payload = PlankDrawingHandoffBytes.decodeBase64URL(characters),
              PlankDrawingHandoffBytes.encodeBase64URL(payload) == characters else {
            return .rejected("encoding.nonCanonical")
        }
        let result = validatePayload(payload, expectedVersion: path == "/v2" ? 2 : 1)
        // The frozen V1 wrong-path vector used /v2 with a V1 payload. It is
        // still a wrong path, not an upgrade of that payload.
        if path == "/v2", result == .rejected("version.unsupported") { return .rejected("url.path") }
        return result
    }

    /// Entry point 3, from the decoded payload bytes (§7.1 step 10 onward).
    static func validatePayload(_ payload: Data, expectedVersion: Int = 1) -> PlankDrawingHandoffParse {
        guard payload.count >= PlankDrawingHandoffContract.minDecodedBytes,
              payload.count <= PlankDrawingHandoffContract.maxDecodedBytes else {
            return .rejected("payload.length")
        }
        guard PlankDrawingHandoffBytes.isWellFormedUTF8(payload) else {
            return .rejected("payload.utf8")
        }
        guard let json = PlankJSONReader.parse(payload) else {
            return .rejected("payload.json")
        }
        guard let members = json.members else { return .rejected("payload.notObject") }
        guard !PlankDrawingHandoffBytes.containsDuplicateMember(json) else {
            return .rejected("payload.duplicateMember")
        }

        var lookup: [String: PlankJSON] = [:]
        for member in members { lookup[member.name] = member.value }

        // version is privileged: presence, type, then value, all resolved
        // before the member-set check (§7.1 step 15).
        guard let versionValue = lookup["version"] else { return .rejected("version.missing") }
        guard let version = versionValue.integerValue else { return .rejected("version.type") }
        guard version == expectedVersion && (version == 1 || version == 2) else {
            return .rejected("version.unsupported")
        }

        var frozen: Set<String> = [
            "version", "requestID", "displayName", "managementIdentity",
            "drawingIdentity", "drawingProtocol", "routes",
        ]
        if version == 2 { frozen.insert("bluetooth") }
        guard members.allSatisfy({ frozen.contains($0.name) }) else {
            return .rejected("link.unknownMember")
        }
        for name in ["requestID", "displayName", "managementIdentity",
                     "drawingIdentity", "drawingProtocol", "routes"] {
            guard lookup[name] != nil else { return .rejected("\(name).missing") }
        }

        guard let requestID = lookup["requestID"]!.stringValue else {
            return .rejected("requestID.type")
        }
        guard isCanonicalRequestID(requestID) else { return .rejected("requestID.invalid") }

        guard let displayName = lookup["displayName"]!.stringValue else {
            return .rejected("displayName.type")
        }
        guard isAcceptableDisplayName(displayName) else {
            return .rejected("displayName.invalid")
        }

        guard let managementIdentity = lookup["managementIdentity"]!.stringValue else {
            return .rejected("managementIdentity.type")
        }
        guard isCanonicalIdentity(managementIdentity) else {
            return .rejected("managementIdentity.invalid")
        }

        guard let drawingIdentity = lookup["drawingIdentity"]!.stringValue else {
            return .rejected("drawingIdentity.type")
        }
        guard isCanonicalIdentity(drawingIdentity) else {
            return .rejected("drawingIdentity.invalid")
        }
        guard drawingIdentity != managementIdentity else {
            return .rejected("drawingIdentity.collidesWithManagement")
        }

        if let reason = validateProtocol(lookup["drawingProtocol"]!) {
            return .rejected(reason)
        }

        var bluetoothIdentifier: UUID?
        if let bluetooth = lookup["bluetooth"] {
            guard let fields = bluetooth.members, Set(fields.map(\.name)) == ["linkType", "peripheralIdentifier"],
                  fields.first(where: { $0.name == "linkType" })?.value.integerValue == 1,
                  let text = fields.first(where: { $0.name == "peripheralIdentifier" })?.value.stringValue,
                  isCanonicalRequestID(text), let id = UUID(uuidString: text),
                  text != "00000000-0000-0000-0000-000000000000" else {
                return .rejected("bluetooth.invalid")
            }
            bluetoothIdentifier = id
        }
        switch validateRoutes(lookup["routes"]!, allowEmpty: bluetoothIdentifier != nil) {
        case let .rejection(reason):
            return .rejected(reason)
        case let .value(routes):
            return .accepted(PlankDrawingHandoffDescriptor(
                version: version,
                requestID: requestID,
                displayName: displayName,
                managementIdentity: managementIdentity,
                drawingIdentity: drawingIdentity,
                routes: routes, bluetoothIdentifier: bluetoothIdentifier
            ))
        }
    }

    // MARK: Field checks

    static func isCanonicalIdentity(_ text: String) -> Bool {
        guard text.utf8.count == PlankDrawingHandoffContract.identityHexLength else {
            return false
        }
        return text.utf8.allSatisfy {
            ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) ||
                ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f"))
        }
    }

    static func isCanonicalRequestID(_ text: String) -> Bool {
        let bytes = [UInt8](text.utf8)
        guard bytes.count == 36 else { return false }
        let hyphens = [8, 13, 18, 23]
        for (offset, byte) in bytes.enumerated() {
            if hyphens.contains(offset) {
                guard byte == UInt8(ascii: "-") else { return false }
                continue
            }
            let isDigit = byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
            let isLowerHex = byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f")
            guard isDigit || isLowerHex else { return false }
        }
        return true
    }

    static func isAcceptableDisplayName(_ text: String) -> Bool {
        let byteCount = text.utf8.count
        guard byteCount >= 1, byteCount <= PlankDrawingHandoffContract.maxDisplayNameBytes else {
            return false
        }
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { return false }
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func validateProtocol(_ value: PlankJSON) -> String? {
        guard let members = value.members else { return "drawingProtocol.type" }
        let frozen: Set<String> = ["name", "version", "rawHID", "linkType"]
        guard members.allSatisfy({ frozen.contains($0.name) }) else {
            return "drawingProtocol.unknownMember"
        }
        var lookup: [String: PlankJSON] = [:]
        for member in members { lookup[member.name] = member.value }

        guard let name = lookup["name"] else { return "drawingProtocol.name.missing" }
        guard name.stringValue == PlankDrawingHandoffContract.protocolName else {
            return "drawingProtocol.name"
        }
        guard let version = lookup["version"] else { return "drawingProtocol.version.missing" }
        guard version.integerValue == PlankDrawingHandoffContract.protocolVersion else {
            return "drawingProtocol.version"
        }
        guard let rawHID = lookup["rawHID"] else { return "drawingProtocol.rawHID.missing" }
        guard rawHID.integerValue == PlankDrawingHandoffContract.protocolRawHID else {
            return "drawingProtocol.rawHID"
        }
        guard let linkType = lookup["linkType"] else { return "drawingProtocol.linkType.missing" }
        guard linkType.integerValue == PlankDrawingHandoffContract.protocolLinkTypeTCP else {
            // linkType 1 is Bluetooth LE. Version 1 adds no Bluetooth drawing
            // transport and the link type is bound into the Noise prologue.
            return "drawingProtocol.linkType"
        }
        return nil
    }

    private static func validateRoutes(
        _ value: PlankJSON, allowEmpty: Bool = false
    ) -> PlankValidated<[PlankDrawingRoute]> {
        guard let elements = value.arrayValue else { return .rejection("routes.type") }
        guard elements.count >= (allowEmpty ? 0 : PlankDrawingHandoffContract.minRoutes),
              elements.count <= PlankDrawingHandoffContract.maxRoutes else {
            return .rejection("routes.count")
        }
        var routes: [PlankDrawingRoute] = []
        for element in elements {
            switch validateRoute(element) {
            case let .rejection(reason): return .rejection(reason)
            case let .value(route): routes.append(route)
            }
        }
        // Byte-identical address and port deduplicates rather than rejects.
        var seen = Set<String>()
        var surviving: [PlankDrawingRoute] = []
        for route in routes where seen.insert("\(route.address):\(route.port)").inserted {
            surviving.append(route)
        }
        guard allowEmpty || !surviving.isEmpty else { return .rejection("routes.count") }
        return .value(surviving)
    }

    private static func validateRoute(
        _ value: PlankJSON
    ) -> PlankValidated<PlankDrawingRoute> {
        guard let members = value.members else { return .rejection("route.type") }
        let frozen: Set<String> = ["address", "port", "interface", "kind"]
        guard members.allSatisfy({ frozen.contains($0.name) }) else {
            return .rejection("route.unknownMember")
        }
        var lookup: [String: PlankJSON] = [:]
        for member in members { lookup[member.name] = member.value }

        // An optional member set to null is a rejection; absence is absence.
        for optional in ["interface", "kind"] {
            if let present = lookup[optional], present.isNull {
                return .rejection("route.nullMember")
            }
        }

        guard let addressValue = lookup["address"] else { return .rejection("route.address.missing") }
        guard let address = addressValue.stringValue else { return .rejection("route.address.type") }
        guard address.utf8.count <= PlankDrawingHandoffContract.maxRouteAddressBytes else {
            return .rejection("route.address.tooLong")
        }
        guard !address.contains("%") else { return .rejection("route.address.scoped") }
        let family: PlankDrawingAddressFamily
        switch PlankDrawingAddress.classify(address) {
        case .notLiteral: return .rejection("route.address.notLiteral")
        case .nonCanonical: return .rejection("route.address.nonCanonical")
        case .mapped: return .rejection("route.address.mapped")
        case let .literal(parsed): family = parsed
        }
        switch PlankDrawingAddress.classification(of: family) {
        case .unspecified: return .rejection("route.address.unspecified")
        case .loopback: return .rejection("route.address.loopback")
        case .linkLocal: return .rejection("route.address.linkLocal")
        case .multicast: return .rejection("route.address.multicast")
        case .broadcast: return .rejection("route.address.broadcast")
        case .unicast: break
        }
        if case .ipv6 = family { return .rejection("route.address.familyUnsupported") }

        guard let portValue = lookup["port"] else { return .rejection("route.port.missing") }
        guard let port = portValue.integerValue, port >= 1, port <= 65535 else {
            return .rejection("route.port")
        }

        var interface: String?
        if let value = lookup["interface"] {
            guard let text = value.stringValue, isAcceptableInterface(text) else {
                return .rejection("route.interface")
            }
            interface = text
        }
        var kind: PlankDrawingRouteKind?
        if let value = lookup["kind"] {
            guard let text = value.stringValue,
                  let parsed = PlankDrawingRouteKind(rawValue: text) else {
                return .rejection("route.kind")
            }
            kind = parsed
        }
        return .value(PlankDrawingRoute(
            address: address, port: UInt16(port), interface: interface, kind: kind
        ))
    }

    private static func isAcceptableInterface(_ text: String) -> Bool {
        let bytes = [UInt8](text.utf8)
        guard bytes.count >= 1,
              bytes.count <= PlankDrawingHandoffContract.maxInterfaceBytes else { return false }
        return bytes.allSatisfy { byte in
            (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) ||
                (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) ||
                (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) ||
                byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") ||
                byte == UInt8(ascii: "-")
        }
    }
}

// MARK: - Trust gate (contract §10)

/// What PLANK already knows, supplied by the caller. The gate itself performs
/// no Keychain, network or discovery work.
struct PlankDrawingTrustEnvironment: Equatable {
    /// Drawing identities PLANK holds an explicit approval for, identity-indexed.
    var approvedDrawingIdentities: Set<String> = []
    /// Legacy route-keyed approvals, "address:port" to the pinned drawing
    /// identity. Used only to tell an identity *change* from a first sighting.
    var routeApprovals: [String: String] = [:]
    /// True while a PLANK desktop session is live.
    var desktopSessionActive = false
}

enum PlankDrawingHandoffDecision: Equatable {
    /// The pin is already approved. The route is still only a hint: the
    /// authenticated drawing handshake must complete before it is accepted.
    case verifyThenConnect(PlankDrawingRouteSelection)
    case duplicateRequest
    case desktopSessionActive
    case drawingIdentityMismatch(saved: String, received: String)
    case needsExplicitApproval(drawingIdentity: String)

    var outcomeIdentifier: String {
        switch self {
        case .verifyThenConnect: "handoffReady"
        case .duplicateRequest: "requestID.duplicate"
        case .desktopSessionActive: "trust.sessionActive"
        case .drawingIdentityMismatch: "trust.drawingIdentityMismatch"
        case .needsExplicitApproval: "trust.unknownDrawingIdentity"
        }
    }
}

/// Route candidates for one approved drawing identity. Order is descriptor
/// order; interface metadata is display-only.
struct PlankDrawingRouteSelection: Equatable {
    let drawingIdentity: String
    let displayName: String
    let routes: [PlankDrawingRoute]
    var bluetoothIdentifier: UUID? = nil

    func route(forAttempt attempt: Int) -> PlankDrawingRoute? {
        guard !routes.isEmpty else { return nil }
        return routes[((attempt % routes.count) + routes.count) % routes.count]
    }

    var routeLabel: String { routes.first?.displayLabel ?? (bluetoothIdentifier != nil ? "Bluetooth" : "Network") }
}

/// Bounded, process-lifetime, non-persistent request deduplication (§10.5). A
/// repeated requestID proves nothing and a fresh one confers nothing: the set
/// only prevents a second confirmation or connection attempt for one tap.
struct PlankDrawingHandoffGate {
    private var acceptedRequestIDs: [String] = []

    var recentRequestIDCount: Int { acceptedRequestIDs.count }

    func hasAccepted(_ requestID: String) -> Bool {
        acceptedRequestIDs.contains(requestID)
    }

    mutating func evaluate(
        _ descriptor: PlankDrawingHandoffDescriptor,
        environment: PlankDrawingTrustEnvironment
    ) -> PlankDrawingHandoffDecision {
        if acceptedRequestIDs.contains(descriptor.requestID) {
            return .duplicateRequest
        }
        // Never interrupt a stroke because another app opened a URL.
        if environment.desktopSessionActive { return .desktopSessionActive }

        if !environment.approvedDrawingIdentities.contains(descriptor.drawingIdentity) {
            for route in descriptor.routes {
                if let saved = environment.routeApprovals["\(route.address):\(route.port)"],
                   saved != descriptor.drawingIdentity {
                    // Do not replace the pin and do not delete the approval.
                    return .drawingIdentityMismatch(
                        saved: saved, received: descriptor.drawingIdentity
                    )
                }
            }
            return .needsExplicitApproval(drawingIdentity: descriptor.drawingIdentity)
        }

        acceptedRequestIDs.append(descriptor.requestID)
        if acceptedRequestIDs.count > PlankDrawingHandoffContract.recentRequestIDCapacity {
            acceptedRequestIDs.removeFirst(
                acceptedRequestIDs.count - PlankDrawingHandoffContract.recentRequestIDCapacity
            )
        }
        return .verifyThenConnect(PlankDrawingRouteSelection(
            drawingIdentity: descriptor.drawingIdentity,
            displayName: descriptor.displayName,
            routes: descriptor.routes, bluetoothIdentifier: descriptor.bluetoothIdentifier
        ))
    }
}
