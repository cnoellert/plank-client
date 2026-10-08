import Foundation

/// Builds the native-transport negotiation request. Kept free of the C bridge
/// so focused tests can prove which values reach the Host.
enum PlankStreamRequest {
    static func negotiation(
        topology: PlankTopology,
        frameRate: Int,
        encoderTargetKbps: Int
    ) -> [String: Any] {
        [
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
                "encoder_target_kbps": StreamBitrate.normalized(encoderTargetKbps),
                "negotiated_format": 0x0800,
            ],
            "audio": [
                "channels": 2,
                "channel_mask": 3,
                "packet_duration_ms": 5,
                "high_quality": true,
            ],
        ]
    }
}
