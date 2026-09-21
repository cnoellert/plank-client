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
    func probeFirstFrame(
        host: String,
        topology: PlankTopology,
        launch: PlankLaunchCredentials
    ) async throws -> PlankFrameProbe {
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

            var payload = [UInt8](repeating: 0, count: 4 * 1024 * 1024)
            var frame = PlankVisionVideoFrame()
            for _ in 0..<4 {
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
                return PlankFrameProbe(
                    byteCount: payloadSize,
                    frameNumber: frame.frame_number,
                    isKeyFrame: (frame.flags & 1) != 0,
                    negotiationSummary: "HEVC 10-bit 4:4:4, \(topology.desktopWidth)×\(topology.desktopHeight) at 60 fps"
                )
            }
            throw PlankSessionError.noVideo
        }.value
    }
}
