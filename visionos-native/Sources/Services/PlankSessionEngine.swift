import Foundation

enum PlankInputEvent: Sendable {
    case pointer(x: UInt16, y: UInt16, maximumX: UInt16, maximumY: UInt16)
    case button(number: UInt8, pressed: Bool)
    case key(code: UInt16, pressed: Bool, modifiers: UInt8)
    case text(Data)
}

final class PlankInputQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PlankInputEvent] = []

    func append(_ event: PlankInputEvent) {
        lock.lock()
        if case .pointer = event,
           case .pointer? = events.last {
            events[events.count - 1] = event
        } else {
            events.append(event)
        }
        lock.unlock()
    }

    func drain() -> [PlankInputEvent] {
        lock.lock()
        let drained = events
        events.removeAll(keepingCapacity: true)
        lock.unlock()
        return drained
    }

    func removeAll() {
        lock.lock()
        events.removeAll(keepingCapacity: true)
        lock.unlock()
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

struct PlankSessionEngine: Sendable {
    func stream(
        host: String,
        topology: PlankTopology,
        launch: PlankLaunchCredentials,
        inputQueue: PlankInputQueue,
        onFrame: @escaping @Sendable (PlankRenderedFrame) -> Void,
        onCursor: @escaping @Sendable (PlankRemoteCursor) -> Void
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
                    "fps": 60,
                    "fps_x100": 6000,
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

            guard let decoder = plank_video_decoder_create(&error, error.count) else {
                throw PlankSessionError.transport(String(cString: error))
            }
            defer { plank_video_decoder_destroy(decoder) }

            var payload = [UInt8](repeating: 0, count: 4 * 1024 * 1024)
            var pixels = [UInt8](
                repeating: 0,
                count: topology.desktopWidth * topology.desktopHeight * 4
            )
            var frame = PlankVisionVideoFrame()
            var decodedFrames: UInt64 = 0
            while !Task.isCancelled {
                for input in inputQueue.drain() {
                    let inputResult: Int32
                    switch input {
                    case let .pointer(x, y, maximumX, maximumY):
                        inputResult = plank_vision_transport_send_mouse_position(
                            transport, x, y, maximumX, maximumY
                        )
                    case let .button(number, pressed):
                        inputResult = plank_vision_transport_send_mouse_button(
                            transport, number, pressed ? 1 : 0
                        )
                    case let .key(code, pressed, modifiers):
                        inputResult = plank_vision_transport_send_key(
                            transport, code, pressed ? 1 : 0, modifiers
                        )
                    case let .text(data):
                        inputResult = data.withUnsafeBytes { bytes in
                            plank_vision_transport_send_utf8(
                                transport,
                                bytes.bindMemory(to: UInt8.self).baseAddress,
                                bytes.count
                            )
                        }
                    }
                    guard inputResult == PLANK_VISION_TRANSPORT_OK else {
                        throw PlankSessionError.transport("The remote input channel stopped unexpectedly.")
                    }
                }
                var payloadSize = 0
                let result = plank_vision_transport_receive_video(
                    transport, &frame, &payload, payload.count, &payloadSize, 3000
                )
                if result == PLANK_VISION_TRANSPORT_BUFFER_TOO_SMALL,
                   payloadSize > payload.count, payloadSize <= 64 * 1024 * 1024 {
                    payload = [UInt8](repeating: 0, count: payloadSize)
                    continue
                }
                if result == PLANK_VISION_TRANSPORT_TIMEOUT { continue }
                guard result == PLANK_VISION_TRANSPORT_OK, payloadSize > 0 else {
                    throw PlankSessionError.transport("The native video receiver stopped unexpectedly.")
                }

                while true {
                    var cursor = PlankVisionCursorPosition()
                    let cursorResult = plank_vision_transport_receive_cursor_position(
                        transport, &cursor, 0
                    )
                    if cursorResult == PLANK_VISION_TRANSPORT_TIMEOUT { break }
                    guard cursorResult == PLANK_VISION_TRANSPORT_OK else {
                        throw PlankSessionError.transport("The remote cursor channel stopped unexpectedly.")
                    }
                    onCursor(PlankRemoteCursor(
                        x: Int(cursor.x),
                        y: Int(cursor.y),
                        frameWidth: Int(cursor.frame_width),
                        frameHeight: Int(cursor.frame_height),
                        sequence: cursor.sequence
                    ))
                }

                var decodedWidth: UInt32 = 0
                var decodedHeight: UInt32 = 0
                var decodedStride: UInt32 = 0
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
                if decodeResult == PLANK_VIDEO_DECODER_NO_FRAME { continue }
                guard decodeResult == PLANK_VIDEO_DECODER_FRAME else {
                    throw PlankSessionError.transport(String(cString: error))
                }
                decodedFrames += 1
                if decodedFrames == 1 || decodedFrames.isMultiple(of: 6) {
                    let byteCount = Int(decodedStride) * Int(decodedHeight)
                    onFrame(PlankRenderedFrame(
                        pixels: Data(pixels.prefix(byteCount)),
                        width: Int(decodedWidth),
                        height: Int(decodedHeight),
                        bytesPerRow: Int(decodedStride),
                        frameNumber: frame.frame_number
                    ))
                }
            }
        }
        try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
