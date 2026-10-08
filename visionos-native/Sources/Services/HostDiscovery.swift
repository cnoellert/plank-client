import Combine
import Foundation
import Network

@MainActor
final class HostDiscovery: ObservableObject {
    @Published private(set) var hosts: [DiscoveredHost] = []
    @Published private(set) var isSearching = false

    private var browser: NWBrowser?
    private var generation = UUID()

    func start() {
        guard browser == nil else { return }
        let generation = UUID()
        self.generation = generation

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: "_nvstream._tcp", domain: nil),
            using: parameters
        )

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == generation, self.browser != nil else { return }
                switch state {
                case .ready:
                    self.isSearching = true
                case .failed, .cancelled:
                    self.isSearching = false
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> DiscoveredHost? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return DiscoveredHost(
                    serviceName: name,
                    endpointDescription: name
                )
            }
            .sorted { $0.serviceName.localizedStandardCompare($1.serviceName) == .orderedAscending }

            Task { @MainActor in
                guard let self, self.generation == generation, self.browser != nil else { return }
                self.hosts = found
            }
        }

        self.browser = browser
        browser.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        generation = UUID()
        browser?.cancel()
        browser = nil
        isSearching = false
        hosts = []
    }
}
