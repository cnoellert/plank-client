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

typedef struct PlankVisionCursorEvent {
    uint16_t type;
    uint32_t x;
    uint32_t y;
    uint32_t frame_width;
    uint32_t frame_height;
    uint64_t sequence;
    uint64_t generation;
    uint32_t flags;
    uint32_t width;
    uint32_t height;
    uint32_t hotspot_x;
    uint32_t hotspot_y;
    uint32_t image_size;
    uint32_t chunk_offset;
} PlankVisionCursorEvent;

enum {
    PLANK_VISION_RAW_HID_EVENT = 2,
    PLANK_VISION_CURSOR_SHAPE = 3,
    PLANK_VISION_CURSOR_POSITION = 4,
    PLANK_VISION_CURSOR_VISIBLE = 1,
    PLANK_VISION_CURSOR_FIRST_CHUNK = 2,
    PLANK_VISION_CURSOR_LAST_CHUNK = 4,
    PLANK_VISION_CURSOR_MAX_CHUNK_SIZE = 48 * 1024,
};

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

int32_t plank_vision_transport_send_mouse_position(
    PlankVisionTransport *transport,
    uint16_t x,
    uint16_t y,
    uint16_t maximum_x,
    uint16_t maximum_y);

int32_t plank_vision_transport_send_mouse_button(
    PlankVisionTransport *transport,
    uint8_t button,
    uint8_t pressed);

int32_t plank_vision_transport_send_scroll(
    PlankVisionTransport *transport,
    int16_t amount,
    uint8_t horizontal);

int32_t plank_vision_transport_send_key(
    PlankVisionTransport *transport,
    uint16_t key_code,
    uint8_t pressed,
    uint8_t modifiers);

int32_t plank_vision_transport_send_utf8(
    PlankVisionTransport *transport,
    const uint8_t *text,
    size_t text_size);

int32_t plank_vision_transport_send_raw_hid(
    PlankVisionTransport *transport,
    const uint8_t *frame,
    size_t frame_size);

// Receives cursor updates and Host raw-HID control frames from the data lane.
int32_t plank_vision_transport_receive_data_event(
    PlankVisionTransport *transport,
    PlankVisionCursorEvent *cursor_event,
    uint8_t *chunk,
    size_t chunk_capacity,
    size_t *chunk_size,
    uint32_t timeout_ms);

void plank_vision_transport_disconnect(PlankVisionTransport *transport);

#ifdef __cplusplus
}
#endif

#endif
