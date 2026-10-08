// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Network

protocol PlankRelayByteTransport: AnyObject, Sendable {
    func start(queue: DispatchQueue, ready: @escaping @Sendable () -> Void,
               failed: @escaping @Sendable (any Error) -> Void)
    func receive(_ completion: @escaping @Sendable (Data?, Bool, (any Error)?) -> Void)
    func send(_ data: Data, completion: @escaping @Sendable ((any Error)?) -> Void)
    func cancel()
}

final class PlankRelayTCPTransport: PlankRelayByteTransport, @unchecked Sendable {
    private let connection: NWConnection
    init(endpoint: NWEndpoint) { connection = NWConnection(to: endpoint, using: .tcp) }
    func start(queue: DispatchQueue, ready: @escaping @Sendable () -> Void,
               failed: @escaping @Sendable (any Error) -> Void) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready()
            case let .failed(error): failed(error)
            case .cancelled: failed(CancellationError())
            default: break
            }
        }
        connection.start(queue: queue)
    }
    func receive(_ completion: @escaping @Sendable (Data?, Bool, (any Error)?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, done, error in
            completion(data, done, error)
        }
    }
    func send(_ data: Data, completion: @escaping @Sendable ((any Error)?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { completion($0) })
    }
    func cancel() { connection.stateUpdateHandler = nil; connection.cancel() }
}
