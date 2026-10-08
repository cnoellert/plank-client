#include "PlankAudioRing.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct PlankAudioRing {
    float *samples;           // interleaved stereo
    uint64_t mask;            // capacity - 1
    PlankAudioRingConfig config;

    _Atomic uint64_t write_position;   // advanced by the writer only
    _Atomic uint64_t read_position;    // advanced by the reader only
    atomic_int flush_requested;

    // Reader-only state.
    int playing;
    uint32_t target;
    double smoothed_backlog;
    uint32_t drift_counter;

    // Diagnostics, relaxed.
    _Atomic uint64_t frames_written;
    _Atomic uint64_t frames_rejected_full;
    _Atomic uint64_t frames_played;
    _Atomic uint64_t underruns;
    _Atomic uint64_t frames_trimmed;
    _Atomic uint64_t drift_frames_skipped;
    _Atomic uint64_t drift_frames_repeated;
    _Atomic uint64_t flushes;
    _Atomic uint32_t reported_target;
    _Atomic uint32_t reported_playing;
};

PlankAudioRingConfig plank_audio_ring_default_config(void) {
    const PlankAudioRingConfig config = {
        .capacity_frames = 16384,
        .target_frames = 1440,
        .target_step_frames = 480,
        .maximum_target_frames = 4800,
        .trim_margin_frames = 2880,
        .drift_deadband_frames = 240,
        .drift_period_frames = 1000,
    };
    return config;
}

PlankAudioRing *plank_audio_ring_create(const PlankAudioRingConfig *config) {
    if (config == NULL || config->capacity_frames == 0 ||
            config->capacity_frames > (1u << 24) ||
            config->target_frames == 0 ||
            config->maximum_target_frames < config->target_frames ||
            config->drift_period_frames == 0) {
        return NULL;
    }
    uint64_t capacity = 1;
    while (capacity < config->capacity_frames) capacity <<= 1;
    // The largest backlog the reader keeps must fit with room for a burst.
    if ((uint64_t)config->maximum_target_frames + config->trim_margin_frames >= capacity) {
        return NULL;
    }
    PlankAudioRing *ring = calloc(1, sizeof(*ring));
    if (ring == NULL) return NULL;
    ring->samples = calloc((size_t)capacity * 2, sizeof(float));
    if (ring->samples == NULL) {
        free(ring);
        return NULL;
    }
    ring->mask = capacity - 1;
    ring->config = *config;
    ring->config.capacity_frames = (uint32_t)capacity;
    ring->target = config->target_frames;
    atomic_store(&ring->reported_target, ring->target);
    return ring;
}

void plank_audio_ring_destroy(PlankAudioRing *ring) {
    if (ring == NULL) return;
    free(ring->samples);
    free(ring);
}

uint32_t plank_audio_ring_write(
    PlankAudioRing *ring, const float *interleaved, uint32_t frames) {
    if (ring == NULL || interleaved == NULL || frames == 0) return 0;
    const uint64_t write = atomic_load_explicit(&ring->write_position, memory_order_relaxed);
    const uint64_t read = atomic_load_explicit(&ring->read_position, memory_order_acquire);
    const uint64_t space = (uint64_t)ring->config.capacity_frames - (write - read);
    const uint32_t accepted = frames > space ? (uint32_t)space : frames;
    for (uint32_t index = 0; index < accepted; ++index) {
        const uint64_t slot = ((write + index) & ring->mask) * 2;
        ring->samples[slot] = interleaved[index * 2];
        ring->samples[slot + 1] = interleaved[index * 2 + 1];
    }
    atomic_store_explicit(&ring->write_position, write + accepted, memory_order_release);
    atomic_fetch_add_explicit(&ring->frames_written, accepted, memory_order_relaxed);
    if (accepted < frames) {
        atomic_fetch_add_explicit(&ring->frames_rejected_full, frames - accepted,
                                  memory_order_relaxed);
    }
    return accepted;
}

void plank_audio_ring_request_flush(PlankAudioRing *ring) {
    if (ring == NULL) return;
    atomic_store(&ring->flush_requested, 1);
}

static void set_playing(PlankAudioRing *ring, int playing) {
    ring->playing = playing;
    atomic_store_explicit(&ring->reported_playing, (uint32_t)playing, memory_order_relaxed);
}

int plank_audio_ring_read(
    PlankAudioRing *ring, float *left, float *right, uint32_t frames) {
    if (left == NULL || right == NULL || frames == 0) return 0;
    if (ring == NULL) {
        memset(left, 0, frames * sizeof(float));
        memset(right, 0, frames * sizeof(float));
        return 0;
    }
    const uint64_t write = atomic_load_explicit(&ring->write_position, memory_order_acquire);
    uint64_t read = atomic_load_explicit(&ring->read_position, memory_order_relaxed);

    if (atomic_exchange(&ring->flush_requested, 0)) {
        read = write;
        set_playing(ring, 0);
        atomic_fetch_add_explicit(&ring->flushes, 1, memory_order_relaxed);
    }

    uint64_t available = write - read;
    if (!ring->playing) {
        if (available < ring->target) {
            atomic_store_explicit(&ring->read_position, read, memory_order_release);
            memset(left, 0, frames * sizeof(float));
            memset(right, 0, frames * sizeof(float));
            return 0;
        }
        // Start exactly at the target so the first delay is the primed one.
        const uint64_t excess = available - ring->target;
        read += excess;
        available -= excess;
        atomic_fetch_add_explicit(&ring->frames_trimmed, excess, memory_order_relaxed);
        ring->smoothed_backlog = (double)ring->target;
        ring->drift_counter = 0;
        set_playing(ring, 1);
    } else if (available > (uint64_t)ring->target + ring->config.trim_margin_frames) {
        const uint64_t excess = available - ring->target;
        read += excess;
        available -= excess;
        atomic_fetch_add_explicit(&ring->frames_trimmed, excess, memory_order_relaxed);
        ring->smoothed_backlog = (double)ring->target;
    }

    ring->smoothed_backlog += ((double)available - ring->smoothed_backlog) / 16.0;
    const double deadband = (double)ring->config.drift_deadband_frames;
    const int skip = ring->smoothed_backlog > (double)ring->target + deadband;
    const int repeat = ring->smoothed_backlog < (double)ring->target - deadband;

    uint32_t produced = 0;
    uint64_t skipped = 0;
    uint64_t repeated = 0;
    while (produced < frames && read < write) {
        const uint64_t slot = (read & ring->mask) * 2;
        left[produced] = ring->samples[slot];
        right[produced] = ring->samples[slot + 1];
        ++produced;
        ++read;
        if (++ring->drift_counter >= ring->config.drift_period_frames) {
            ring->drift_counter = 0;
            if (skip && read < write) {
                ++read;
                ++skipped;
            } else if (repeat) {
                --read;
                ++repeated;
            }
        }
    }
    const int underrun = produced < frames;
    if (underrun) {
        memset(left + produced, 0, (frames - produced) * sizeof(float));
        memset(right + produced, 0, (frames - produced) * sizeof(float));
        set_playing(ring, 0);
        atomic_fetch_add_explicit(&ring->underruns, 1, memory_order_relaxed);
        // Network jitter outran the queue: hold a little more from now on.
        const uint32_t grown = ring->target + ring->config.target_step_frames;
        ring->target = grown > ring->config.maximum_target_frames ?
            ring->config.maximum_target_frames : grown;
        atomic_store_explicit(&ring->reported_target, ring->target, memory_order_relaxed);
    }
    atomic_store_explicit(&ring->read_position, read, memory_order_release);
    atomic_fetch_add_explicit(&ring->frames_played, produced, memory_order_relaxed);
    if (skipped) {
        atomic_fetch_add_explicit(&ring->drift_frames_skipped, skipped, memory_order_relaxed);
    }
    if (repeated) {
        atomic_fetch_add_explicit(&ring->drift_frames_repeated, repeated, memory_order_relaxed);
    }
    return produced > 0;
}

void plank_audio_ring_stats(const PlankAudioRing *ring, PlankAudioRingStats *stats) {
    if (stats == NULL) return;
    memset(stats, 0, sizeof(*stats));
    if (ring == NULL) return;
    PlankAudioRing *mutable_ring = (PlankAudioRing *)ring;
    const uint64_t write = atomic_load(&mutable_ring->write_position);
    const uint64_t read = atomic_load(&mutable_ring->read_position);
    stats->frames_written = atomic_load(&mutable_ring->frames_written);
    stats->frames_rejected_full = atomic_load(&mutable_ring->frames_rejected_full);
    stats->frames_played = atomic_load(&mutable_ring->frames_played);
    stats->underruns = atomic_load(&mutable_ring->underruns);
    stats->frames_trimmed = atomic_load(&mutable_ring->frames_trimmed);
    stats->drift_frames_skipped = atomic_load(&mutable_ring->drift_frames_skipped);
    stats->drift_frames_repeated = atomic_load(&mutable_ring->drift_frames_repeated);
    stats->flushes = atomic_load(&mutable_ring->flushes);
    stats->backlog_frames = write >= read ? (uint32_t)(write - read) : 0;
    stats->target_frames = atomic_load(&mutable_ring->reported_target);
    stats->playing = atomic_load(&mutable_ring->reported_playing);
}
