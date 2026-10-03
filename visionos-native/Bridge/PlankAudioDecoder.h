#ifndef PLANK_AUDIO_DECODER_H
#define PLANK_AUDIO_DECODER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Host audio is Opus at 48 kHz. This slice plays the stereo baseline only.
enum {
    PLANK_VISION_AUDIO_SAMPLE_RATE = 48000,
    PLANK_VISION_AUDIO_CHANNELS = 2,
    // 120 ms, the largest Opus packet duration.
    PLANK_VISION_AUDIO_MAX_FRAME_SAMPLES = 5760,
};

typedef struct PlankVisionAudioDecoder PlankVisionAudioDecoder;

// Creates a multistream decoder from the negotiated layout. Returns NULL with
// an error message when the layout is not stereo 48 kHz, the mapping does not
// fit the stream counts, or libopus is not linked.
PlankVisionAudioDecoder *plank_audio_decoder_create(
    int32_t sample_rate,
    int32_t channels,
    int32_t streams,
    int32_t coupled_streams,
    const uint8_t *mapping,
    size_t mapping_count,
    char *error,
    size_t error_capacity);

// Decodes one packet into interleaved stereo float samples. A NULL packet
// conceals exactly frame_samples of lost audio with Opus packet-loss
// concealment, matching the desktop Client. Returns the decoded frame count,
// or a negative value for an invalid packet or argument.
int32_t plank_audio_decoder_decode(
    PlankVisionAudioDecoder *decoder,
    const uint8_t *packet,
    size_t packet_size,
    uint32_t frame_samples,
    float *interleaved,
    size_t capacity_frames);

void plank_audio_decoder_destroy(PlankVisionAudioDecoder *decoder);

// True for the packet durations Opus can encode or conceal (2.5-120 ms).
int plank_audio_frame_samples_valid(uint32_t frame_samples);

// Concealment frames for a transport hole: whole frames covering
// missing_samples, as the desktop Client does, capped at maximum_frames so a
// long stall cannot flood the bounded playback queue.
uint32_t plank_audio_concealment_frames(
    uint32_t missing_samples, uint32_t frame_samples, uint32_t maximum_frames);

#ifdef __cplusplus
}
#endif

#endif
