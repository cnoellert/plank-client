#ifndef PLANK_TRANSPORT_BRIDGE_H
#define PLANK_TRANSPORT_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PlankVisionTransport PlankVisionTransport;

typedef struct PlankVisionVideoFrame {
    uint32_t codec;
    uint32_t flags;
    uint64_t frame_number;
    uint64_t pts_90khz;
    uint16_t host_processing_latency;
} PlankVisionVideoFrame;

enum {
    PLANK_VISION_TRANSPORT_OK = 0,
    PLANK_VISION_TRANSPORT_TIMEOUT = 1,
    PLANK_VISION_TRANSPORT_BUFFER_TOO_SMALL = 2,
    PLANK_VISION_TRANSPORT_ERROR = -1,
    PLANK_VISION_TRANSPORT_UNAVAILABLE = -2,
};

PlankVisionTransport *plank_vision_transport_connect(
    const char *remote_host,
    uint16_t remote_port,
    const char *certificate_sha256,
    const char *session_token,
    uint32_t maximum_udp_payload,
    char *error,
    size_t error_capacity);

int32_t plank_vision_transport_negotiate(
    PlankVisionTransport *transport,
    const uint8_t *request_json,
    size_t request_size,
    uint8_t *response_json,
    size_t response_capacity,
    size_t *response_size,
    char *error,
    size_t error_capacity);

int32_t plank_vision_transport_receive_video(
    PlankVisionTransport *transport,
    PlankVisionVideoFrame *frame,
    uint8_t *payload,
    size_t payload_capacity,
    size_t *payload_size,
    uint32_t timeout_ms);

void plank_vision_transport_disconnect(PlankVisionTransport *transport);

#ifdef __cplusplus
}
#endif

#endif
