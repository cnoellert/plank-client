import CoreGraphics
import SwiftUI
import UIKit

struct HostDetailView: View {
    let host: HostBookmark
    @ObservedObject var store: HostStore
    @StateObject private var client = PlankCoreClient()
    @State private var username = ""
    @State private var password = ""
    @State private var remotePointerPressed = false

    var body: some View {
        ZStack {
            if let frame = client.latestFrame,
               let image = makeImage(from: frame) {
                GeometryReader { proxy in
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .contentShape(Rectangle())
                        .background {
                            HardwareKeyboardCapture { characters in
                                handleKeyboardCharacters(characters)
                            }
                        }
                        .onContinuousHover(coordinateSpace: .local) { phase in
                            if case let .active(location) = phase {
                                sendPointer(location, in: proxy.size, frame: frame)
                            }
                        }
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                                .onChanged { value in
                                    sendPointer(value.location, in: proxy.size, frame: frame)
                                    if !remotePointerPressed {
                                        remotePointerPressed = true
                                        client.setLeftButton(pressed: true)
                                    }
                                }
                                .onEnded { value in
                                    sendPointer(value.location, in: proxy.size, frame: frame)
                                    remotePointerPressed = false
                                    client.setLeftButton(pressed: false)
                                }
                        )
                        .overlay(alignment: .topLeading) {
                            Label("Live · frame \(frame.frameNumber)", systemImage: "dot.radiowaves.left.and.right")
                                .font(.headline.monospacedDigit())
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(20)
                        }
                        .overlay(alignment: .topTrailing) {
                            Button(role: .destructive) {
                                client.disconnectSession()
                            } label: {
                                Label("Disconnect", systemImage: "xmark.circle.fill")
                                    .font(.headline)
                            }
                            .buttonStyle(.borderedProminent)
                            .padding(20)
                        }
                        .overlay {
                            if let cursor = client.remoteCursor,
                               cursor.frameWidth == frame.width,
                               cursor.frameHeight == frame.height {
                                remoteCursorView(cursor, in: proxy.size, frame: frame)
                            }
                        }
                }
            } else {
                connectionPanel
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(host.name)
    }

    private var connectionPanel: some View {
        VStack(spacing: 28) {
            Image(systemName: "display.2")
                .font(.system(size: 64, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.cyan)

            VStack(spacing: 8) {
                Text(host.name)
                    .font(.largeTitle.weight(.semibold))
                Text("\(host.address):\(host.port)")
                    .font(.title3.monospaced())
                    .foregroundStyle(.secondary)
            }

            status

            if case .authenticated = client.phase {
                Button {
                    client.startSession()
                } label: {
                    Label("Start Session", systemImage: "play.rectangle.fill")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
            }

            if case .needsCredentials = client.phase {
                VStack(spacing: 14) {
                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)

                    Button {
                        let suppliedPassword = password
                        password = ""
                        Task {
                            await client.authenticate(
                                username: username,
                                password: suppliedPassword
                            )
                            if case .authenticated = client.phase {
                                store.markConnected(host)
                            }
                        }
                    } label: {
                        Label("Sign In", systemImage: "person.badge.key.fill")
                            .frame(minWidth: 140)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(username.isEmpty || password.isEmpty)
                }
                .frame(maxWidth: 420)
            } else {
                HStack(spacing: 16) {
                    Button(role: .destructive) {
                        store.remove(host)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }

                    switch client.phase {
                    case .idle:
                        connectButton("Connect", systemImage: "play.fill")
                    case .failed:
                        connectButton("Try Again", systemImage: "arrow.clockwise")
                    default:
                        EmptyView()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch client.phase {
        case .idle:
            Text("Ready")
                .foregroundStyle(.secondary)
        case .probing:
            ProgressView("Contacting workstation…")
        case let .needsCredentials(identity):
            Label("Connected securely to \(identity.name)", systemImage: "lock.shield.fill")
                .foregroundStyle(.green)
        case let .authenticating(identity):
            ProgressView("Signing in to \(identity.name)…")
        case let .authenticated(identity, authentication):
            VStack(spacing: 8) {
                Label("Signed in to \(identity.name)", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(authentication.desktopStage == "greeter" ?
                     "The Linux desktop is unlocking. Streaming session startup is next." :
                     "The Host accepted this client. Streaming session startup is next.")
                    .foregroundStyle(.secondary)
            }
        case let .startingSession(identity, _):
            ProgressView("Starting secure stream from \(identity.name)…")
        case let .frameReceived(identity, _, probe):
            VStack(spacing: 8) {
                Label("Live video reached Vision Pro", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(identity.name) sent frame \(probe.frameNumber), \(probe.byteCount.formatted()) bytes")
                Text(probe.negotiationSummary)
                    .foregroundStyle(.secondary)
            }
        case let .streaming(identity, _, frameNumber):
            Label("Live video from \(identity.name) · frame \(frameNumber)", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }
    }

    private func connectButton(_ title: String, systemImage: String) -> some View {
        Button {
            Task { await client.connect(to: host) }
        } label: {
            Label(title, systemImage: systemImage)
                .frame(minWidth: 120)
        }
        .buttonStyle(.borderedProminent)
    }

    private func makeImage(from frame: PlankRenderedFrame) -> CGImage? {
        guard let provider = CGDataProvider(data: frame.pixels as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        return CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func sendPointer(
        _ location: CGPoint,
        in availableSize: CGSize,
        frame: PlankRenderedFrame
    ) {
        let scale = min(
            availableSize.width / CGFloat(frame.width),
            availableSize.height / CGFloat(frame.height)
        )
        guard scale > 0 else { return }
        let imageSize = CGSize(
            width: CGFloat(frame.width) * scale,
            height: CGFloat(frame.height) * scale
        )
        let origin = CGPoint(
            x: (availableSize.width - imageSize.width) / 2,
            y: (availableSize.height - imageSize.height) / 2
        )
        let x = Int(((location.x - origin.x) / scale).rounded())
        let y = Int(((location.y - origin.y) / scale).rounded())
        guard x >= 0, y >= 0, x < frame.width, y < frame.height else { return }
        client.movePointer(x: x, y: y, width: frame.width, height: frame.height)
    }

    private func handleKeyboardCharacters(_ characters: String) {
        for character in characters {
            switch character {
            case "\r", "\n":
            client.pressKey(code: 0x0D)
            case "\t":
            client.pressKey(code: 0x09)
            case "\u{8}", "\u{7f}":
            client.pressKey(code: 0x08)
            case "\u{1b}":
            client.pressKey(code: 0x1B)
            default:
                if let key = physicalKey(for: character) {
                    client.pressKey(code: key.code, modifiers: key.shifted ? 0x01 : 0)
                } else {
                    client.sendText(String(character))
                }
            }
        }
    }

    private func physicalKey(for character: Character) -> (code: UInt16, shifted: Bool)? {
        if let ascii = character.asciiValue {
            if ascii >= Character("a").asciiValue!, ascii <= Character("z").asciiValue! {
                return (UInt16(ascii - Character("a").asciiValue! + 0x41), false)
            }
            if ascii >= Character("A").asciiValue!, ascii <= Character("Z").asciiValue! {
                return (UInt16(ascii - Character("A").asciiValue! + 0x41), true)
            }
            if ascii >= Character("0").asciiValue!, ascii <= Character("9").asciiValue! {
                return (UInt16(ascii), false)
            }
        }
        switch character {
        case " ": return (0x20, false)
        case "!": return (0x31, true)
        case "@": return (0x32, true)
        case "#": return (0x33, true)
        case "$": return (0x34, true)
        case "%": return (0x35, true)
        case "^": return (0x36, true)
        case "&": return (0x37, true)
        case "*": return (0x38, true)
        case "(": return (0x39, true)
        case ")": return (0x30, true)
        case ";": return (0xBA, false)
        case ":": return (0xBA, true)
        case "=": return (0xBB, false)
        case "+": return (0xBB, true)
        case ",": return (0xBC, false)
        case "<": return (0xBC, true)
        case "-": return (0xBD, false)
        case "_": return (0xBD, true)
        case ".": return (0xBE, false)
        case ">": return (0xBE, true)
        case "/": return (0xBF, false)
        case "?": return (0xBF, true)
        case "`": return (0xC0, false)
        case "~": return (0xC0, true)
        case "[": return (0xDB, false)
        case "{": return (0xDB, true)
        case "\\": return (0xDC, false)
        case "|": return (0xDC, true)
        case "]": return (0xDD, false)
        case "}": return (0xDD, true)
        case "'": return (0xDE, false)
        case "\"": return (0xDE, true)
        default: return nil
        }
    }

    @ViewBuilder
    private func remoteCursorView(
        _ cursor: PlankRemoteCursor,
        in availableSize: CGSize,
        frame: PlankRenderedFrame
    ) -> some View {
        let scale = min(
            availableSize.width / CGFloat(frame.width),
            availableSize.height / CGFloat(frame.height)
        )
        let imageWidth = CGFloat(frame.width) * scale
        let imageHeight = CGFloat(frame.height) * scale
        let x = (availableSize.width - imageWidth) / 2 + CGFloat(cursor.x) * scale
        let y = (availableSize.height - imageHeight) / 2 + CGFloat(cursor.y) * scale
        ZStack {
            Circle()
                .stroke(.cyan, lineWidth: 2)
                .frame(width: 18, height: 18)
            Circle()
                .fill(.white)
                .frame(width: 4, height: 4)
        }
        .shadow(color: .black, radius: 2)
        .position(x: x, y: y)
        .allowsHitTesting(false)
    }
}

private struct HardwareKeyboardCapture: UIViewRepresentable {
    let onCharacters: @MainActor (String) -> Void

    func makeUIView(context: Context) -> KeyboardCaptureView {
        let view = KeyboardCaptureView()
        view.onCharacters = onCharacters
        return view
    }

    func updateUIView(_ view: KeyboardCaptureView, context: Context) {
        view.onCharacters = onCharacters
        view.requestKeyboardFocus()
    }
}

@MainActor
private final class KeyboardCaptureView: UIView {
    var onCharacters: (@MainActor (String) -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        requestKeyboardFocus()
    }

    func requestKeyboardFocus() {
        guard window != nil, !isFirstResponder else { return }
        DispatchQueue.main.async { [weak self] in
            _ = self?.becomeFirstResponder()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for press in presses {
            guard let characters = press.key?.characters, !characters.isEmpty else { continue }
            onCharacters?(characters)
            handled = true
        }
        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }
}
