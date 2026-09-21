import Combine
import Foundation

enum ConnectionPhase: Equatable, Sendable {
    case idle
    case preparing
    case needsCoreIntegration
    case failed(String)
}

@MainActor
final class PlankCoreClient: ObservableObject {
    @Published private(set) var phase: ConnectionPhase = .idle

    func connect(to host: HostBookmark) async {
        phase = .preparing
        try? await Task.sleep(for: .milliseconds(250))
        phase = .needsCoreIntegration
    }

    func reset() {
        phase = .idle
    }
}

