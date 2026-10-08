#include "../Bridge/PlankRawHidFrame.h"

#include <assert.h>
#include <stdint.h>
#include <string.h>

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

int main(void) {
    uint8_t frame[24] = {0};
    write_le32(frame, 0x504c5748u);
    write_le16(frame + 4, 2);
    write_le16(frame + 6, 3); // INPUT is Relay to Host only.
    write_le32(frame + 16, 4);
    assert(plank_vision_raw_hid_frame_valid(frame, sizeof(frame),
                                            PLANK_VISION_RAW_HID_TO_HOST));
    assert(!plank_vision_raw_hid_frame_valid(frame, sizeof(frame),
                                             PLANK_VISION_RAW_HID_FROM_HOST));
    assert(!plank_vision_raw_hid_frame_valid(frame, 19,
                                             PLANK_VISION_RAW_HID_TO_HOST));

    write_le16(frame + 6, 4); // GET_REPORT is Host to Relay only.
    assert(plank_vision_raw_hid_frame_valid(frame, sizeof(frame),
                                            PLANK_VISION_RAW_HID_FROM_HOST));
    assert(!plank_vision_raw_hid_frame_valid(frame, sizeof(frame),
                                             PLANK_VISION_RAW_HID_TO_HOST));

    write_le32(frame + 16, 5);
    assert(!plank_vision_raw_hid_frame_valid(frame, sizeof(frame),
                                             PLANK_VISION_RAW_HID_FROM_HOST));
    write_le32(frame + 16, 4);
    write_le16(frame + 8, 16);
    assert(!plank_vision_raw_hid_frame_valid(frame, sizeof(frame),
                                             PLANK_VISION_RAW_HID_FROM_HOST));
    write_le16(frame + 8, 0);
    frame[0] = 0;
    assert(!plank_vision_raw_hid_frame_valid(frame, sizeof(frame),
                                             PLANK_VISION_RAW_HID_FROM_HOST));
    frame[0] = 'H';
    write_le16(frame + 6, 0xffff);
    assert(!plank_vision_raw_hid_frame_valid(frame, sizeof(frame),
                                             PLANK_VISION_RAW_HID_FROM_HOST));
    assert(!plank_vision_raw_hid_make_suspend(0, frame, sizeof(frame)));
    assert(!plank_vision_raw_hid_make_suspend(7, frame, 19));
    assert(plank_vision_raw_hid_make_suspend(7, frame, sizeof(frame)));
    assert(plank_vision_raw_hid_frame_valid(frame, 20,
                                            PLANK_VISION_RAW_HID_TO_HOST));
    assert(frame[6] == 13 && frame[10] == 7 && frame[16] == 0);
    return 0;
}
