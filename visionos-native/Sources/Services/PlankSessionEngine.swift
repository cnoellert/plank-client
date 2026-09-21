import Foundation

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
        onFrame: @escaping @Sendable (PlankRenderedFrame) -> Void
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
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
        }.value
    }
}
