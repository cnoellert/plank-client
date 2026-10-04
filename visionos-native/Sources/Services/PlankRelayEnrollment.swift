// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network

@MainActor
enum PlankRelayEnrollmentProof {
    static func prove(_ request: DrawingRegistrationRequest,
                      descriptor: PlankDrawingHandoffDescriptor) async throws -> String {
        guard let target = Data(hexadecimal: descriptor.drawingIdentity), target.count == 32,
              let id = Data(hexadecimal: request.requestID), id.count == 16 else {
            throw DrawingRegistrationError.invalidRequest
        }
        let privateKey = try PlankRelayKeys.clientPrivateKey()
        var publicKey = [UInt8](repeating: 0, count: 32)
        let valid = privateKey.withUnsafeBytes { bytes in
            pltr_noise_public_key(bytes.bindMemory(to: UInt8.self).baseAddress, &publicKey)
        }
        guard valid == 0, Data(publicKey).hexadecimalText == request.clientIdentity else {
            throw DrawingRegistrationError.invalidRequest
        }
        let routeDeadline = ContinuousClock.now + .seconds(40)
        var lastError: any Error = PlankRelayError.connectionTimedOut
        for route in descriptor.routes {
            try Task.checkCancellation()
            guard ContinuousClock.now < routeDeadline,
                  let port = NWEndpoint.Port(rawValue: route.port) else { break }
            let stream = PlankRelayTCP(endpoint: .hostPort(host: NWEndpoint.Host(route.address), port: port))
            defer { stream.cancel() }
            // Only connection establishment retries alternate routes. Once a
            // proof is sent it may have claimed the single-use grant; never
            // replay that mutation after an ambiguous result.
            do { try await stream.connect() }
            catch {
                try Task.checkCancellation()
                guard PlankRelayApprovalRoutes.canTryNextRoute(after: error) else { throw error }
                lastError = error
                continue
            }
            try await proveConnected(stream, privateKey: privateKey, target: target, requestID: id)
            return descriptor.drawingIdentity
        }
        throw lastError
    }

    private static func proveConnected(_ stream: PlankRelayTCP, privateKey: Data,
                                      target: Data, requestID: Data) async throws {
        let codec = privateKey.withUnsafeBytes { privateBytes in
            target.withUnsafeBytes { targetBytes in
                requestID.withUnsafeBytes { id in
                    pltr_client_enrollment_create(privateBytes.bindMemory(to: UInt8.self).baseAddress,
                        targetBytes.bindMemory(to: UInt8.self).baseAddress, id.bindMemory(to: UInt8.self).baseAddress)
                }
            }
        }
        guard let codec else { throw PlankRelayError.crypto }
        defer { pltr_client_enrollment_destroy(codec) }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(12))
            if !Task.isCancelled { stream.cancel() }
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            var output = [UInt8](repeating: 0, count: 256)
            var written = 0
            guard pltr_client_enrollment_start(codec, &output, output.count, &written) == 0 else {
                throw PlankRelayError.crypto
            }
            try await stream.send(Data(output.prefix(written)))
            while true {
                try Task.checkCancellation()
                let bytes = try await stream.receive()
                var offset = 0
                while offset < bytes.count {
                    var consumed = 0
                    let result = bytes.withUnsafeBytes { input in
                        pltr_client_enrollment_receive(codec,
                            input.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset), bytes.count-offset,
                            &consumed, &output, output.count, &written)
                    }
                    guard result >= 0, consumed > 0, consumed <= bytes.count-offset else {
                        throw DrawingRegistrationError.invalidRequest
                    }
                    offset += consumed
                    // Cancel can win before the commit confirmation is sent.
                    try Task.checkCancellation()
                    if written > 0 { try await stream.send(Data(output.prefix(written))) }
                    if result == 2 {
                        guard offset == bytes.count else { throw DrawingRegistrationError.invalidRequest }
                        return
                    }
                }
            }
        } onCancel: { stream.cancel() }
    }
}
