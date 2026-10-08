// SPDX-License-Identifier: AGPL-3.0-or-later
// Local physical-source qualification only. No network, microphone, preview,
// compressed-frame persistence, or production Host/session authentication.
import SwiftUI
import AppKit
import Foundation

private final class Counter: @unchecked Sendable {
    struct Result: Codable, Sendable {
        var frames = 0
        var independentFrames = 0
        var invalidRecords = 0
        var firstCaptureUS: UInt64 = 0
        var lastCaptureUS: UInt64 = 0
        var maximumAgeUS: UInt64 = 0
    }
    private let lock = NSLock()
    private var result = Result()
    func accept(_ packet: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var header = PlankEncodedCameraHeader()
        let decoded = packet.withUnsafeBytes {
            plank_encoded_camera_header_decode($0.bindMemory(to: UInt8.self).baseAddress, $0.count, &header)
        }
        guard decoded == 0, header.capture_time_us > result.lastCaptureUS,
              header.sequence == UInt64(result.frames) else { result.invalidRecords += 1; return false }
        if result.frames == 0 { result.firstCaptureUS = header.capture_time_us }
        result.lastCaptureUS = header.capture_time_us
        result.frames += 1
        if header.flags & UInt8(PLANK_CAMERA_KEY_FRAME) != 0 { result.independentFrames += 1 }
        let now = PlankMacCameraEncoder.nowUS
        if now >= header.capture_time_us { result.maximumAgeUS = max(result.maximumAgeUS, now - header.capture_time_us) }
        return true
    }
    var snapshot: Result { lock.lock(); defer { lock.unlock() }; return result }
}
@MainActor private final class CameraTestModel: ObservableObject {
    @Published var choices = PlankMacCameraCapture.choices()
    @Published var selectedID = ""
    @Published var running = false
    @Published var status = "Choose the camera to test."
    @Published var detail = ""
    private var source: PlankMacCameraCapture?
    private var token: UInt64 = 0
    private var timer: Task<Void, Never>?
    private var counter: Counter?
    private var activated = false
    private struct Report: Codable {
        let passed: Bool
        let adapterOnly: Bool
        let productSessionUsed: Bool
        let compressedImagesSaved: Bool
        let ended: String
        let result: Counter.Result
    }
    func refresh() { choices = PlankMacCameraCapture.choices() }
    func start() {
        guard !running, !selectedID.isEmpty else { return }
        token += 1
        let expected = token, choice = selectedID
        running = true; activated = false; detail = ""; status = "Waiting for camera permission…"
        Task { [self] in
            let allowed = await PlankMacCameraCapture.requestConsent()
            guard token == expected, running else { return }
            guard allowed else { finish("Camera permission was not granted.", completed: false); return }
            let sink = Counter(); counter = sink
            let camera = PlankMacCameraCapture { [weak self] update in
                Task { @MainActor [weak self] in
                    guard let self, self.token == expected, self.running else { return }
                    switch update {
                    case .starting: self.status = "Starting the camera…"
                    case .active:
                        self.activated = true
                        self.status = "Camera test running. It stops after five seconds."
                    case .off: self.finish("Test interrupted.", completed: false)
                    case let .unavailable(reason): self.finish("Camera unavailable: \(reason).", completed: false)
                    }
                }
            }
            source = camera
            // Test acknowledgement fixture only. There is no product negotiation
            // or remote Host in this local source check.
            camera.start(selectedID: choice, generation: expected, acknowledgedGeneration: expected,
                         featureVersion: 2, submit: { sink.accept($0) })
            timer = Task { [weak self] in
                for _ in 0..<50 {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self, self.token == expected, self.running else { return }
                    if self.activated { break }
                }
                guard let self, self.token == expected, self.running else { return }
                guard self.activated else { self.finish("Camera did not start in time.", completed: false); return }
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, self.token == expected, self.running else { return }
                self.finish("Test complete.", completed: true)
            }
        }
    }
    func stop() {
        if running { finish("Stopped.", completed: false) }
        else { source?.stop(); source = nil }
    }
    private func finish(_ ended: String, completed: Bool) {
        // Admission is revoked before taking the final count. No compressed
        // packet can reach Counter after stop returns.
        source?.stop()
        let result = counter?.snapshot ?? Counter.Result()
        let passed = completed && result.frames >= 60 && result.independentFrames >= 2 && result.invalidRecords == 0
        token += 1; running = false; timer?.cancel(); timer = nil; source = nil
        status = completed ? (passed ? "Camera source check passed." : "Camera source check needs investigation.") : ended
        detail = "\(result.frames) frames · \(result.independentFrames) recovery frames · \(String(format: "%.1f", Double(result.maximumAgeUS) / 1000)) ms maximum frame age"
        let report = Report(passed: passed, adapterOnly: true, productSessionUsed: false, compressedImagesSaved: false,
                            ended: ended, result: result)
        do {
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share/plank/private-notes/camera-source-device-test")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let file = directory.appendingPathComponent("latest.json")
            try encoder.encode(report).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch { detail += " · Could not save the count report." }
    }
}
@main struct CameraSourceTestApp: App {
    @StateObject private var model = CameraTestModel()
    var body: some Scene {
        WindowGroup("PLANK Camera Test") {
            VStack(alignment: .leading, spacing: 18) {
                Text("Camera source check").font(.title2.bold())
                Text("Test one camera on this Mac for five seconds.").foregroundStyle(.secondary)
                Picker("Camera", selection: $model.selectedID) {
                    Text("Choose a camera").tag("")
                    ForEach(model.choices, id: \.id) { camera in Text(camera.name).tag(camera.id) }
                }.disabled(model.running)
                HStack {
                    Button("Scan again") { model.refresh() }.disabled(model.running)
                    Spacer()
                    if model.running { Button("Stop") { model.stop() } }
                    else { Button("Start camera test") { model.start() }.disabled(model.selectedID.isEmpty).buttonStyle(.borderedProminent) }
                }
                Divider()
                Text(model.status)
                if !model.detail.isEmpty { Text(model.detail).font(.callout).foregroundStyle(.secondary) }
                Text("Images stay in memory. Only frame counts and timing are saved.").font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(width: 480, alignment: .leading)
             .onDisappear { model.stop() }
        }.windowResizability(.contentSize)
    }
}
