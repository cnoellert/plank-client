// SPDX-License-Identifier: GPL-3.0-or-later
// swiftc -Onone -parse-as-library Sources/Services/PlankRelayApprovalRoutes.swift \
//   Tests/PlankRelayApprovalRoutesTests.swift -o out && out
import Foundation
import Network

@main
@MainActor
enum PlankRelayApprovalRoutesTests {
    static var checks = 0

    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }

    static func main() async throws {
        let routeErrors: [Error] = [
            PlankRelayError.connectionTimedOut, PlankRelayError.connectionClosed,
            NWError.posix(.ECONNREFUSED), NWError.posix(.ECONNRESET),
            NWError.posix(.ECONNABORTED), NWError.posix(.ENETUNREACH),
            NWError.posix(.EHOSTUNREACH), NWError.posix(.EHOSTDOWN),
            NWError.posix(.ENETDOWN), NWError.posix(.ENETRESET),
            NWError.posix(.ETIMEDOUT), NWError.posix(.EADDRNOTAVAIL),
            NWError.posix(.EPIPE), NWError.posix(.ENOTCONN), NWError.dns(-65538),
        ]
        for error in routeErrors {
            var attempts: [Int] = []
            let result: String = try await PlankRelayApprovalRoutes.approve(routes: [1, 2, 3]) { route in
                attempts.append(route)
                if route == 1 { throw error }
                return "proved identity"
            }
            check(result == "proved identity", "alternate route must succeed after \(error)")
            check(attempts == [1, 2], "ordered routes stop after success")
        }

        let terminalErrors: [Error] = [
            PlankRelayError.pairingRejected, PlankRelayError.crypto,
            PlankRelayError.keychain(-1), PlankRelayError.random,
            CancellationError(), NWError.posix(.ECANCELED),
            NWError.posix(.ENOMEM), NWError.tls(-9807),
            NSError(domain: "unexpected", code: 1),
        ]
        for error in terminalErrors {
            var attempts: [Int] = []
            do {
                let _: String = try await PlankRelayApprovalRoutes.approve(routes: [1, 2]) { route in
                    attempts.append(route)
                    throw error
                }
                preconditionFailure("terminal approval failure must escape")
            } catch {
                check(attempts == [1], "terminal failure cannot try another identity/address")
            }
        }

        var exhausted: [Int] = []
        do {
            let _: String = try await PlankRelayApprovalRoutes.approve(routes: [1, 2]) { route in
                exhausted.append(route)
                throw NWError.posix(route == 1 ? .ECONNREFUSED : .EHOSTUNREACH)
            }
            preconditionFailure("exhausted routes cannot approve")
        } catch let error as NWError {
            check(error == .posix(.EHOSTUNREACH), "preserve the final native network error")
            check(exhausted == [1, 2], "each route attempted exactly once")
        }

        // Cancel after an in-flight attempt has produced a matching key.
        // It must not be returned to the caller that stores the approval.
        let lateResult = Task { @MainActor in
            var attempts = 0
            do {
                let _: String = try await PlankRelayApprovalRoutes.approve(routes: [1, 2]) { _ in
                    attempts += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                    return "late matching key"
                }
                preconditionFailure("canceled approval must discard a late key")
            } catch is CancellationError {
                check(attempts == 1, "cancel cannot start an alternate attempt")
            }
        }
        try await lateResult.value

        do {
            let _: String = try await PlankRelayApprovalRoutes.approve(routes: []) { _ in
                preconditionFailure("empty route list cannot start an attempt")
            }
            preconditionFailure("empty routes cannot approve")
        } catch PlankRelayError.connectionTimedOut {
            check(true, "empty routes retain the existing unreachable outcome")
        }
        print("PlankRelayApprovalRoutesTests: \(checks) checks passed")
    }
}
