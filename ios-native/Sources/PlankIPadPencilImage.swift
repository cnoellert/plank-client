// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import CoreGraphics
import Foundation
import Network
import UIKit

/// Optional, foreground reference-image consent is separate from Pencil consent.
/// Image frames reach passive UIKit subscribers without publishing SwiftUI state.
@MainActor final class PlankIPadPencilImageReceiver: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var intensity = 0.35
    @Published private(set) var status = "Image overlay is off"
    private var privateKey: Data?
    private var serviceName: String?
    private var binding: PlankPencilSessionBinding?
    private var dimensions: (width: Int, height: Int)?
    private var listener: NWListener?
    private var peer: PlankPencilImagePeer?
    private var decoder: PlankIPadPencilImageDecoder?
    private var mailbox: PlankIPadPencilImagePresentationMailbox?
    private var expiry: DispatchSourceTimer?
    private var generation = UUID(), peerID = UUID()
    private var image: CGImage?
    private var receivedAt: UInt64 = 0
    private var subscribers: [ObjectIdentifier: PlankIPadPencilImageWeakView] = [:]
    private static let maximumAge: UInt64 = 1_500_000_000

    /// Makes the image service available for this foreground sharing lifetime.
    /// Availability alone does not enable image reception or authorize a peer.
    func start(privateKey: Data, serviceName: String) throws {
        stop()
        guard privateKey.count == 32, !serviceName.isEmpty else { throw PlankPencilWireError.invalid }
        self.privateKey = privateKey; self.serviceName = serviceName
        status = "Image overlay is off"
    }
    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if value { beginListening() }
        else { endListening(); status = "Image overlay is off" }
    }
    func setIntensity(_ value: Double) {
        let next = value.isFinite ? min(1, max(0, value)) : 0.35
        guard next != intensity else { return }
        intensity = next; updateSubscribers()
    }
    func authorize(_ value: PlankPencilSessionBinding) {
        guard value.peerKey.count == 32, value.transcriptHash.count == 64 else { revoke(); return }
        guard binding != value else { return }
        endMedia(); dimensions = nil; binding = value
        if enabled { status = "Waiting for the client’s reference image" }
    }
    func configureDimensions(width: Int, height: Int) {
        guard width > 1, height > 1, width <= 65536, height <= 65536 else {
            dimensions = nil; decoder?.configureDimensions(nil); clearImage(); return
        }
        guard dimensions?.width != width || dimensions?.height != height else { return }
        dimensions = (width, height)
        decoder?.configureDimensions(dimensions); clearImage()
    }
    func revoke() {
        binding = nil; dimensions = nil; endMedia()
        if enabled { status = "Waiting for an approved Pencil connection" }
    }
    func stop() {
        endListening(); binding = nil; dimensions = nil; privateKey = nil; serviceName = nil
        enabled = false; status = "Image overlay is off"
    }
    private func beginListening() {
        guard enabled, let privateKey, let serviceName else {
            status = "Start Pencil sharing to use the image overlay"; return
        }
        do {
            let next = try NWListener(using: .tcp, on: .any)
            next.service = .init(name: serviceName, type: "_plank-pencil-image._tcp", domain: "local.")
            next.service?.noAutoRename = true
            next.newConnectionLimit = 1
            generation = UUID(); let current = generation
            next.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in self?.accept(connection, key: privateKey, generation: current) }
            }
            next.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == current, self.enabled else { return }
                    switch state {
                    case .ready: self.status = self.binding == nil
                        ? "Waiting for an approved Pencil connection" : "Waiting for the client’s reference image"
                    case .failed:
                        self.endListening(); self.status = "Reference image unavailable. Pencil sharing is unchanged."
                    default: break
                    }
                }
            }
            listener = next; next.start(queue: DispatchQueue(label: "la.instinctual.plank.pencil.image.listen", qos: .utility))
        } catch { endListening(); status = "Reference image unavailable. Pencil sharing is unchanged." }
    }
    private func accept(_ connection: NWConnection, key: Data, generation current: UUID) {
        guard enabled, generation == current, peer == nil, let binding else {
            connection.cancel(); listener?.newConnectionLimit = 1; return
        }
        let id = UUID(); peerID = id
        let presentation = PlankIPadPencilImagePresentationMailbox { [weak self] result in
            guard let self, self.enabled, self.generation == current, self.peerID == id else { return }
            switch result {
            case let .image(decoded):
                let now = DispatchTime.now().uptimeNanoseconds
                guard self.decoder?.isCurrent(decoded.revision) == true,
                      now >= decoded.receivedAt, now - decoded.receivedAt < Self.maximumAge else { return }
                self.image = decoded.image; self.receivedAt = decoded.receivedAt
                if self.status != "Receiving reference image" { self.status = "Receiving reference image" }
                self.updateSubscribers(); self.startExpiry()
            case let .failure(revision):
                guard self.decoder?.isCurrent(revision) == true else { return }
                self.endMedia(); self.status = "Reference image unavailable. Pencil sharing is unchanged."
            }
        }
        let decode = PlankIPadPencilImageDecoder(dimensions: dimensions, presentation: presentation)
        do {
            let next = try PlankPencilImagePeer(connection: connection, privateKey: key,
                                                binding: binding, initiator: false) { [weak self, weak decode] event in
                switch event {
                case .ready:
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == current, self.peerID == id else { return }
                        if self.image == nil { self.status = "Waiting for the client’s reference image" }
                    }
                case let .frame(frame): decode?.offer(frame)
                case .ended:
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == current, self.peerID == id else { return }
                        self.endMedia(); self.status = "Reference image unavailable. Pencil sharing is unchanged."
                    }
                }
            }
            mailbox = presentation; decoder = decode; peer = next; next.start()
        } catch {
            decode.invalidate(); presentation.invalidate(); connection.cancel()
            listener?.newConnectionLimit = 1
            status = "Reference image unavailable. Pencil sharing is unchanged."
        }
    }
    private func endListening() {
        generation = UUID()
        listener?.newConnectionHandler = nil; listener?.stateUpdateHandler = nil
        listener?.cancel(); listener = nil
        endMedia()
    }
    private func endMedia() {
        peerID = UUID()
        decoder?.invalidate(); decoder = nil
        mailbox?.invalidate(); mailbox = nil
        peer?.close(); peer = nil
        listener?.newConnectionLimit = 1
        clearImage()
    }
    private func clearImage() {
        image = nil; receivedAt = 0
        expiry?.setEventHandler {}; expiry?.cancel(); expiry = nil
        updateSubscribers()
    }
    private func startExpiry() {
        guard expiry == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.expireImage() }
        }
        expiry = timer; timer.resume()
    }
    private func expireImage() {
        guard image != nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= receivedAt, now - receivedAt >= Self.maximumAge else { return }
        clearImage()
        if enabled, peer != nil { status = "Reference image paused. Pencil sharing is unchanged." }
    }
    fileprivate func subscribe(_ view: PlankIPadPencilImageView) {
        subscribers[ObjectIdentifier(view)] = PlankIPadPencilImageWeakView(view)
        expireImage(); view.present(image, intensity: intensity)
    }
    fileprivate func unsubscribe(_ view: PlankIPadPencilImageView) {
        unsubscribe(id: ObjectIdentifier(view))
    }
    fileprivate func unsubscribe(id: ObjectIdentifier) { subscribers.removeValue(forKey: id) }
    private func updateSubscribers() {
        subscribers = subscribers.filter { $0.value.view != nil }
        for value in subscribers.values { value.view?.present(image, intensity: intensity) }
    }
}

@MainActor private final class PlankIPadPencilImageWeakView {
    weak var view: PlankIPadPencilImageView?
    init(_ view: PlankIPadPencilImageView) { self.view = view }
}

/// Its owner places this view in the EXISTING Pencil viewport rectangle. Resize
/// therefore follows Match Desktop or Full Pad, without a second fit/crop map.
@MainActor final class PlankIPadPencilImageView: UIView {
    private weak var receiver: PlankIPadPencilImageReceiver?
    private var subscribed = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; isAccessibilityElement = false
        backgroundColor = .clear; clipsToBounds = true
        layer.contentsGravity = .resize
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit {
        let id = ObjectIdentifier(self)
        if let receiver {
            Task { @MainActor [weak receiver] in receiver?.unsubscribe(id: id) }
        }
    }
    func configure(receiver: PlankIPadPencilImageReceiver?) {
        if self.receiver !== receiver {
            if subscribed { self.receiver?.unsubscribe(self) }
            self.receiver = receiver; subscribed = false; present(nil, intensity: 0)
        }
        if window != nil, !subscribed, let receiver {
            receiver.subscribe(self); subscribed = true
        }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            if subscribed { receiver?.unsubscribe(self) }; subscribed = false
            present(nil, intensity: 0)
        } else if !subscribed, let receiver {
            receiver.subscribe(self); subscribed = true
        }
    }
    fileprivate func present(_ image: CGImage?, intensity: Double) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.contents = image; layer.opacity = Float(intensity)
        CATransaction.commit()
    }
}

private struct PlankIPadPencilDecodedImage: @unchecked Sendable {
    let image: CGImage
    let receivedAt: UInt64
    let revision: UInt64
}
private enum PlankIPadPencilImagePresentation: Sendable {
    case image(PlankIPadPencilDecodedImage)
    case failure(UInt64)
}

/// One decoded image waiting for one main-queue delivery. A slow UI replaces the
/// waiting image; it never accumulates frame Tasks or an unbounded delivery queue.
private final class PlankIPadPencilImagePresentationMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private let deliver: @MainActor @Sendable (PlankIPadPencilImagePresentation) -> Void
    private var latest: PlankIPadPencilImagePresentation?
    private var scheduled = false, closed = false
    init(deliver: @escaping @MainActor @Sendable (PlankIPadPencilImagePresentation) -> Void) { self.deliver = deliver }
    func offer(_ value: PlankIPadPencilImagePresentation) {
        lock.lock(); guard !closed else { lock.unlock(); return }
        latest = value; let wake = !scheduled
        if wake { scheduled = true }; lock.unlock()
        if wake { DispatchQueue.main.async { [weak self] in self?.drain() } }
    }
    func invalidate() { lock.lock(); closed = true; latest = nil; lock.unlock() }
    private func drain() {
        lock.lock()
        let item = !closed ? latest : nil; latest = nil; scheduled = false
        lock.unlock()
        if let item { MainActor.assumeIsolated { deliver(item) } }
    }
}

/// Independent latest-only decoder. Source identity/order are admitted before
/// ImageIO receives compressed bytes; ImageIO validates encoded size itself.
private final class PlankIPadPencilImageDecoder: @unchecked Sendable {
    private struct Pending { let frame: PlankPencilImageFrame; let revision: UInt64 }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "la.instinctual.plank.pencil.image.decode", qos: .utility)
    private let presentation: PlankIPadPencilImagePresentationMailbox
    private var dimensions: (width: Int, height: Int)?
    private var pending: Pending?
    private var scheduled = false, closed = false
    private var revision: UInt64 = 1
    private var desktopID: UUID?
    private var generation: UInt64 = 0, frameNumber: UInt64 = 0
    private var requiresNewGeneration = false
    init(dimensions: (width: Int, height: Int)?, presentation: PlankIPadPencilImagePresentationMailbox) {
        self.dimensions = dimensions; self.presentation = presentation
    }
    func configureDimensions(_ next: (width: Int, height: Int)?) {
        lock.lock()
        if revision == UInt64.max { closed = true } else { revision += 1 }
        dimensions = next; pending = nil; requiresNewGeneration = generation > 0
        lock.unlock()
    }
    func offer(_ frame: PlankPencilImageFrame) {
        guard (try? frame.validated()) != nil else { return }
        let descriptor = frame.descriptor
        let now = DispatchTime.now().uptimeNanoseconds
        guard frame.receivedAtUptimeNanoseconds > 0, now >= frame.receivedAtUptimeNanoseconds,
              now - frame.receivedAtUptimeNanoseconds < 1_500_000_000 else { return }
        lock.lock()
        guard !closed, let dimensions,
              descriptor.sourceWidth == dimensions.width, descriptor.sourceHeight == dimensions.height,
              descriptor.frameNumber > frameNumber,
              descriptor.geometryGeneration >= generation,
              !requiresNewGeneration || descriptor.geometryGeneration > generation,
              desktopID == nil || desktopID == descriptor.desktopID else { lock.unlock(); return }
        desktopID = descriptor.desktopID; generation = descriptor.geometryGeneration
        frameNumber = descriptor.frameNumber; requiresNewGeneration = false
        pending = Pending(frame: frame, revision: revision)
        let wake = !scheduled
        if wake { scheduled = true }; lock.unlock()
        if wake { queue.async { [weak self] in self?.pump() } }
    }
    func invalidate() { lock.lock(); closed = true; pending = nil; lock.unlock() }
    func isCurrent(_ value: UInt64) -> Bool {
        lock.lock(); let current = !closed && revision == value; lock.unlock(); return current
    }
    private func pump() {
        lock.lock()
        guard !closed, let item = pending else { scheduled = false; lock.unlock(); return }
        pending = nil; lock.unlock()
        do {
            let descriptor = item.frame.descriptor
            let image = try PlankPencilReferenceImageCodec.decode(item.frame.jpegData,
                expectedWidth: descriptor.encodedWidth, expectedHeight: descriptor.encodedHeight)
            let now = DispatchTime.now().uptimeNanoseconds
            lock.lock(); let valid = !closed && revision == item.revision; lock.unlock()
            if valid, now >= item.frame.receivedAtUptimeNanoseconds,
               now - item.frame.receivedAtUptimeNanoseconds < 1_500_000_000 {
                presentation.offer(.image(.init(image: image, receivedAt: item.frame.receivedAtUptimeNanoseconds, revision: item.revision)))
            }
        } catch {
            lock.lock(); let valid = !closed && revision == item.revision; lock.unlock()
            if valid { presentation.offer(.failure(item.revision)) }
        }
        lock.lock(); let again = !closed && pending != nil
        if !again { scheduled = false }; lock.unlock()
        if again { queue.async { [weak self] in self?.pump() } }
    }
}
