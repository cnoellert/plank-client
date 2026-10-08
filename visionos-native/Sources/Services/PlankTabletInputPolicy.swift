// A paired tablet is part of the desktop session's input contract. A Relay
// socket alone is not enough: the Host must acknowledge the current attachment.
struct PlankTabletInputPolicy {
    enum AvailabilityExpiry: Equatable {
        case none
        case continueWithoutTablet
        case keepRecovering
    }

    enum Release: Equatable {
        case mouse(UInt8)
        case key(UInt16, modifiers: UInt8)
    }

    private enum State: Equatable {
        case noTablet
        case waiting
        case ready
        case recovering
        case withoutTablet
    }

    private var state: State = .noTablet
    private var relayAttached = false
    private var hasBeenReady = false
    private var suppressedMouseButtons = Set<UInt8>()
    private var forwardedMouseButtons = Set<UInt8>()
    private var suppressedKeys = Set<UInt16>()
    private var forwardedKeys: [UInt16: UInt8] = [:]

    var waitsForTablet: Bool { state == .waiting }
    var showsBlockingOverlay: Bool { waitsForTablet && relayAttached }
    var shouldContinueWhenUnavailable: Bool { waitsForTablet && !relayAttached }
    var forwardsTabletReports: Bool { state == .ready }

    mutating func begin(hasPairedTablet: Bool) {
        state = hasPairedTablet ? .waiting : .noTablet
        relayAttached = false
        hasBeenReady = false
        suppressedMouseButtons.removeAll()
        forwardedMouseButtons.removeAll()
        suppressedKeys.removeAll()
        forwardedKeys.removeAll()
    }

    mutating func updatePreflight(ready: Bool, relayAttached: Bool = false) -> [Release] {
        guard state == .waiting || state == .ready || state == .recovering else { return [] }
        let previouslyAllowedInput = state == .ready || state == .recovering
        self.relayAttached = relayAttached
        if ready {
            state = .ready
            hasBeenReady = true
        } else if state != .recovering || relayAttached {
            // After a live outage the desktop remains usable while recovery
            // continues. Once a tablet is claimed again, guard input until
            // its fresh descriptors and Host acknowledgement have passed.
            state = .waiting
        }
        guard previouslyAllowedInput && state == .waiting else { return [] }
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
        relayAttached = false
    }

    mutating func expireAvailabilityGrace() -> AvailabilityExpiry {
        guard shouldContinueWhenUnavailable else { return .none }
        if hasBeenReady {
            state = .recovering
            return .keepRecovering
        }
        continueWithoutTablet()
        return .continueWithoutTablet
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
