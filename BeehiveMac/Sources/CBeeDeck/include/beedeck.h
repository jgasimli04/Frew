/* beedeck.h — the BeeDeck realtime DSP core (C, per the transition blueprint:
 * realtime hazards stay off the Swift runtime; Swift is shell/UI only).
 *
 * Model: two BDDeck sources feed one BDMixer. The audio thread calls
 * bd_mixer_render() from an AVAudioSourceNode render block; every parameter
 * setter below is safe to call from the UI thread (C11 atomics, single writer
 * per field, no locks anywhere near render).
 *
 * Per deck: sample-accurate transport over an in-memory stereo Float32 track,
 * cubic-Hermite varispeed (vinyl-style: pitch and tempo move together;
 * key-lock is a later layer), cue + 8 hot cues, a loop with a micro-crossfade
 * at the wrap, trim, a 5-band full-kill isolator built as a Linkwitz-Riley LR4
 * crossover tree (60/250/2000/8000 Hz — kills are true zeros and the all-open
 * sum is allpass-flat by construction), a one-knob HP/LP filter, and a channel
 * fader. The mixer applies the crossfader curve and sums.
 *
 * Every deck also publishes post-EQ per-band peak envelopes — the live signal
 * source for the AV stage ("the EQ sends the signal to the visuals").
 */
#ifndef BEEDECK_H
#define BEEDECK_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { BD_BANDS = 5, BD_HOT_CUES = 8 };

typedef struct BDDeck BDDeck;
typedef struct BDMixer BDMixer;

/* ---- lifecycle ---- */

BDDeck *bd_deck_new(double sample_rate);
void bd_deck_free(BDDeck *d);

/* Load a track: deinterleaved stereo (mono: pass the same pointer twice).
 * The samples are copied. bpm/beat0_sample define the beatgrid (helix
 * convention: the grid is θ-anchored; beat0 is the first beat's sample). */
void bd_deck_load(BDDeck *d, const float *left, const float *right,
                  int64_t n_samples, double bpm, double beat0_sample);
bool bd_deck_loaded(const BDDeck *d);
int64_t bd_deck_length(const BDDeck *d);
double bd_deck_bpm(const BDDeck *d);

/* ---- transport (UI thread; applied by the render thread sample-accurately) */

void bd_deck_play(BDDeck *d);
void bd_deck_pause(BDDeck *d);
bool bd_deck_is_playing(const BDDeck *d);
double bd_deck_position(const BDDeck *d);      /* fractional sample index */
void bd_deck_seek(BDDeck *d, double sample);
void bd_deck_set_rate(BDDeck *d, double rate); /* 1.0 = native tempo */
double bd_deck_rate(const BDDeck *d);

void bd_deck_set_cue(BDDeck *d, double sample);
double bd_deck_cue(const BDDeck *d);
void bd_deck_set_hot_cue(BDDeck *d, int slot, double sample); /* <0 clears */
double bd_deck_hot_cue(const BDDeck *d, int slot);            /* <0 if empty */

/* Loop region in samples; active loops wrap out→in with a micro-crossfade. */
void bd_deck_set_loop(BDDeck *d, double in_sample, double out_sample, bool active);
bool bd_deck_loop_active(const BDDeck *d);

/* ---- channel strip ---- */

void bd_deck_set_trim_db(BDDeck *d, float db);          /* ±12 dB useful range */
void bd_deck_set_fader(BDDeck *d, float level);         /* 0..1 */
/* Isolator band gain in dB (0 = flat, +6 boost, kill = true zero regardless
 * of gain). Bands: 0 sub(<60) 1 low(60-250) 2 mid(250-2k) 3 himid(2k-8k) 4 hi(>8k). */
void bd_deck_set_eq(BDDeck *d, int band, float gain_db, bool kill);
/* One-knob filter: -1..0 = low-pass sweep down, 0..+1 = high-pass sweep up,
 * 0 = bypass (with a small centre detent handled by the caller). */
void bd_deck_set_filter(BDDeck *d, float knob);

/* Post-EQ per-band peak envelopes (release-smoothed, ~0..1). Safe any thread. */
void bd_deck_band_levels(const BDDeck *d, float out[BD_BANDS]);

/* ---- mixer ---- */

BDMixer *bd_mixer_new(double sample_rate);
void bd_mixer_free(BDMixer *m);
void bd_mixer_attach(BDMixer *m, BDDeck *a, BDDeck *b);
/* x in -1(full A)..+1(full B); curve: 0 = smooth (constant-power),
 * 1 = sharp (scratch), 2 = cut. */
void bd_mixer_set_crossfader(BDMixer *m, float x, int curve);
void bd_mixer_set_master(BDMixer *m, float level); /* 0..1 */
/* Master peak levels since the last call (L, R), for meters. */
void bd_mixer_levels(const BDMixer *m, float out[2]);

/* The render entry point — audio thread only. Writes n frames. */
void bd_mixer_render(BDMixer *m, float *out_left, float *out_right, int32_t n);

#ifdef __cplusplus
}
#endif

#endif /* BEEDECK_H */
