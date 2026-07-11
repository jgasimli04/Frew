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
 *
 * Beat FX (BEEDECK_ROADMAP T5): one θ-synced effect slot per deck, inserted on
 * the isolator band buses — the LR4 split doubles as the FX router (the
 * RMX-style 3-band idea: LOW = bands 0-1, MID = band 2, HI = bands 3-4). All
 * timing derives from the beatgrid: the FX cycle is beat_samples × beats
 * (source domain), phase φ is computed from the playhead each frame, so loops,
 * seeks and varispeed keep the effect phase-locked to what is audible. DUCK,
 * ROLL and REVERSE are pure functions of φ over rings (no clock of their own);
 * ECHO adds a feedback delay whose time glides tape-style when the beat
 * fraction or rate moves; DRIVE is a waveshaper. The RELEASE flag is a
 * momentary "echo out": while held the deck mutes and beat-spaced repeats
 * decay; on release the dry returns and the tail rings out to silence.
 */
#ifndef BEEDECK_H
#define BEEDECK_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { BD_BANDS = 5, BD_HOT_CUES = 8 };

/* Beat FX types and band targets (see the header comment). Second wave:
 * SWEEP = θ-synced resonant low-pass (cutoff rides φ, amount = resonance),
 * FLANGER/PHASER = φ-driven LFOs (delay line / 4-stage allpass), SLICER =
 * previous-cycle slice re-sequencer over the capture ring (amount picks the
 * pattern), REVERB = Schroeder (4 comb + 2 allpass, amount = RT60). */
enum { BD_FX_OFF = 0, BD_FX_ECHO, BD_FX_DUCK, BD_FX_ROLL, BD_FX_REVERSE,
       BD_FX_DRIVE, BD_FX_SWEEP, BD_FX_FLANGER, BD_FX_PHASER, BD_FX_SLICER,
       BD_FX_REVERB };
enum { BD_FXT_LOW = 0, BD_FXT_MID, BD_FXT_HI, BD_FXT_ALL };

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

/* ---- beat FX (θ-synced) ---- */

/* The FX beatgrid: beat length in *source* samples (track domain, same unit
 * as bd_deck_position) and the first beat's sample. 0 = no grid; the FX then
 * free-runs on a 0.5 s cycle scaled by the beats parameter. */
void bd_deck_set_grid(BDDeck *d, double beat_samples, double beat0_sample);
/* Select effect + band target and switch it on/off (BD_FX_* / BD_FXT_*).
 * All transitions are declick-smoothed; bypass leaves the dry path untouched. */
void bd_deck_set_fx(BDDeck *d, int type, int target, bool on);
void bd_deck_set_fx_beats(BDDeck *d, double beats);   /* cycle length, 1/16..8 beats */
void bd_deck_set_fx_amount(BDDeck *d, float amount);  /* 0..1: feedback/depth/drive */
/* Momentary "echo out": true while the control is held. Works with any (or
 * no) effect selected — it grabs the deck's full post-EQ signal. */
void bd_deck_set_fx_release(BDDeck *d, bool held);
/* Current FX cycle length in output samples (after rate) — for UI/tests. */
double bd_deck_fx_cycle(const BDDeck *d);

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
