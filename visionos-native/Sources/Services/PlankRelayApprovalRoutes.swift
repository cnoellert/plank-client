// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network
import Security

enum PlankRelayError: LocalizedError {
    case keychain(OSStatus)
    case random
    case crypto
    case connectionClosed
    case connectionTimedOut
    case pairingRejected

    var errorDescription: String? {
        switch self {
        case let .keychain(status): "Relay trust storage failed (\(status))."
        case .random: "Could not generate a secure headset approval code."
        case .crypto: "The Relay approval exchange failed verification."
        case .connectionClosed: "The tablet Relay closed the connection."
        case .connectionTimedOut: "The Relay could not be reached at the network address Relay Setup provided."
        case .pairingRejected: "The Relay rejected headset approval. Check the ExpressKey order and try again."
        }
    }
}


/// Address failures may try the next advertised route. Verification, storage,
/// cancellation and TLS failures cannot be repaired by changing an address.
@MainActor
enum PlankRelayApprovalRoutes {
    static func canTryNextRoute(after error: Error) -> Bool {
        if let relay = error as? PlankRelayError {
            switch relay {
            case .connectionTimedOut, .connectionClosed: return true
            default: return false
            }
        }
        guard let network = error as? NWError else { return false }
        switch network {
        case let .posix(code):
            switch code {
            case .ECONNREFUSED, .ECONNRESET, .ECONNABORTED, .ENETUNREACH,
                 .EHOSTUNREACH, .EHOSTDOWN, .ENETDOWN, .ENETRESET,
                 .ETIMEDOUT, .EADDRNOTAVAIL, .EPIPE, .ENOTCONN:
                return true
            default: return false
            }
        case .dns: return true
        case .tls: return false
        default: return false
        }
    }

    /// Each supplied route is attempted at most once, using the existing
    /// per-attempt connection/approval deadlines. Preserve the final error.
    static func approve<Route, Value>(routes: [Route],
                                     attempt: @MainActor (Route) async throws -> Value) async throws -> Value {
        var lastError: Error = PlankRelayError.connectionTimedOut
        for route in routes {
            try Task.checkCancellation()
            do {
                let value = try await attempt(route)
                try Task.checkCancellation()
                return value
            } catch {
                try Task.checkCancellation()
                guard canTryNextRoute(after: error) else { throw error }
                lastError = error
            }
        }
        throw lastError
    }
}
