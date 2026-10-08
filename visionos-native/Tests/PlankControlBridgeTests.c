// Exercises the real data-event bridge with a deterministic native receiver.
// Build on macOS with the transport include path, -DPLANK_NATIVE_TRANSPORT=1,
// -Wl,-dead_strip,-undefined,dynamic_lookup and Bridge/PlankRawHidFrame.c.
#include "../Bridge/PlankTransportBridge.c"

static unsigned next_packet;
int32_t plank_transport_native_data_receive(
    PlankTransportNativeEndpoint *endpoint, uint8_t *payload, size_t capacity,
    size_t *size, uint32_t timeout_ms) {
    (void)endpoint; (void)timeout_ms;
    const uint16_t types[] = {
        PLANK_TRANSPORT_EVENT_HDR_MODE, PLANK_TRANSPORT_EVENT_CLIPBOARD_OFFER,
        PLANK_TRANSPORT_EVENT_CURSOR_POSITION
    };
    if (next_packet >= 3 && next_packet < 6) {
        // Control records on the same lane: a valid bitrate acknowledgement,
        // one with a short payload, and an unhandled control type.
        const uint32_t ack[3] = {100000, 90000, 120000};
        const unsigned index = next_packet++;
        const uint16_t type = index == 5 ? PLANK_TRANSPORT_CONTROL_HOST_TERMINATE :
                                           PLANK_TRANSPORT_CONTROL_VIDEO_BITRATE_APPLIED;
        const size_t count = index == 3 ? 3 : (index == 4 ? 2 : 1);
        return plank_transport_control_encode(type, ack, count, payload, capacity, size) == 0 ?
            PLANK_TRANSPORT_OK : PLANK_TRANSPORT_ERROR_RUNTIME;
    }
    if (next_packet >= 6) return PLANK_TRANSPORT_TIMEOUT;
    uint8_t cursor[32] = {0x50, 0x43, 0x4c, 0x50, 1, 0, 0, 0, 1};
    cursor[24] = 100; cursor[28] = 100;
    const uint16_t type = types[next_packet++];
    return plank_transport_event_encode(
        type, type == PLANK_TRANSPORT_EVENT_CURSOR_POSITION ? cursor : NULL,
        type == PLANK_TRANSPORT_EVENT_CURSOR_POSITION ? sizeof(cursor) : 0,
        payload, capacity, size) == 0 ? PLANK_TRANSPORT_OK : PLANK_TRANSPORT_ERROR_RUNTIME;
}
static uint8_t sent[64];
static size_t sent_size;
static unsigned sends;
int32_t plank_transport_native_data_send(
    PlankTransportNativeEndpoint *endpoint, const uint8_t *payload, size_t size) {
    (void)endpoint;
    if (size > sizeof(sent)) return PLANK_TRANSPORT_ERROR_INVALID_ARGUMENT;
    memcpy(sent, payload, size);
    sent_size = size;
    ++sends;
    return PLANK_TRANSPORT_OK;
}
uint32_t plank_transport_native_endpoint_state(const PlankTransportNativeEndpoint *endpoint) {
    (void)endpoint; return PLANK_TRANSPORT_STATE_READY;
}

#define CHECK(value) do { if (!(value)) { fprintf(stderr, "control bridge check failed at line %d\n", __LINE__); abort(); } } while (0)
int main(void) {
    PlankVisionTransport transport = {0};
    transport.endpoint = (PlankTransportNativeEndpoint *)1;
    PlankVisionCursorEvent event;
    uint8_t chunk[PLANK_VISION_CURSOR_MAX_CHUNK_SIZE];
    size_t size;
    for (unsigned i = 0; i < 2; ++i) {
        CHECK(plank_vision_transport_receive_data_event(
            &transport, &event, chunk, sizeof(chunk), &size, 0) == PLANK_VISION_TRANSPORT_DATA_IGNORED);
        CHECK(size == 0);
    }
    CHECK(plank_vision_transport_receive_data_event(
        &transport, &event, chunk, sizeof(chunk), &size, 0) == PLANK_VISION_TRANSPORT_OK);
    CHECK(event.type == PLANK_VISION_CURSOR_POSITION && event.sequence == 1);
    // The bitrate acknowledgement is decoded with all three values.
    CHECK(plank_vision_transport_receive_data_event(
        &transport, &event, chunk, sizeof(chunk), &size, 0) == PLANK_VISION_TRANSPORT_OK);
    CHECK(event.type == PLANK_VISION_BITRATE_APPLIED && size == 0);
    CHECK(event.bitrate_requested_kbps == 100000 && event.bitrate_applied_kbps == 90000 &&
          event.bitrate_peak_kbps == 120000);
    // A malformed acknowledgement and other control records stay errors.
    CHECK(plank_vision_transport_receive_data_event(
        &transport, &event, chunk, sizeof(chunk), &size, 0) == PLANK_VISION_TRANSPORT_ERROR);
    CHECK(plank_vision_transport_receive_data_event(
        &transport, &event, chunk, sizeof(chunk), &size, 0) == PLANK_VISION_TRANSPORT_ERROR);
    CHECK(plank_vision_transport_receive_data_event(
        &transport, &event, chunk, sizeof(chunk), &size, 0) == PLANK_VISION_TRANSPORT_TIMEOUT);

    // A live target goes out as native SET_VIDEO_BITRATE with one value;
    // values the Host would treat as fatal never leave the Client.
    CHECK(plank_vision_transport_set_video_bitrate(&transport, 75000) == PLANK_VISION_TRANSPORT_OK);
    PlankTransportControlPacket control = {0};
    CHECK(sends == 1 && plank_transport_control_decode(sent, sent_size, &control) == 0);
    CHECK(control.type == PLANK_TRANSPORT_CONTROL_SET_VIDEO_BITRATE && control.payload_size == 4);
    CHECK(plank_transport_control_read_u32(control.payload) == 75000);
    CHECK(plank_vision_transport_set_video_bitrate(&transport, 499) == PLANK_VISION_TRANSPORT_ERROR);
    CHECK(plank_vision_transport_set_video_bitrate(&transport, 500001) == PLANK_VISION_TRANSPORT_ERROR);
    CHECK(sends == 1);
    puts("Control bridge: ignored events consumed, following cursor delivered, genuine timeout distinct, bitrate request and acknowledgement framed");
}
