// A paired tablet is part of the desktop session's input contract. A Relay
// socket alone is not enough: the Host must acknowledge the current attachment.
struct PlankTabletInputPolicy {
    enum Release: Equatable {
        case mouse(UInt8)
        case key(UInt16, modifiers: UInt8)
    }

    private enum State: Equatable {
        case noTablet
        case waiting
        case ready
        case withoutTablet
    }

    private var state: State = .noTablet
    private var suppressedMouseButtons = Set<UInt8>()
    private var forwardedMouseButtons = Set<UInt8>()
    private var suppressedKeys = Set<UInt16>()
    private var forwardedKeys: [UInt16: UInt8] = [:]

    var waitsForTablet: Bool { state == .waiting }
    var forwardsTabletReports: Bool { state == .ready }

    mutating func begin(hasPairedTablet: Bool) {
        state = hasPairedTablet ? .waiting : .noTablet
        suppressedMouseButtons.removeAll()
        forwardedMouseButtons.removeAll()
        suppressedKeys.removeAll()
        forwardedKeys.removeAll()
    }

    mutating func updatePreflight(ready: Bool) -> [Release] {
        guard state == .waiting || state == .ready else { return [] }
        let wasReady = state == .ready
        state = ready ? .ready : .waiting
        guard wasReady && !ready else { return [] }
        let releases = forwardedMouseButtons.sorted().map(Release.mouse) +
            forwardedKeys.sorted { $0.key < $1.key }.map {
                Release.key($0.key, modifiers: $0.value)
            }
        suppressedMouseButtons.formUnion(forwardedMouseButtons)
        forwardedMouseButtons.removeAll()
        suppressedKeys.formUnion(forwardedKeys.keys)
        forwardedKeys.removeAll()
        return releases
    }

    mutating func continueWithoutTablet() {
        guard state == .waiting else { return }
        state = .withoutTablet
    }

    mutating func allowsMouseButton(_ number: UInt8, pressed: Bool) -> Bool {
        if waitsForTablet {
            if pressed { suppressedMouseButtons.insert(number) }
            else { suppressedMouseButtons.remove(number) }
            return false
        }
        if !pressed && suppressedMouseButtons.remove(number) != nil { return false }
        if pressed {
            suppressedMouseButtons.remove(number)
            forwardedMouseButtons.insert(number)
        } else {
            forwardedMouseButtons.remove(number)
        }
        return true
    }

    mutating func allowsKey(_ code: UInt16, pressed: Bool, modifiers: UInt8) -> Bool {
        if waitsForTablet {
            if pressed { suppressedKeys.insert(code) }
            else { suppressedKeys.remove(code) }
            return false
        }
        if !pressed && suppressedKeys.remove(code) != nil { return false }
        if pressed {
            suppressedKeys.remove(code)
            forwardedKeys[code] = modifiers
        } else {
            forwardedKeys.removeValue(forKey: code)
        }
        return true
    }
}
