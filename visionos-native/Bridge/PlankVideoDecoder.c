#include "PlankVideoDecoder.h"

#include <libavcodec/avcodec.h>
#include <libavcodec/defs.h>
#include <libavutil/error.h>
#include <libavutil/pixfmt.h>
#include <libswscale/swscale.h>

#include <stdio.h>
#include <stdlib.h>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif

struct PlankVideoDecoder {
    AVCodecContext *codec;
    AVFrame *frame;
    AVPacket *packet;
    struct SwsContext *scale;
};

size_t plank_video_decoder_input_padding(void) {
    return AV_INPUT_BUFFER_PADDING_SIZE;
}

static void set_error(char *error, size_t capacity, const char *message) {
    if (error == NULL || capacity == 0) return;
    snprintf(error, capacity, "%s", message == NULL ? "Video decoder error" : message);
}

static void set_av_error(char *error, size_t capacity, const char *prefix, int result) {
    char detail[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(result, detail, sizeof(detail));
    if (error != NULL && capacity > 0) {
        snprintf(error, capacity, "%s: %s", prefix, detail);
    }
}

// The negotiated identity-GBR stream decodes to full-range planar GBR10.
// Copy its channels directly to the current 8-bit BGRA display surface;
// swscale otherwise routes this format through an unnecessary YUV conversion.
static void convert_gbrp10le_to_bgra(const AVFrame *frame, uint8_t *bgra, size_t stride) {
    for (int y = 0; y < frame->height; ++y) {
        const uint16_t *green = (const uint16_t *)(frame->data[0] + y * frame->linesize[0]);
        const uint16_t *blue = (const uint16_t *)(frame->data[1] + y * frame->linesize[1]);
        const uint16_t *red = (const uint16_t *)(frame->data[2] + y * frame->linesize[2]);
        uint8_t *output = bgra + (size_t)y * stride;
        int x = 0;
#if defined(__aarch64__)
        for (; x + 8 <= frame->width; x += 8) {
            uint8x8x4_t pixels;
            pixels.val[0] = vshrn_n_u16(vld1q_u16(blue + x), 2);
            pixels.val[1] = vshrn_n_u16(vld1q_u16(green + x), 2);
            pixels.val[2] = vshrn_n_u16(vld1q_u16(red + x), 2);
            pixels.val[3] = vdup_n_u8(255);
            vst4_u8(output + (size_t)x * 4, pixels);
        }
#endif
        for (; x < frame->width; ++x) {
            output[(size_t)x * 4 + 0] = (uint8_t)(blue[x] >> 2);
            output[(size_t)x * 4 + 1] = (uint8_t)(green[x] >> 2);
            output[(size_t)x * 4 + 2] = (uint8_t)(red[x] >> 2);
            output[(size_t)x * 4 + 3] = 255;
        }
    }
}

PlankVideoDecoder *plank_video_decoder_create(char *error, size_t error_capacity) {
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_HEVC);
    if (codec == NULL) {
        set_error(error, error_capacity, "HEVC decoder is unavailable");
        return NULL;
    }

    PlankVideoDecoder *decoder = calloc(1, sizeof(*decoder));
    if (decoder == NULL) {
        set_error(error, error_capacity, "Unable to allocate video decoder");
        return NULL;
    }
    decoder->codec = avcodec_alloc_context3(codec);
    decoder->frame = av_frame_alloc();
    decoder->packet = av_packet_alloc();
    if (decoder->codec == NULL || decoder->frame == NULL || decoder->packet == NULL) {
        set_error(error, error_capacity, "Unable to allocate FFmpeg video state");
        plank_video_decoder_destroy(decoder);
        return NULL;
    }
    decoder->codec->thread_count = 0;
    decoder->codec->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
    const int result = avcodec_open2(decoder->codec, codec, NULL);
    if (result < 0) {
        set_av_error(error, error_capacity, "Unable to open HEVC decoder", result);
        plank_video_decoder_destroy(decoder);
        return NULL;
    }
    return decoder;
}

int32_t plank_video_decoder_decode(
    PlankVideoDecoder *decoder,
    const uint8_t *encoded, size_t encoded_size,
    uint8_t *bgra, size_t bgra_capacity,
    uint32_t *width, uint32_t *height, uint32_t *stride,
    char *error, size_t error_capacity) {
    if (decoder == NULL || encoded == NULL || encoded_size == 0 ||
            bgra == NULL || width == NULL || height == NULL || stride == NULL) {
        set_error(error, error_capacity, "Invalid video decode arguments");
        return PLANK_VIDEO_DECODER_ERROR;
    }

    av_packet_unref(decoder->packet);
    decoder->packet->data = (uint8_t *)encoded;
    decoder->packet->size = (int)encoded_size;
    int result = avcodec_send_packet(decoder->codec, decoder->packet);
    if (result < 0) {
        set_av_error(error, error_capacity, "Unable to submit HEVC frame", result);
        return PLANK_VIDEO_DECODER_ERROR;
    }

    result = avcodec_receive_frame(decoder->codec, decoder->frame);
    if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) {
        return PLANK_VIDEO_DECODER_NO_FRAME;
    }
    if (result < 0) {
        set_av_error(error, error_capacity, "Unable to decode HEVC frame", result);
        return PLANK_VIDEO_DECODER_ERROR;
    }

    const size_t output_stride = (size_t)decoder->frame->width * 4;
    const size_t required = output_stride * (size_t)decoder->frame->height;
    if (required > bgra_capacity) {
        set_error(error, error_capacity, "Decoded video buffer is too small");
        return PLANK_VIDEO_DECODER_ERROR;
    }
    *width = (uint32_t)decoder->frame->width;
    *height = (uint32_t)decoder->frame->height;
    *stride = (uint32_t)output_stride;
    if (decoder->frame->format == AV_PIX_FMT_GBRP10LE) {
        convert_gbrp10le_to_bgra(decoder->frame, bgra, output_stride);
        return PLANK_VIDEO_DECODER_FRAME;
    }
    decoder->scale = sws_getCachedContext(
        decoder->scale,
        decoder->frame->width, decoder->frame->height,
        (enum AVPixelFormat)decoder->frame->format,
        decoder->frame->width, decoder->frame->height,
        AV_PIX_FMT_BGRA, SWS_POINT, NULL, NULL, NULL);
    if (decoder->scale == NULL) {
        set_error(error, error_capacity, "Unable to create video colour converter");
        return PLANK_VIDEO_DECODER_ERROR;
    }
    uint8_t *destination[4] = {bgra, NULL, NULL, NULL};
    int destination_stride[4] = {(int)output_stride, 0, 0, 0};
    result = sws_scale(
        decoder->scale,
        (const uint8_t *const *)decoder->frame->data,
        decoder->frame->linesize,
        0, decoder->frame->height,
        destination, destination_stride);
    if (result != decoder->frame->height) {
        set_error(error, error_capacity, "Unable to convert decoded video frame");
        return PLANK_VIDEO_DECODER_ERROR;
    }
    return PLANK_VIDEO_DECODER_FRAME;
}

void plank_video_decoder_destroy(PlankVideoDecoder *decoder) {
    if (decoder == NULL) return;
    sws_freeContext(decoder->scale);
    av_packet_free(&decoder->packet);
    av_frame_free(&decoder->frame);
    avcodec_free_context(&decoder->codec);
    free(decoder);
}
