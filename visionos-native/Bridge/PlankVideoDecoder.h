#ifndef PLANK_VIDEO_DECODER_H
#define PLANK_VIDEO_DECODER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PlankVideoDecoder PlankVideoDecoder;

enum {
    PLANK_VIDEO_DECODER_NO_FRAME = 0,
    PLANK_VIDEO_DECODER_FRAME = 1,
    PLANK_VIDEO_DECODER_ERROR = -1,
};

PlankVideoDecoder *plank_video_decoder_create(
    char *error, size_t error_capacity);

int32_t plank_video_decoder_decode(
    PlankVideoDecoder *decoder,
    const uint8_t *encoded, size_t encoded_size,
    uint8_t *bgra, size_t bgra_capacity,
    uint32_t *width, uint32_t *height, uint32_t *stride,
    char *error, size_t error_capacity);

void plank_video_decoder_destroy(PlankVideoDecoder *decoder);

#ifdef __cplusplus
}
#endif

#endif
