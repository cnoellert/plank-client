#ifndef PLANK_VISION_RAW_HID_FRAME_H
#define PLANK_VISION_RAW_HID_FRAME_H

#include <stddef.h>
#include <stdint.h>

typedef enum PlankVisionRawHidDirection {
    PLANK_VISION_RAW_HID_TO_HOST = 1,
    PLANK_VISION_RAW_HID_FROM_HOST = 2,
} PlankVisionRawHidDirection;

// Check the complete PLWH frame before it crosses the Relay/Host boundary.
// HID report and descriptor contents remain opaque to the Client.
int plank_vision_raw_hid_frame_valid(
    const uint8_t *frame, size_t frame_size,
    PlankVisionRawHidDirection direction);

// Release a Host tablet contact when the Relay link disappears mid-stroke.
// The caller forwards the resulting 20-byte PLWH frame on the Host input lane.
int plank_vision_raw_hid_make_suspend(
    uint16_t generation, uint8_t *out, size_t capacity);

#endif
