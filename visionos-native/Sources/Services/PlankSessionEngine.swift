import Foundation
import CoreVideo

enum PlankHostFeature {
    static let rawHidTablet: UInt32 = 0x04
    static let rawHidFocusSuspend: UInt32 = 0x20
    static let tabletRelayRequired = rawHidTablet | rawHidFocusSuspend
}

enum PlankInputEvent: Sendable {
    case pointer(x: UInt16, y: UInt16, maximumX: UInt16, maximumY: UInt16)
    case button(number: UInt8, pressed: Bool)
    case scroll(vertical: Int16, horizontal: Int16)
    case key(code: UInt16, pressed: Bool, modifiers: UInt8)
    case text(Data)
    case rawHid(Data)
}

struct PlankVideoProgress: Sendable {
    let received: UInt64
    let decoded: UInt64
    let keyFrames: UInt64
    let receiveDrops: UInt64
    let fecUnrecovered: UInt64
    let frameGaps: UInt64
    let averageDecodeMilliseconds: Double
    let decoder: String
}

final class PlankInputQueue: @unchecked Sendable {
    private let lock = NSLock()
    private let wakeups: AsyncStream<Void>
    private let wakeupContinuation: AsyncStream<Void>.Continuation
    private var events: [PlankInputEvent] = []
    private var stopped = false

    init() {
        (wakeups, wakeupContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
    }

    var signals: AsyncStream<Void> { wakeups }

    func append(_ event: PlankInputEvent) {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        let shouldWake = events.isEmpty
        if case .pointer = event,
           case .pointer? = events.last {
            events[events.count - 1] = event
        } else {
            events.append(event)
        }
        lock.unlock()
        if shouldWake { wakeupContinuation.yield(()) }
    }

    func drain() -> [PlankInputEvent] {
        lock.lock()
        let drained = events
        events.removeAll(keepingCapacity: true)
        lock.unlock()
        return drained
    }

    func stop() {
        lock.lock()
        stopped = true
        events.removeAll(keepingCapacity: true)
        lock.unlock()
        wakeupContinuation.finish()
    }
}

// The Rust endpoint synchronizes its input and video queues independently.
// Keep it alive until the input sender has exited before destroying it.
private final class PlankTransportHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }
}

private final class PlankInputSenderState: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = false

    func markFailed() {
        lock.lock()
        failed = true
        lock.unlock()
    }

    var hasFailed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }
}

enum PlankSessionError: LocalizedError, Sendable {
    case transport(String)
    case invalidNegotiation
    case noVideo

    var errorDescription: String? {
        switch self {
        case let .transport(message): return message
        case .invalidNegotiation: return "The Host returned invalid native session values."
        case .noVideo: return "The Host started the session but sent no video frame."
        }
    }
}

// Shape chunks arrive on the same reliable data channel as cursor positions.
// Only a complete, ordered generation becomes visible to the presentation layer.
private struct CursorShapeAssembly {
    private var pixels = Data()
    private var generation: UInt64 = 0
    private var width = 0
    private var height = 0
    private var hotspotX = 0
    private var hotspotY = 0
    private var visible = false

    mutating func append(
        event: PlankVisionCursorEvent,
        chunk: ArraySlice<UInt8>
    ) -> PlankRemoteCursorShape? {
        let first = event.flags & UInt32(PLANK_VISION_CURSOR_FIRST_CHUNK) != 0
        let last = event.flags & UInt32(PLANK_VISION_CURSOR_LAST_CHUNK) != 0
        let currentVisibility = event.flags & UInt32(PLANK_VISION_CURSOR_VISIBLE) != 0
        if first {
            guard event.chunk_offset == 0 else { return nil }
            pixels = Data()
            pixels.reserveCapacity(Int(event.image_size))
            generation = event.generation
            width = Int(event.width)
            height = Int(event.height)
            hotspotX = Int(event.hotspot_x)
            hotspotY = Int(event.hotspot_y)
            visible = currentVisibility
        }
        guard !pixels.isEmpty || first,
              generation == event.generation,
              width == event.width,
              height == event.height,
              hotspotX == event.hotspot_x,
              hotspotY == event.hotspot_y,
              visible == currentVisibility,
              pixels.count == event.chunk_offset else {
            pixels = Data()
            return nil
        }
        pixels.append(contentsOf: chunk)
        guard last else { return nil }
        guard pixels.count == event.image_size else {
            pixels = Data()
            return nil
        }
        let shape = PlankRemoteCursorShape(
            pixels: pixels,
            width: width,
            height: height,
            hotspotX: hotspotX,
            hotspotY: hotspotY,
            visible: visible,
            generation: generation
        )
        pixels = Data()
        return shape
    }
}

struct PlankSessionEngine: Sendable {
    func stream(
        host: String,
        topology: PlankTopology,
        frameRate: Int,
        launch: PlankLaunchCredentials,
        inputQueue: PlankInputQueue,
        onFrame: @escaping @Sendable (PlankRenderedFrame) -> Void,
        onVideoProgress: @escaping @Sendable (PlankVideoProgress) -> Void,
        onCursor: @escaping @Sendable (PlankCursorUpdate) -> Void,
        onHostFeatures: @escaping @Sendable (UInt32) -> Void,
        onRawHid: @escaping @Sendable (Data) -> Void,
        onTabletFrameSent: @escaping @Sendable (Data) -> Void
    ) async throws {
        let worker = Task.detached(priority: .userInitiated) {
            var error = [CChar](repeating: 0, count: 512)
            let transport = host.withCString { hostPointer in
                launch.certificateSHA256.withCString { certificatePointer in
                    launch.transportToken.withCString { tokenPointer in
                        plank_vision_transport_connect(
                            hostPointer,
                            launch.transportPort,
                            certificatePointer,
                            tokenPointer,
                            launch.udpPayloadMTU,
                            &error,
                            error.count
                        )
                    }
                }
            }
            guard let transport else {
                throw PlankSessionError.transport(String(cString: error))
            }
            defer { plank_vision_transport_disconnect(transport) }

            let request: [String: Any] = [
                "video": [
                    "width": topology.desktopWidth,
                    "height": topology.desktopHeight,
                    "fps": frameRate,
                    "fps_x100": frameRate * 100,
                    "slices_per_frame": 1,
                    "reference_frames": 1,
                    "encoder_csc_mode": 7,
                    "codec": 1,
                    "ten_bit": true,
                    "chroma": 1,
                    "intra_refresh": 0,
                    "encoder_target_kbps": 50000,
                    "negotiated_format": 0x0800,
                ],
                "audio": [
                    "channels": 2,
                    "channel_mask": 3,
                    "packet_duration_ms": 5,
                    "high_quality": true,
                ],
            ]
            let requestData = try JSONSerialization.data(withJSONObject: request)
            var response = [UInt8](repeating: 0, count: 64 * 1024)
            var responseSize = 0
            let negotiationResult = requestData.withUnsafeBytes { bytes in
                plank_vision_transport_negotiate(
                    transport,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count,
                    &response,
                    response.count,
                    &responseSize,
                    &error,
                    error.count
                )
            }
            guard negotiationResult == PLANK_VISION_TRANSPORT_OK else {
                throw PlankSessionError.transport(String(cString: error))
            }
            let responseData = Data(response.prefix(responseSize))
            guard let responseObject = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  responseObject["video_format"] as? Int == 0x0800 else {
                throw PlankSessionError.invalidNegotiation
            }
            let hostFeatures = UInt32(truncatingIfNeeded: responseObject["host_feature_flags"] as? Int ?? 0)
            onHostFeatures(hostFeatures)
            let rawHidAvailable = hostFeatures & PlankHostFeature.tabletRelayRequired ==
                PlankHostFeature.tabletRelayRequired

            guard let decoder = plank_video_decoder_create(&error, error.count) else {
                throw PlankSessionError.transport(String(cString: error))
            }
            defer { plank_video_decoder_destroy(decoder) }
            var hardwareDecoder: PlankHardwareVideoDecoder? = PlankHardwareVideoDecoder()

            let decoderPadding = Int(plank_video_decoder_input_padding())
            var payload = [UInt8](repeating: 0, count: 4 * 1024 * 1024 + decoderPadding)
            var pixels = [UInt8](
                repeating: 0,
                count: topology.desktopWidth * topology.desktopHeight * 4
            )
            var frame = PlankVisionVideoFrame()
            var receivedFrames: UInt64 = 0
            var decodedFrames: UInt64 = 0
            var keyFrames: UInt64 = 0
            var frameGaps: UInt64 = 0
            var lastReceivedFrameNumber: UInt64?
            var decodeNanos: UInt64 = 0
            var decodeCalls: UInt64 = 0
            var lastVideoReport = DispatchTime.now().uptimeNanoseconds
            var lastDecodedFrameTime = lastVideoReport
            var lastIDRRequest = UInt64(0)
            var awaitingKeyFrame = false
            var hardwareFailures = 0
            var cursorChunk = [UInt8](repeating: 0, count: Int(PLANK_VISION_CURSOR_MAX_CHUNK_SIZE))
            var cursorAssembly = CursorShapeAssembly()
            let senderState = PlankInputSenderState()
            let endpoint = PlankTransportHandle(transport)
            let sender = Task.detached(priority: .userInitiated) {
                for await _ in inputQueue.signals {
                    for event in inputQueue.drain() {
                        guard Self.send(
                            event, to: endpoint.pointer,
                            rawHidAvailable: rawHidAvailable
                        ) == PLANK_VISION_TRANSPORT_OK else {
                            senderState.markFailed()
                            inputQueue.stop()
                            return
                        }
                        if case let .rawHid(frame) = event {
                            onTabletFrameSent(frame)
                        }
                    }
                }
            }
            do {
                while !Task.isCancelled {
                    if senderState.hasFailed {
                        throw PlankSessionError.transport("The remote input channel stopped unexpectedly.")
                    }
                    var payloadSize = 0
                    let result = plank_vision_transport_receive_video(
                        transport, &frame, &payload,
                        payload.count - decoderPadding, &payloadSize, 30
                    )
                    let reportTime = DispatchTime.now().uptimeNanoseconds
                    if reportTime - lastVideoReport >= 1_000_000_000 {
                        var stats = PlankVisionVideoStats()
                        _ = plank_vision_transport_video_stats(transport, &stats)
                        onVideoProgress(PlankVideoProgress(
                            received: receivedFrames,
                            decoded: decodedFrames,
                            keyFrames: keyFrames,
                            receiveDrops: stats.receive_drops,
                            fecUnrecovered: stats.fec_symbols_unrecovered,
                            frameGaps: frameGaps,
                            averageDecodeMilliseconds: decodeCalls == 0 ? 0 :
                                Double(decodeNanos) / Double(decodeCalls) / 1_000_000,
                            decoder: hardwareDecoder == nil ? "FFmpeg software" : "VideoToolbox xf44"
                        ))
                        decodeNanos = 0
                        decodeCalls = 0
                        lastVideoReport = reportTime
                    }
                    // Keep Host tablet requests moving even while video is idle.
                    // Cap each drain so sustained control traffic cannot starve video.
                    for _ in 0..<64 {
                        var cursor = PlankVisionCursorEvent()
                        var cursorChunkSize = 0
                        let cursorResult = plank_vision_transport_receive_data_event(
                            transport, &cursor, &cursorChunk, cursorChunk.count,
                            &cursorChunkSize, 0
                        )
                        if cursorResult == PLANK_VISION_TRANSPORT_TIMEOUT { break }
                        guard cursorResult == PLANK_VISION_TRANSPORT_OK else {
                            throw PlankSessionError.transport("The remote cursor channel stopped unexpectedly.")
                        }
                        if cursor.type == PLANK_VISION_CURSOR_POSITION {
                            onCursor(.position(PlankRemoteCursor(
                                x: Int(cursor.x),
                                y: Int(cursor.y),
                                frameWidth: Int(cursor.frame_width),
                                frameHeight: Int(cursor.frame_height),
                                sequence: cursor.sequence
                            )))
                        } else if cursor.type == PLANK_VISION_CURSOR_SHAPE,
                                  let shape = cursorAssembly.append(
                                    event: cursor,
                                    chunk: cursorChunk.prefix(cursorChunkSize)
                                  ) {
                            onCursor(.shape(shape))
                        } else if cursor.type == PLANK_VISION_RAW_HID_EVENT {
                            onRawHid(Data(cursorChunk.prefix(cursorChunkSize)))
                        }
                    }

                    if result == PLANK_VISION_TRANSPORT_BUFFER_TOO_SMALL,
                       payloadSize > payload.count - decoderPadding,
                       payloadSize <= 64 * 1024 * 1024 {
                        payload = [UInt8](repeating: 0, count: payloadSize + decoderPadding)
                        continue
                    }
                    if result == PLANK_VISION_TRANSPORT_TIMEOUT { continue }
                    guard result == PLANK_VISION_TRANSPORT_OK, payloadSize > 0 else {
                        throw PlankSessionError.transport("The native video receiver stopped unexpectedly.")
                    }
                    receivedFrames &+= 1
                    if frame.flags & 1 != 0 { keyFrames &+= 1 }
                    if let lastReceivedFrameNumber,
                       frame.frame_number > lastReceivedFrameNumber + 1 {
                        frameGaps &+= frame.frame_number - lastReceivedFrameNumber - 1
                    }
                    lastReceivedFrameNumber = frame.frame_number

                    if awaitingKeyFrame {
                        if frame.flags & 1 != 0 {
                            awaitingKeyFrame = false
                        } else {
                            if reportTime - lastIDRRequest >= 1_000_000_000 {
                                guard plank_vision_transport_request_idr(transport) ==
                                        PLANK_VISION_TRANSPORT_OK else {
                                    throw PlankSessionError.transport("Unable to request a fresh video frame.")
                                }
                                lastIDRRequest = reportTime
                            }
                            continue
                        }
                    }

                    // libavcodec may read beyond the compressed packet size for
                    // vectorized bitstream parsing. The transport buffer is reused,
                    // so clear the trailing bytes after every received frame.
                    payload.replaceSubrange(
                        payloadSize..<(payloadSize + decoderPadding),
                        with: repeatElement(0, count: decoderPadding)
                    )

                    if let hardware = hardwareDecoder {
                        let decodeStart = DispatchTime.now().uptimeNanoseconds
                        let outcome = payload.withUnsafeBufferPointer { bytes in
                            hardware.decode(UnsafeBufferPointer(rebasing: bytes.prefix(payloadSize)))
                        }
                        decodeNanos &+= DispatchTime.now().uptimeNanoseconds - decodeStart
                        decodeCalls &+= 1
                        switch outcome {
                        case let .frame(image):
                            decodedFrames &+= 1
                            lastDecodedFrameTime = reportTime
                            onFrame(PlankRenderedFrame(
                                pixels: Data(), pixelBuffer: image,
                                width: CVPixelBufferGetWidth(image),
                                height: CVPixelBufferGetHeight(image),
                                bytesPerRow: 0, frameNumber: frame.frame_number
                            ))
                            continue
                        case .waiting:
                            if reportTime - lastDecodedFrameTime >= 1_000_000_000 &&
                               reportTime - lastIDRRequest >= 1_000_000_000 {
                                guard plank_vision_transport_request_idr(transport) ==
                                        PLANK_VISION_TRANSPORT_OK else {
                                    throw PlankSessionError.transport("Unable to request a fresh video frame.")
                                }
                                lastIDRRequest = reportTime
                            }
                            continue
                        case .unavailable:
                            hardwareFailures += 1
                            NSLog("PLANK VideoToolbox decoder failed: %@",
                                  hardware.lastError ?? "unknown error")
                            hardwareDecoder = hardwareFailures <= 2 ?
                                PlankHardwareVideoDecoder() : nil
                            awaitingKeyFrame = true
                            guard plank_vision_transport_request_idr(transport) ==
                                    PLANK_VISION_TRANSPORT_OK else {
                                throw PlankSessionError.transport("Unable to request a fresh video frame.")
                            }
                            lastIDRRequest = reportTime
                            continue
                        }
                    }

                    var decodedWidth: UInt32 = 0
                    var decodedHeight: UInt32 = 0
                    var decodedStride: UInt32 = 0
                    let decodeStart = DispatchTime.now().uptimeNanoseconds
                    let decodeResult = payload.withUnsafeBytes { encodedBytes in
                        pixels.withUnsafeMutableBytes { pixelBytes in
                            plank_video_decoder_decode(
                                decoder,
                                encodedBytes.bindMemory(to: UInt8.self).baseAddress,
                                payloadSize,
                                pixelBytes.bindMemory(to: UInt8.self).baseAddress,
                                pixelBytes.count,
                                &decodedWidth,
                                &decodedHeight,
                                &decodedStride,
                                &error,
                                error.count
                            )
                        }
                    }
                    decodeNanos &+= DispatchTime.now().uptimeNanoseconds - decodeStart
                    decodeCalls &+= 1
                    if decodeResult == PLANK_VIDEO_DECODER_NO_FRAME {
                        if reportTime - lastDecodedFrameTime >= 1_000_000_000 &&
                           reportTime - lastIDRRequest >= 1_000_000_000 {
                            guard plank_vision_transport_request_idr(transport) ==
                                    PLANK_VISION_TRANSPORT_OK else {
                                throw PlankSessionError.transport("Unable to request a fresh video frame.")
                            }
                            lastIDRRequest = reportTime
                        }
                        continue
                    }
                    guard decodeResult == PLANK_VIDEO_DECODER_FRAME else {
                        throw PlankSessionError.transport(String(cString: error))
                    }
                    decodedFrames &+= 1
                    lastDecodedFrameTime = reportTime
                    let byteCount = Int(decodedStride) * Int(decodedHeight)
                    onFrame(PlankRenderedFrame(
                        pixels: Data(pixels.prefix(byteCount)),
                        pixelBuffer: nil,
                        width: Int(decodedWidth),
                        height: Int(decodedHeight),
                        bytesPerRow: Int(decodedStride),
                        frameNumber: frame.frame_number
                    ))
                }
            } catch {
                inputQueue.stop()
                await sender.value
                throw error
            }
            inputQueue.stop()
            await sender.value
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            inputQueue.stop()
            worker.cancel()
        }
    }

    private static func send(
        _ input: PlankInputEvent,
        to transport: OpaquePointer,
        rawHidAvailable: Bool
    ) -> Int32 {
        switch input {
        case let .pointer(x, y, maximumX, maximumY):
            return plank_vision_transport_send_mouse_position(
                transport, x, y, maximumX, maximumY
            )
        case let .button(number, pressed):
            return plank_vision_transport_send_mouse_button(
                transport, number, pressed ? 1 : 0
            )
        case let .scroll(vertical, horizontal):
            let verticalResult = vertical == 0 ? Int32(PLANK_VISION_TRANSPORT_OK) :
                plank_vision_transport_send_scroll(transport, vertical, 0)
            let horizontalResult = horizontal == 0 ? Int32(PLANK_VISION_TRANSPORT_OK) :
                plank_vision_transport_send_scroll(transport, horizontal, 1)
            return verticalResult == PLANK_VISION_TRANSPORT_OK ? horizontalResult : verticalResult
        case let .key(code, pressed, modifiers):
            return plank_vision_transport_send_key(
                transport, code, pressed ? 1 : 0, modifiers
            )
        case let .text(data):
            return data.withUnsafeBytes { bytes in
                plank_vision_transport_send_utf8(
                    transport,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count
                )
            }
        case let .rawHid(frame):
            guard rawHidAvailable else { return Int32(PLANK_VISION_TRANSPORT_ERROR) }
            return frame.withUnsafeBytes { bytes in
                plank_vision_transport_send_raw_hid(
                    transport,
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count
                )
            }
        }
    }
}
