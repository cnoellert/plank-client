#include "PlankAudioDecoder.h"

#include <stdio.h>
#include <stdlib.h>

#if PLANK_OPUS_AUDIO
#include <opus_multistream.h>
#endif

struct PlankVisionAudioDecoder {
#if PLANK_OPUS_AUDIO
    OpusMSDecoder *opus;
#else
    void *opus;
#endif
};

static void set_error(char *error, size_t capacity, const char *message) {
    if (error == NULL || capacity == 0) return;
    snprintf(error, capacity, "%s", message);
}

int plank_audio_frame_samples_valid(uint32_t frame_samples) {
    switch (frame_samples) {
    case 120: case 240: case 480: case 960: case 1920: case 2880:
    case 3840: case 4800: case 5760:
        return 1;
    default:
        return 0;
    }
}

uint32_t plank_audio_concealment_frames(
    uint32_t missing_samples, uint32_t frame_samples, uint32_t maximum_frames) {
    if (missing_samples == 0 || !plank_audio_frame_samples_valid(frame_samples)) {
        return 0;
    }
    const uint64_t frames =
        ((uint64_t)missing_samples + frame_samples - 1) / frame_samples;
    return frames > maximum_frames ? maximum_frames : (uint32_t)frames;
}

PlankVisionAudioDecoder *plank_audio_decoder_create(
    int32_t sample_rate,
    int32_t channels,
    int32_t streams,
    int32_t coupled_streams,
    const uint8_t *mapping,
    size_t mapping_count,
    char *error,
    size_t error_capacity) {
    if (sample_rate != PLANK_VISION_AUDIO_SAMPLE_RATE ||
            channels != PLANK_VISION_AUDIO_CHANNELS ||
            streams <= 0 || streams > channels ||
            coupled_streams < 0 || coupled_streams > streams ||
            mapping == NULL || mapping_count != (size_t)channels) {
        set_error(error, error_capacity,
                  "The Host audio format is not stereo 48 kHz Opus");
        return NULL;
    }
    // Each output channel names a decoded stream channel; 255 is silence.
    for (size_t index = 0; index < mapping_count; ++index) {
        if (mapping[index] != 255 &&
                mapping[index] >= (uint32_t)(streams + coupled_streams)) {
            set_error(error, error_capacity, "The Host audio channel map is invalid");
            return NULL;
        }
    }
#if !PLANK_OPUS_AUDIO
    set_error(error, error_capacity, "The Opus decoder is not linked");
    return NULL;
#else
    PlankVisionAudioDecoder *decoder = calloc(1, sizeof(*decoder));
    if (decoder == NULL) {
        set_error(error, error_capacity, "Unable to allocate the audio decoder");
        return NULL;
    }
    int result = OPUS_OK;
    decoder->opus = opus_multistream_decoder_create(
        sample_rate, channels, streams, coupled_streams, mapping, &result);
    if (decoder->opus == NULL || result != OPUS_OK) {
        if (error != NULL && error_capacity > 0) {
            snprintf(error, error_capacity, "Unable to create the Opus decoder: %s",
                     opus_strerror(result));
        }
        free(decoder);
        return NULL;
    }
    return decoder;
#endif
}

int32_t plank_audio_decoder_decode(
    PlankVisionAudioDecoder *decoder,
    const uint8_t *packet,
    size_t packet_size,
    uint32_t frame_samples,
    float *interleaved,
    size_t capacity_frames) {
    if (decoder == NULL || interleaved == NULL ||
            capacity_frames < PLANK_VISION_AUDIO_MAX_FRAME_SAMPLES) {
        return -1;
    }
    if (packet == NULL) {
        // Concealment needs a frame size Opus can synthesize.
        if (!plank_audio_frame_samples_valid(frame_samples)) return -1;
    } else if (packet_size == 0 || packet_size > 0x7fffffff) {
        return -1;
    }
#if !PLANK_OPUS_AUDIO
    (void)packet; (void)packet_size; (void)frame_samples;
    return -1;
#else
    const int frames = opus_multistream_decode_float(
        decoder->opus, packet, packet == NULL ? 0 : (opus_int32)packet_size,
        interleaved,
        packet == NULL ? (int)frame_samples : PLANK_VISION_AUDIO_MAX_FRAME_SAMPLES,
        0);
    return frames < 0 ? -1 : frames;
#endif
}

void plank_audio_decoder_destroy(PlankVisionAudioDecoder *decoder) {
    if (decoder == NULL) return;
#if PLANK_OPUS_AUDIO
    opus_multistream_decoder_destroy(decoder->opus);
#endif
    free(decoder);
}
