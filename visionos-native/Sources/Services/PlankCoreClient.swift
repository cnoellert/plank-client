import Combine
import Foundation

enum ConnectionPhase: Equatable, Sendable {
    case idle
    case probing
    case needsCredentials(PlankHostIdentity)
    case authenticating(PlankHostIdentity)
    case authenticated(PlankHostIdentity, PlankAuthentication)
    case failed(String)
}

@MainActor
final class PlankCoreClient: ObservableObject {
    @Published private(set) var phase: ConnectionPhase = .idle

    private var httpClient: PlankHTTPClient?
    private var lastIdentity: PlankHostIdentity?

    func connect(to host: HostBookmark) async {
        phase = .probing
        do {
            let client = try PlankHTTPClient(host: host)
            let identity = try await client.fetchServerInfo()
            guard identity.supportsAuthentication else {
                throw PlankHTTPError.invalidResponse("This Host does not advertise PLANK authentication.")
            }
            httpClient = client
            lastIdentity = identity
            phase = .needsCredentials(identity)
        } catch {
            httpClient = nil
            lastIdentity = nil
            phase = .failed(Self.message(for: error))
        }
    }

    func authenticate(username: String, password: String) async {
        guard let httpClient,
              let identity = lastIdentity else {
            phase = .failed("The workstation connection is no longer ready.")
            return
        }

        phase = .authenticating(identity)
        do {
            let authentication = try await httpClient.authenticate(
                username: username,
                password: password
            )
            phase = .authenticated(identity, authentication)
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    func retryCredentials() {
        guard let identity = lastIdentity else { return }
        phase = .needsCredentials(identity)
    }

    func reset() {
        httpClient = nil
        lastIdentity = nil
        phase = .idle
    }

    private static func message(for error: Error) -> String {
        if let error = error as? LocalizedError,
           let description = error.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
