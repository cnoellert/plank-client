// Tests the production bridge with a deterministic native input sender.
// Build like PlankControlBridgeTests.c, with Bridge/PlankRawHidFrame.c.
#include "../Bridge/PlankTransportBridge.c"

static unsigned checks;
#define CHECK(value) do { ++checks; if (!(value)) { fprintf(stderr, "raw HID session check failed at line %d: %s\n", __LINE__, #value); abort(); } } while (0)

static uint8_t sent[16][512];
static size_t sizes[16];
static unsigned sends, fail_at;
static int32_t failure_code;

int32_t plank_transport_native_input_send(
    PlankTransportNativeEndpoint *endpoint, uint8_t type,
    const uint8_t *payload, size_t size) {
    CHECK(endpoint != NULL && type == PLANK_TRANSPORT_INPUT_RAW_HID_WACOM);
    CHECK(sends < 16 && size <= sizeof(sent[0]));
    memcpy(sent[sends], payload, size);
    sizes[sends++] = size;
    return sends == fail_at ? failure_code : PLANK_TRANSPORT_OK;
}

uint32_t plank_transport_native_endpoint_state(const PlankTransportNativeEndpoint *endpoint) {
    (void)endpoint; return PLANK_TRANSPORT_STATE_READY;
}

static void write16(uint8_t *out, uint16_t value) {
    out[0] = (uint8_t)value; out[1] = (uint8_t)(value >> 8);
}
static void write32(uint8_t *out, uint32_t value) {
    for (unsigned i = 0; i < 4; ++i) out[i] = (uint8_t)(value >> (i * 8));
}
static void frame_header(uint8_t *frame, uint16_t type, uint16_t generation, size_t payload_size) {
    memset(frame, 0, sizeof(PLANK_RAW_HID_WIRE_HEADER));
    write32(frame, PLANK_RAW_HID_WIRE_MAGIC);
    write16(frame + 4, PLANK_RAW_HID_WIRE_VERSION);
    write16(frame + 6, type); write16(frame + 10, generation);
    write32(frame + 16, (uint32_t)payload_size);
}
static PlankVisionTransport fresh_transport(void) {
    sends = 0; fail_at = 0; failure_code = PLANK_TRANSPORT_OK;
    PlankVisionTransport result = {0};
    result.endpoint = (PlankTransportNativeEndpoint *)1;
    return result;
}

int main(void) {
    uint8_t device[sizeof(PLANK_RAW_HID_WIRE_HEADER) + sizeof(PLANK_RAW_HID_DEVICE_MESSAGE)];
    memset(device, 0x5a, sizeof(device)); // Identity bytes must stay opaque and identical.
    frame_header(device, PLANK_RAW_HID_DEVICE, 354, sizeof(PLANK_RAW_HID_DEVICE_MESSAGE));
    write16(device + sizeof(PLANK_RAW_HID_WIRE_HEADER), 2);
    uint8_t descriptor[24], report[24], suspend[20], detach[20];
    frame_header(descriptor, PLANK_RAW_HID_DESCRIPTOR, 354, 4);
    frame_header(report, PLANK_RAW_HID_INPUT, 354, 4);
    memset(descriptor + 20, 0x17, 4); memset(report + 20, 0x28, 4);
    CHECK(plank_vision_raw_hid_make_suspend(354, suspend, sizeof(suspend)));
    CHECK(plank_vision_raw_hid_make_detach(354, detach, sizeof(detach)));
    CHECK(!plank_vision_raw_hid_make_detach(0, detach, sizeof(detach)));
    CHECK(!plank_vision_raw_hid_make_detach(354, detach, 19));
    CHECK(!plank_vision_raw_hid_make_detach(354, NULL, 20));
    CHECK(plank_vision_raw_hid_frame_valid(detach, sizeof(detach), PLANK_VISION_RAW_HID_TO_HOST));

    PlankVisionTransport transport = fresh_transport();
    CHECK(plank_vision_transport_send_raw_hid(&transport, device, sizeof(device)) == PLANK_VISION_TRANSPORT_OK);
    CHECK(sends == 3); // Broken single-DEVICE behavior must fail here.
    CHECK(sizes[0] == sizeof(device) && memcmp(sent[0], device, sizeof(device)) == 0);
    CHECK(sizes[1] == 20 && memcmp(sent[1], detach, 20) == 0);
    CHECK(sizes[2] == sizeof(device) && memcmp(sent[2], device, sizeof(device)) == 0);
    // No descriptors precede DETACH, so the preparatory DEVICE cannot create
    // an intermediate group. Only the real descriptor attachment can ACK.
    CHECK(plank_vision_transport_send_raw_hid(&transport, descriptor, sizeof(descriptor)) == PLANK_VISION_TRANSPORT_OK);
    CHECK(plank_vision_transport_send_raw_hid(&transport, report, sizeof(report)) == PLANK_VISION_TRANSPORT_OK);
    CHECK(sends == 5 && memcmp(sent[3], descriptor, 24) == 0 && memcmp(sent[4], report, 24) == 0);
    // Focus suspension and Relay reattachment within the same desktop session
    // remain byte-for-byte single sends, including a new Relay generation.
    CHECK(plank_vision_transport_send_raw_hid(&transport, suspend, 20) == PLANK_VISION_TRANSPORT_OK);
    write16(device + 10, 355);
    CHECK(plank_vision_transport_send_raw_hid(&transport, device, sizeof(device)) == PLANK_VISION_TRANSPORT_OK);
    CHECK(sends == 7 && memcmp(sent[5], suspend, 20) == 0 && memcmp(sent[6], device, sizeof(device)) == 0);
    CHECK(plank_vision_transport_send_raw_hid(&transport, detach, 20) == PLANK_VISION_TRANSPORT_OK);
    CHECK(sends == 8 && memcmp(sent[7], detach, 20) == 0);

    // A new desktop endpoint resets again, irrespective of Relay transport.
    transport = fresh_transport();
    CHECK(plank_vision_transport_send_raw_hid(&transport, device, sizeof(device)) == PLANK_VISION_TRANSPORT_OK);
    CHECK(sends == 3 && read_le16(sent[1] + 10) == 355);

    // A failure at any point is terminal, carries the native error unchanged,
    // and cannot emit later sequence frames or allow a partial attach retry.
    const int32_t errors[] = {PLANK_TRANSPORT_TIMEOUT, PLANK_TRANSPORT_ERROR_RUNTIME};
    for (unsigned e = 0; e < 2; ++e) {
        for (unsigned stage = 1; stage <= 3; ++stage) {
            transport = fresh_transport(); fail_at = stage; failure_code = errors[e];
            CHECK(plank_vision_transport_send_raw_hid(&transport, device, sizeof(device)) == PLANK_VISION_TRANSPORT_ERROR);
            CHECK(sends == stage);
            const uint64_t failure = atomic_load(&transport.first_failure);
            CHECK((int32_t)(failure >> 32) == errors[e]);
            CHECK(((failure >> 8) & 0xff) == PLANK_VISION_LANE_INPUT);
            CHECK((failure & 0xff) == (e == 0 ? PLANK_VISION_FAILURE_QUEUE_FULL : PLANK_VISION_FAILURE_TERMINATED));
            CHECK(plank_vision_transport_send_raw_hid(&transport, device, sizeof(device)) == PLANK_VISION_TRANSPORT_ERROR);
            CHECK(plank_vision_transport_send_raw_hid(&transport, report, sizeof(report)) == PLANK_VISION_TRANSPORT_ERROR);
            CHECK(sends == stage && atomic_load(&transport.first_failure) == failure);
        }
    }
    transport = fresh_transport();
    write16(device + 10, 0);
    CHECK(plank_vision_transport_send_raw_hid(&transport, device, sizeof(device)) == PLANK_VISION_TRANSPORT_ERROR && sends == 0);
    write16(device + 10, 356);
    CHECK(plank_vision_transport_send_raw_hid(&transport, device, sizeof(device) - 1) == PLANK_VISION_TRANSPORT_ERROR && sends == 0);
    write16(device + 20, 0);
    CHECK(plank_vision_transport_send_raw_hid(&transport, device, sizeof(device)) == PLANK_VISION_TRANSPORT_ERROR && sends == 0);
    write16(device + 20, PLANK_RAW_HID_MAX_INTERFACES + 1);
    CHECK(plank_vision_transport_send_raw_hid(&transport, device, sizeof(device)) == PLANK_VISION_TRANSPORT_ERROR && sends == 0);
    write16(device + 20, 2);
    CHECK(plank_vision_transport_send_raw_hid(&transport, device, sizeof(device)) == PLANK_VISION_TRANSPORT_OK && sends == 3);
    printf("Raw HID session bridge: %u checks passed\n", checks);
}
