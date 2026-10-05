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
        let routes = descriptor.routes.map(PlankRelayDrawingRoute.network) +
            (descriptor.bluetoothIdentifier.map { [PlankRelayDrawingRoute.bluetooth($0)] } ?? [])
        for route in routes {
            try Task.checkCancellation()
            guard ContinuousClock.now < routeDeadline else { break }
            let transport: any PlankRelayByteTransport
            switch route {
            case let .network(network):
                guard let port = NWEndpoint.Port(rawValue: network.port) else { continue }
                transport = PlankRelayTCPTransport(endpoint: .hostPort(host: NWEndpoint.Host(network.address), port: port))
            case let .bluetooth(identifier): transport = PlankRelayBluetoothTransport(identifier: identifier)
            }
            let stream = PlankEnrollmentByteStream(transport: transport)
            defer { stream.cancel() }
            // Only connection establishment retries alternate routes. Once a
            // proof is sent it may have claimed the single-use grant; never
            // replay that mutation after an ambiguous result.
            let connectionDeadline: ContinuousClock.Instant
            switch route {
            case .network: connectionDeadline = min(routeDeadline, ContinuousClock.now + .seconds(6))
            case .bluetooth: connectionDeadline = routeDeadline
            }
            do { try await stream.connect(deadline: connectionDeadline) }
            catch {
                try Task.checkCancellation()
                guard PlankRelayApprovalRoutes.canTryNextRoute(after: error) || error is PlankDrawingBluetoothError else { throw error }
                lastError = error
                continue
            }
            try await proveConnected(stream, privateKey: privateKey, target: target, requestID: id)
            return descriptor.drawingIdentity
        }
        throw lastError
    }

    private static func proveConnected(_ stream: PlankEnrollmentByteStream, privateKey: Data,
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


// The PLEN proof is identical on both byte transports and never acquires
// capture. A transport retry is allowed only before its first proof byte.
private final class PlankEnrollmentByteStream: @unchecked Sendable {
    let transport: any PlankRelayByteTransport
    private let queue = DispatchQueue(label: "la.instinctual.plank.enrollment")
    private let lock = NSLock()
    private var waiter: PlankEnrollmentConnectWaiter?
    init(transport: any PlankRelayByteTransport) { self.transport = transport }
    func connect(deadline: ContinuousClock.Instant) async throws {
        let timeout = Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            if !Task.isCancelled { cancel() }
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let pending = PlankEnrollmentConnectWaiter(continuation)
                lock.withLock { waiter = pending }
                if Task.isCancelled { cancel(); return }
                transport.start(queue: queue,
                    ready: { pending.finish(.success(())) },
                    failed: { pending.finish(.failure($0)) })
            }
        } onCancel: { self.cancel() }
    }
    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            transport.send(data) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            transport.receive { data, closed, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: PlankRelayError.connectionClosed) }
            }
        }
    }
    func cancel() {
        lock.withLock { waiter }?.finish(.failure(PlankRelayError.connectionTimedOut))
        transport.cancel()
    }
}

private final class PlankEnrollmentConnectWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    @discardableResult
    func finish(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
        return pending != nil
    }
}
