#include "PlankRawHidFrame.h"

#include "../../moonlight-common-c/moonlight-common-c/src/plank.h"

static uint16_t read_le16(const uint8_t *value) {
    return (uint16_t)value[0] | ((uint16_t)value[1] << 8);
}

static uint32_t read_le32(const uint8_t *value) {
    return (uint32_t)value[0] | ((uint32_t)value[1] << 8) |
           ((uint32_t)value[2] << 16) | ((uint32_t)value[3] << 24);
}

static void write_le16(uint8_t *out, uint16_t value) {
    out[0] = (uint8_t)value;
    out[1] = (uint8_t)(value >> 8);
}

static void write_le32(uint8_t *out, uint32_t value) {
    out[0] = (uint8_t)value;
    out[1] = (uint8_t)(value >> 8);
    out[2] = (uint8_t)(value >> 16);
    out[3] = (uint8_t)(value >> 24);
}

static int make_lifecycle_frame(
    uint16_t type, uint16_t generation, uint8_t *out, size_t capacity) {
    if (generation == 0 || out == NULL ||
            capacity < sizeof(PLANK_RAW_HID_WIRE_HEADER)) return 0;
    write_le32(out, PLANK_RAW_HID_WIRE_MAGIC);
    write_le16(out + 4, PLANK_RAW_HID_WIRE_VERSION);
    write_le16(out + 6, type);
    write_le16(out + 8, 0);
    write_le16(out + 10, generation);
    write_le32(out + 12, 0);
    write_le32(out + 16, 0);
    return 1;
}

int plank_vision_raw_hid_make_suspend(
    uint16_t generation, uint8_t *out, size_t capacity) {
    return make_lifecycle_frame(PLANK_RAW_HID_SUSPEND, generation, out, capacity);
}

int plank_vision_raw_hid_make_detach(
    uint16_t generation, uint8_t *out, size_t capacity) {
    return make_lifecycle_frame(PLANK_RAW_HID_DETACH, generation, out, capacity);
}

int plank_vision_raw_hid_frame_valid(
    const uint8_t *frame, size_t frame_size,
    PlankVisionRawHidDirection direction) {
    if (frame == NULL || frame_size < sizeof(PLANK_RAW_HID_WIRE_HEADER) ||
            frame_size > sizeof(PLANK_RAW_HID_WIRE_HEADER) +
                         PLANK_RAW_HID_MAX_PAYLOAD_SIZE ||
            read_le32(frame) != PLANK_RAW_HID_WIRE_MAGIC ||
            read_le16(frame + 4) != PLANK_RAW_HID_WIRE_VERSION ||
            read_le32(frame + 16) != frame_size - sizeof(PLANK_RAW_HID_WIRE_HEADER)) {
        return 0;
    }

    const uint16_t type = read_le16(frame + 6);
    const uint16_t interface_id = read_le16(frame + 8);
    if (interface_id >= PLANK_RAW_HID_MAX_INTERFACES) return 0;

    if (direction == PLANK_VISION_RAW_HID_TO_HOST) {
        switch (type) {
        case PLANK_RAW_HID_DEVICE:
        case PLANK_RAW_HID_DESCRIPTOR:
        case PLANK_RAW_HID_INPUT:
        case PLANK_RAW_HID_GET_REPORT_REPLY:
        case PLANK_RAW_HID_SET_REPORT_REPLY:
        case PLANK_RAW_HID_DETACH:
        case PLANK_RAW_HID_SUSPEND:
            return 1;
        default:
            return 0;
        }
    }
    if (direction == PLANK_VISION_RAW_HID_FROM_HOST) {
        switch (type) {
        case PLANK_RAW_HID_GET_REPORT:
        case PLANK_RAW_HID_SET_REPORT:
        case PLANK_RAW_HID_OUTPUT:
        case PLANK_RAW_HID_ATTACH_RESULT:
        case PLANK_RAW_HID_OPEN:
        case PLANK_RAW_HID_CLOSE:
            return 1;
        default:
            return 0;
        }
    }
    return 0;
}
