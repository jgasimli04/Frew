/* beemeasure.h — realtime-safe plumbing for the measurement harness.
 *
 * This is TEST INFRASTRUCTURE, deliberately kept out of CBeeDeck (the shipping
 * DSP core). Two objects, both obeying the same rule as the deck core: nothing
 * on the audio thread allocates, locks, or makes a syscall.
 *
 *   BMPlayer — plays a preallocated stimulus table (impulse / chirp / sweep)
 *              out of the AVAudioSourceNode render block. Render only copies
 *              floats and advances an atomic cursor.
 *   BMRing   — lock-free SPSC float ring. Producer is the AVAudioSinkNode
 *              capture callback (audio thread); consumer is the analysis
 *              thread, which drains it. Overruns are counted, never hidden:
 *              a run whose ring overran is discarded, like an xrun.
 *   BMXrun   — detects a discontinuity in the host's mSampleTime, which is the
 *              only xrun signal AVAudioEngine actually exposes.
 *
 * Single producer, single consumer, per object. No other pattern is safe here.
 */
#ifndef BEEMEASURE_H
#define BEEMEASURE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- stimulus player ---------------------------------------------------- */

typedef struct BMPlayer BMPlayer;

/* Copies `frames` samples of mono stimulus into an internal buffer. Call off
 * the audio thread. The same table feeds both output channels. */
BMPlayer *bm_player_new(const float *table, int64_t frames);
void bm_player_free(BMPlayer *p);

/* Render `frames` into two non-interleaved channel pointers, zero-padding once
 * the table is exhausted. Audio-thread safe. Returns frames of real stimulus
 * emitted (0 once done). */
int bm_player_render(BMPlayer *p, float *l, float *r, int frames);

void bm_player_reset(BMPlayer *p);
int64_t bm_player_position(const BMPlayer *p);
bool bm_player_done(const BMPlayer *p);

/* ---- capture ring (SPSC) ------------------------------------------------- */

typedef struct BMRing BMRing;

/* Capacity is rounded up to a power of two. Call off the audio thread. */
BMRing *bm_ring_new(size_t capacity_frames);
void bm_ring_free(BMRing *r);

/* Producer side (audio thread). Returns frames actually written; a short write
 * means the consumer fell behind and is counted as an overrun. */
int bm_ring_write(BMRing *r, const float *src, int frames);

/* Consumer side (analysis thread). Returns frames actually read. */
int bm_ring_read(BMRing *r, float *dst, int frames);

size_t bm_ring_available(const BMRing *r);
uint64_t bm_ring_overruns(const BMRing *r);
void bm_ring_reset(BMRing *r);

/* ---- timestamp marks ------------------------------------------------------
 *
 * Without these, the round trip is only known to ±1 IO buffer: the consumer
 * cannot tell whether the capture callback ran before or after the render
 * callback within the cycle where measurement started, and that ambiguity
 * shows up as a believable standard deviation rather than as an error.
 *
 * So each side stamps the host's mSampleTime at its own start-of-measurement:
 * the render block stamps the cycle in which stimulus frame 0 went out, the
 * capture block stamps the cycle in which ring frame 0 came in. Both are on
 * the same device timeline, so their difference is exact.
 *
 * Arm from the control thread; the audio thread stamps once and disarms. */

/* Opaque: the fields are C11 atomics, which do not import cleanly into Swift. */
typedef struct BMMark BMMark;

BMMark *bm_mark_new(void);
void bm_mark_free(BMMark *m);
void bm_mark_arm(BMMark *m);
/* Audio-thread safe. Stamps and disarms only if currently armed. */
void bm_mark_stamp(BMMark *m, double sample_time);
bool bm_mark_valid(const BMMark *m);
double bm_mark_value(const BMMark *m);

/* Start-of-measurement, performed ON THE AUDIO THREAD so that the reset and
 * the timestamp cannot be separated by an intervening callback.
 *
 * Arming from the control thread and then resetting from the control thread is
 * NOT equivalent: a capture callback could write frames after the reset but
 * before the arm, so ring frame 0 would belong to an earlier cycle than the one
 * stamped — exactly the one-buffer error these marks exist to remove.
 *
 * Call each at the top of its callback; both are no-ops unless armed. */
void bm_emit_begin(BMPlayer *p, BMMark *m, double sample_time);
void bm_capture_begin(BMRing *r, BMMark *m, double sample_time);

/* ---- xrun detection ------------------------------------------------------ */

typedef struct {
    double next_expected;   /* mSampleTime we expect on the next callback */
    uint64_t discontinuities;
    bool primed;
} BMXrun;

void bm_xrun_reset(BMXrun *x);

/* Call once per render/capture callback with the host timestamp's mSampleTime
 * and the frame count. A gap or overlap beyond half a frame counts as one
 * discontinuity — i.e. the stream dropped or repeated audio. Audio-thread safe
 * (plain stores; the struct is owned by one callback). */
void bm_xrun_observe(BMXrun *x, double sample_time, int frames);

#ifdef __cplusplus
}
#endif

#endif /* BEEMEASURE_H */
