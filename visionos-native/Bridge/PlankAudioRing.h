#ifndef PLANK_AUDIO_RING_H
#define PLANK_AUDIO_RING_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Bounded stereo playback queue between one decode thread (writer) and the
// real-time render callback (reader). The reader owns every timing decision:
// it primes to a target backlog, trims a backlog that grows past the bound,
// and nudges the consumption rate by at most 1000 ppm so the queue (and
// therefore the audio delay behind the presented video) stays constant
// against Host/headset clock drift. No call allocates or locks.
typedef struct PlankAudioRing PlankAudioRing;

typedef struct PlankAudioRingConfig {
    uint32_t capacity_frames;      // rounded up to a power of two
    uint32_t target_frames;        // initial primed backlog
    uint32_t target_step_frames;   // added after each underrun
    uint32_t maximum_target_frames;
    uint32_t trim_margin_frames;   // backlog above target + margin is dropped
    uint32_t drift_deadband_frames;
    uint32_t drift_period_frames;  // one frame skipped/repeated per period
} PlankAudioRingConfig;

typedef struct PlankAudioRingStats {
    uint64_t frames_written;
    uint64_t frames_rejected_full;
    uint64_t frames_played;
    uint64_t underruns;
    uint64_t frames_trimmed;
    uint64_t drift_frames_skipped;
    uint64_t drift_frames_repeated;
    uint64_t flushes;
    uint32_t backlog_frames;
    uint32_t target_frames;
    uint32_t playing;
} PlankAudioRingStats;

// The stereo baseline: 30 ms primed target growing by 10 ms per underrun to
// 100 ms, a 60 ms trim margin, 5 ms deadband and 1000 ppm correction.
PlankAudioRingConfig plank_audio_ring_default_config(void);

PlankAudioRing *plank_audio_ring_create(const PlankAudioRingConfig *config);
void plank_audio_ring_destroy(PlankAudioRing *ring);

// Writer thread. Copies interleaved stereo frames; returns how many fit.
// A full queue rejects the newest frames; the reader trims stale backlog.
uint32_t plank_audio_ring_write(
    PlankAudioRing *ring, const float *interleaved, uint32_t frames);

// Render thread. Always fills both planar outputs (silence when priming or
// after an underrun). Returns 1 when any decoded audio was produced.
int plank_audio_ring_read(
    PlankAudioRing *ring, float *left, float *right, uint32_t frames);

// Any thread. The next read discards everything queued and primes again, so
// audio queued before an interruption, route change or reconnect never plays.
void plank_audio_ring_request_flush(PlankAudioRing *ring);

// Any thread.
void plank_audio_ring_stats(const PlankAudioRing *ring, PlankAudioRingStats *stats);

#ifdef __cplusplus
}
#endif

#endif
