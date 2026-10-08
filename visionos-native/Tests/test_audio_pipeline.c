// Focused checks for the Host-audio decoder and playback queue. Build against
// a host libopus from scripts/build-visionos-opus.sh, for example:
//   cc -std=c11 -O0 -Wall -Wextra -DPLANK_OPUS_AUDIO=1 -I<opus>/include/opus \
//      -IBridge Tests/test_audio_pipeline.c Bridge/PlankAudioDecoder.c \
//      Bridge/PlankAudioRing.c <opus>/lib/libopus.a -lm -o test_audio_pipeline
// Failures are counted explicitly, so NDEBUG and optimisation cannot hide them.
#include "PlankAudioDecoder.h"
#include "PlankAudioRing.h"

#include <math.h>
#include <opus_multistream.h>
#include <stdio.h>
#include <string.h>

static int checks;
static int failures;

#define CHECK(condition) do { \
    ++checks; \
    if (!(condition)) { \
        ++failures; \
        fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
    } \
} while (0)

enum { FRAME = 240 };  // 5 ms, the AVP's requested packet duration

static const uint8_t stereo_map[2] = {0, 1};

static double energy(const float *interleaved, int frames, int channel) {
    double sum = 0;
    for (int index = 0; index < frames; ++index) {
        const double value = interleaved[index * 2 + channel];
        sum += value * value;
    }
    return sum;
}

// Encodes a 1 kHz tone on the left channel only, as the Host's stereo
// multistream encoder would (one coupled stream).
static int encode_left_tone(OpusMSEncoder *encoder, int frame_index,
                            uint8_t *packet, int capacity) {
    float pcm[FRAME * 2];
    for (int index = 0; index < FRAME; ++index) {
        const double t = (double)(frame_index * FRAME + index) / 48000.0;
        pcm[index * 2] = (float)(0.5 * sin(2 * M_PI * 1000 * t));
        pcm[index * 2 + 1] = 0;
    }
    return opus_multistream_encode_float(encoder, pcm, FRAME, packet, capacity);
}

static void test_decoder_validation(void) {
    char error[128];
    const uint8_t bad_map[2] = {0, 2};
    CHECK(plank_audio_decoder_create(44100, 2, 1, 1, stereo_map, 2, error, sizeof error) == NULL);
    CHECK(plank_audio_decoder_create(48000, 6, 4, 2, stereo_map, 2, error, sizeof error) == NULL);
    CHECK(plank_audio_decoder_create(48000, 2, 0, 0, stereo_map, 2, error, sizeof error) == NULL);
    CHECK(plank_audio_decoder_create(48000, 2, 1, 2, stereo_map, 2, error, sizeof error) == NULL);
    CHECK(plank_audio_decoder_create(48000, 2, 1, 1, bad_map, 2, error, sizeof error) == NULL);
    CHECK(strstr(error, "channel map") != NULL);
    CHECK(plank_audio_decoder_create(48000, 2, 1, 1, stereo_map, 1, error, sizeof error) == NULL);
    CHECK(plank_audio_decoder_create(48000, 2, 1, 1, NULL, 2, error, sizeof error) == NULL);
}

static void test_decoder_channels_and_concealment(const uint8_t *mapping, int loud_channel) {
    char error[128] = {0};
    PlankVisionAudioDecoder *decoder = plank_audio_decoder_create(
        48000, 2, 1, 1, mapping, 2, error, sizeof error);
    CHECK(decoder != NULL);
    if (decoder == NULL) {
        fprintf(stderr, "decoder: %s\n", error);
        return;
    }
    int result = 0;
    OpusMSEncoder *encoder = opus_multistream_encoder_create(
        48000, 2, 1, 1, stereo_map, OPUS_APPLICATION_RESTRICTED_LOWDELAY, &result);
    CHECK(encoder != NULL && result == OPUS_OK);
    opus_multistream_encoder_ctl(encoder, OPUS_SET_BITRATE(256000));

    static float pcm[PLANK_VISION_AUDIO_MAX_FRAME_SAMPLES * 2];
    uint8_t packet[1500];
    double loud = 0, quiet = 0;
    for (int frame = 0; frame < 40; ++frame) {
        const int size = encode_left_tone(encoder, frame, packet, sizeof packet);
        CHECK(size > 0);
        const int32_t decoded = plank_audio_decoder_decode(
            decoder, packet, (size_t)size, FRAME, pcm, PLANK_VISION_AUDIO_MAX_FRAME_SAMPLES);
        CHECK(decoded == FRAME);
        if (frame >= 10 && decoded == FRAME) {  // past the codec's start-up delay
            loud += energy(pcm, FRAME, loud_channel);
            quiet += energy(pcm, FRAME, 1 - loud_channel);
        }
    }
    // The tone stays on its mapped channel: stereo is not swapped or mixed.
    CHECK(loud > 1.0);
    CHECK(quiet < loud / 100.0);

    // A hole conceals exactly one negotiated frame per call, and the
    // concealed audio continues the tone instead of cutting to silence.
    const int32_t concealed = plank_audio_decoder_decode(
        decoder, NULL, 0, FRAME, pcm, PLANK_VISION_AUDIO_MAX_FRAME_SAMPLES);
    CHECK(concealed == FRAME);
    CHECK(energy(pcm, FRAME, loud_channel) > 0.0);
    CHECK(plank_audio_decoder_decode(decoder, NULL, 0, 0, pcm,
                                     PLANK_VISION_AUDIO_MAX_FRAME_SAMPLES) < 0);
    CHECK(plank_audio_decoder_decode(decoder, NULL, 0, 100, pcm,
                                     PLANK_VISION_AUDIO_MAX_FRAME_SAMPLES) < 0);

    // Malformed input is rejected, and decoding recovers afterwards.
    const uint8_t invalid[1] = {0xff};  // code 3 without its frame-count byte
    CHECK(plank_audio_decoder_decode(decoder, invalid, sizeof invalid, FRAME, pcm,
                                     PLANK_VISION_AUDIO_MAX_FRAME_SAMPLES) < 0);
    CHECK(plank_audio_decoder_decode(decoder, packet, 0, FRAME, pcm,
                                     PLANK_VISION_AUDIO_MAX_FRAME_SAMPLES) < 0);
    CHECK(plank_audio_decoder_decode(decoder, packet, 10, FRAME, pcm, 100) < 0);
    const int size = encode_left_tone(encoder, 41, packet, sizeof packet);
    CHECK(plank_audio_decoder_decode(decoder, packet, (size_t)size, FRAME, pcm,
                                     PLANK_VISION_AUDIO_MAX_FRAME_SAMPLES) == FRAME);

    opus_multistream_encoder_destroy(encoder);
    plank_audio_decoder_destroy(decoder);
}

static void test_concealment_frames(void) {
    CHECK(plank_audio_concealment_frames(480, FRAME, 20) == 2);
    CHECK(plank_audio_concealment_frames(241, FRAME, 20) == 2);
    CHECK(plank_audio_concealment_frames(1, FRAME, 20) == 1);
    CHECK(plank_audio_concealment_frames(0, FRAME, 20) == 0);
    // A hole before the codec header has no frame size: nothing to conceal.
    CHECK(plank_audio_concealment_frames(480, 0, 20) == 0);
    CHECK(plank_audio_concealment_frames(480, 100, 20) == 0);
    CHECK(plank_audio_concealment_frames(1000000, FRAME, 20) == 20);
    CHECK(plank_audio_concealment_frames(UINT32_MAX, 5760, UINT32_MAX) == 745655);
}

// Writes frames whose left sample is its sequence number and right its negation.
static uint32_t write_sequence(PlankAudioRing *ring, uint32_t first, uint32_t count) {
    static float buffer[32768 * 2];
    for (uint32_t index = 0; index < count; ++index) {
        buffer[index * 2] = (float)(first + index);
        buffer[index * 2 + 1] = -(float)(first + index);
    }
    return plank_audio_ring_write(ring, buffer, count);
}

static PlankAudioRingConfig test_config(void) {
    PlankAudioRingConfig config = plank_audio_ring_default_config();
    return config;
}

static void test_ring_priming_order_and_underrun(void) {
    PlankAudioRingConfig config = test_config();
    PlankAudioRing *ring = plank_audio_ring_create(&config);
    CHECK(ring != NULL);
    float left[2048], right[2048];

    // Below the 30 ms target nothing plays.
    CHECK(write_sequence(ring, 1, 1000) == 1000);
    left[0] = 99;
    CHECK(plank_audio_ring_read(ring, left, right, 256) == 0);
    CHECK(left[0] == 0 && left[255] == 0);

    // Above the target, playback starts exactly target frames behind the
    // newest sample and keeps order and channel identity.
    CHECK(write_sequence(ring, 1001, 1000) == 1000);  // 2000 queued, target 1440
    CHECK(plank_audio_ring_read(ring, left, right, 256) == 1);
    CHECK(left[0] == 561.0f && right[0] == -561.0f);
    CHECK(left[255] == 816.0f);
    PlankAudioRingStats stats;
    plank_audio_ring_stats(ring, &stats);
    CHECK(stats.playing == 1);
    CHECK(stats.frames_trimmed == 560);
    CHECK(stats.backlog_frames == 2000 - 560 - 256);

    // Draining past the end is an underrun: silence after the last sample,
    // back to priming, and a 10 ms larger target.
    CHECK(plank_audio_ring_read(ring, left, right, 2048) == 1);
    CHECK(left[1183] == 2000.0f);
    CHECK(left[1184] == 0.0f && right[2047] == 0.0f);
    plank_audio_ring_stats(ring, &stats);
    CHECK(stats.underruns == 1);
    CHECK(stats.playing == 0);
    CHECK(stats.target_frames == 1920);

    // Repeated underruns grow the target only to its maximum.
    for (int round = 0; round < 20; ++round) {
        write_sequence(ring, 0, 4900);
        plank_audio_ring_read(ring, left, right, 2048);
        plank_audio_ring_read(ring, left, right, 2048);
        plank_audio_ring_read(ring, left, right, 2048);
        plank_audio_ring_read(ring, left, right, 2048);
    }
    plank_audio_ring_stats(ring, &stats);
    CHECK(stats.target_frames == config.maximum_target_frames);
    plank_audio_ring_destroy(ring);
}

static void test_ring_flush_discards_stale_audio(void) {
    PlankAudioRingConfig config = test_config();
    PlankAudioRing *ring = plank_audio_ring_create(&config);
    float left[512], right[512];
    write_sequence(ring, 1, 3000);
    CHECK(plank_audio_ring_read(ring, left, right, 512) == 1);

    plank_audio_ring_request_flush(ring);
    // Audio from the new connection or after the interruption; the stale
    // values (< 100000) must never be heard again.
    write_sequence(ring, 100000, 100);
    CHECK(plank_audio_ring_read(ring, left, right, 512) == 0);
    CHECK(left[0] == 0.0f);
    PlankAudioRingStats stats;
    plank_audio_ring_stats(ring, &stats);
    CHECK(stats.flushes == 1);
    CHECK(stats.backlog_frames == 0);
    write_sequence(ring, 100100, 2000);
    CHECK(plank_audio_ring_read(ring, left, right, 512) == 1);
    int stale = 0;
    for (int index = 0; index < 512; ++index) stale |= left[index] < 100000.0f;
    CHECK(!stale);
    plank_audio_ring_destroy(ring);
}

static void test_ring_bounds(void) {
    PlankAudioRingConfig config = test_config();
    PlankAudioRing *ring = plank_audio_ring_create(&config);
    float left[256], right[256];

    // The queue never holds more than its capacity.
    CHECK(write_sequence(ring, 0, 20000) == 16384);
    PlankAudioRingStats stats;
    plank_audio_ring_stats(ring, &stats);
    CHECK(stats.frames_rejected_full == 20000 - 16384);
    CHECK(stats.backlog_frames == 16384);

    // Starting from that backlog plays only the newest target frames.
    CHECK(plank_audio_ring_read(ring, left, right, 256) == 1);
    CHECK(left[0] == (float)(16384 - 1440));

    // A burst while playing is trimmed back to the target in one step.
    write_sequence(ring, 50000, 4000);
    CHECK(plank_audio_ring_read(ring, left, right, 256) == 1);
    CHECK(left[0] == (float)(50000 + 4000 - 1440));
    plank_audio_ring_stats(ring, &stats);
    CHECK(stats.backlog_frames == 1440 - 256);

    // Invalid configurations are refused.
    PlankAudioRingConfig invalid = config;
    invalid.capacity_frames = 4096;  // smaller than the maximum backlog
    CHECK(plank_audio_ring_create(&invalid) == NULL);
    invalid = config;
    invalid.target_frames = 0;
    CHECK(plank_audio_ring_create(&invalid) == NULL);
    CHECK(plank_audio_ring_create(NULL) == NULL);
    plank_audio_ring_destroy(ring);
}

// Feeds and consumes equal amounts per period while holding the queue away
// from the target: the reader must skip (or repeat) frames to converge.
static void test_ring_drift_correction(void) {
    PlankAudioRingConfig config = test_config();
    PlankAudioRing *ring = plank_audio_ring_create(&config);
    float left[480], right[480];
    PlankAudioRingStats stats;

    write_sequence(ring, 0, 1440);
    plank_audio_ring_read(ring, left, right, 240);
    write_sequence(ring, 0, 240 + 1000);  // ~21 ms above target, below trim
    for (int period = 0; period < 400; ++period) {
        write_sequence(ring, 0, 240);
        plank_audio_ring_read(ring, left, right, 240);
    }
    plank_audio_ring_stats(ring, &stats);
    CHECK(stats.drift_frames_skipped > 0);
    CHECK(stats.drift_frames_repeated == 0);
    CHECK(stats.underruns == 0);
    CHECK(stats.backlog_frames < 1440 + 1000);
    plank_audio_ring_destroy(ring);

    ring = plank_audio_ring_create(&config);
    write_sequence(ring, 0, 1440);
    plank_audio_ring_read(ring, left, right, 480);
    plank_audio_ring_read(ring, left, right, 240);  // 720 left: 10 ms below
    for (int period = 0; period < 400; ++period) {
        write_sequence(ring, 0, 240);
        plank_audio_ring_read(ring, left, right, 240);
    }
    plank_audio_ring_stats(ring, &stats);
    CHECK(stats.drift_frames_repeated > 0);
    CHECK(stats.drift_frames_skipped == 0);
    CHECK(stats.underruns == 0);
    CHECK(stats.backlog_frames > 720);
    plank_audio_ring_destroy(ring);

    // Inside the deadband the rate is left alone.
    ring = plank_audio_ring_create(&config);
    write_sequence(ring, 0, 1440);
    for (int period = 0; period < 400; ++period) {
        write_sequence(ring, 0, 240);
        plank_audio_ring_read(ring, left, right, 240);
    }
    plank_audio_ring_stats(ring, &stats);
    CHECK(stats.drift_frames_skipped == 0 && stats.drift_frames_repeated == 0);
    plank_audio_ring_destroy(ring);
}

int main(void) {
    const uint8_t swapped_map[2] = {1, 0};
    test_decoder_validation();
    test_decoder_channels_and_concealment(stereo_map, 0);
    test_decoder_channels_and_concealment(swapped_map, 1);
    test_concealment_frames();
    test_ring_priming_order_and_underrun();
    test_ring_flush_discards_stale_audio();
    test_ring_bounds();
    test_ring_drift_correction();
    printf("%d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
