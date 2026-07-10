/* beedeck.c — see beedeck.h for the model. Everything here is written for the
 * audio render thread: no allocation, no locks, no Objective-C/Swift runtime.
 * UI-thread setters communicate through C11 atomics (single writer per field).
 *
 * The isolator is a Linkwitz-Riley LR4 crossover *tree* with phase
 * compensation. Each LR4 split (LP4 + HP4, both = a squared Q=1/√2
 * Butterworth biquad) sums to a 2nd-order allpass exactly — the analog
 * identity  LP4(s)+HP4(s) = (s²−√2ωs+ω²)/(s²+√2ωs+ω²)  survives the bilinear
 * transform, so the digital branches sum allpass-flat too. Branches that skip
 * a downstream split carry a matching allpass so every band arrives with the
 * same phase; the all-open sum is then flat to float roundoff (measured by
 * `beehive-cli --decktest`, findings doc).
 */
#include "include/beedeck.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define BD_MAX_BLOCK 4096
#define BD_XFADE 64            /* declick crossfade, frames (~1.5 ms @44.1k) */
#define BD_SILENCE 1e-7f       /* below this a kill target snaps to true 0  */

/* ---------------------------------------------------------------- biquads */

typedef struct {
    float b0, b1, b2, a1, a2;  /* a0-normalized */
    float z1[2], z2[2];        /* TDF-II state, stereo */
} Biquad;

static void bq_reset(Biquad *q) { memset(q->z1, 0, sizeof q->z1); memset(q->z2, 0, sizeof q->z2); }

static inline float bq_tick(Biquad *q, int ch, float x)
{
    float y = q->b0 * x + q->z1[ch];
    q->z1[ch] = q->b1 * x - q->a1 * y + q->z2[ch];
    q->z2[ch] = q->b2 * x - q->a2 * y;
    return y;
}

enum { BQ_LP, BQ_HP, BQ_AP };

/* RBJ cookbook, Q fixed where the caller says; a0-normalized. */
static void bq_design(Biquad *q, int type, double fc, double sr, double Q)
{
    if (fc > 0.49 * sr) fc = 0.49 * sr;
    double w = 2.0 * M_PI * fc / sr, cw = cos(w), sw = sin(w);
    double alpha = sw / (2.0 * Q);
    double a0 = 1.0 + alpha, b0, b1, b2;
    switch (type) {
    case BQ_LP: b0 = (1.0 - cw) / 2.0; b1 = 1.0 - cw;        b2 = b0; break;
    case BQ_HP: b0 = (1.0 + cw) / 2.0; b1 = -(1.0 + cw);     b2 = b0; break;
    default:    b0 = 1.0 - alpha;      b1 = -2.0 * cw;       b2 = 1.0 + alpha; break;
    }
    q->b0 = (float)(b0 / a0); q->b1 = (float)(b1 / a0); q->b2 = (float)(b2 / a0);
    q->a1 = (float)(-2.0 * cw / a0); q->a2 = (float)((1.0 - alpha) / a0);
}

/* ---------------------------------------------------------------- rings  */

/* Stereo circular buffer for the FX delay/capture lines. Allocated once at
 * deck creation (never on the render thread). */
typedef struct {
    float *b[2];
    int len, w;
} Ring;

static bool ring_init(Ring *r, int len)
{
    r->w = 0; r->len = 0;
    r->b[0] = calloc((size_t)len, sizeof(float));
    r->b[1] = calloc((size_t)len, sizeof(float));
    if (!r->b[0] || !r->b[1]) { free(r->b[0]); free(r->b[1]); r->b[0] = r->b[1] = NULL; return false; }
    r->len = len;
    return true;
}
static void ring_free(Ring *r) { free(r->b[0]); free(r->b[1]); }
static void ring_clear(Ring *r)
{
    if (r->len) { memset(r->b[0], 0, (size_t)r->len * sizeof(float));
                  memset(r->b[1], 0, (size_t)r->len * sizeof(float)); }
    r->w = 0;
}
/* value `back` frames before the write head (fractional, linear interp) */
static inline float ring_tap(const Ring *r, int ch, double back)
{
    double rp = (double)r->w - back;
    while (rp < 0) rp += (double)r->len;
    int i0 = (int)rp, i1 = i0 + 1 >= r->len ? 0 : i0 + 1;
    float t = (float)(rp - (double)i0);
    return r->b[ch][i0] * (1.0f - t) + r->b[ch][i1] * t;
}
static inline float ring_at(const Ring *r, int ch, int idx)
{
    idx %= r->len; if (idx < 0) idx += r->len;
    return r->b[ch][idx];
}
static inline void ring_push(Ring *r, float l, float rr)
{
    r->b[0][r->w] = l; r->b[1][r->w] = rr;
    if (++r->w >= r->len) r->w = 0;
}

/* ------------------------------------------------------------- the deck  */

static const double BD_XOVER[4] = { 60.0, 250.0, 2000.0, 8000.0 };
#define RT2I 0.7071067811865476  /* 1/sqrt(2) */

typedef struct {                 /* one LR4 two-way split */
    Biquad lp[2], hp[2];         /* two cascaded biquads each */
} Split;

struct BDDeck {
    double sr;

    /* track (owned copies) */
    float *chan[2];
    int64_t n;
    double bpm, beat0;
    _Atomic bool loaded;

    /* transport — UI writes, render consumes */
    _Atomic bool playing;
    _Atomic double target_rate;
    _Atomic double pending_seek;
    _Atomic uint32_t seek_seq;
    _Atomic double cue;
    _Atomic double hot[BD_HOT_CUES];
    _Atomic double loop_in, loop_out;
    _Atomic bool loop_on;
    _Atomic double pub_pos;      /* render publishes for the UI/playhead */

    /* channel strip — UI writes linear targets, render smooths */
    _Atomic float t_trim, t_fader, t_band[BD_BANDS];
    _Atomic float t_filter;      /* knob -1..1 */

    /* render-side state */
    uint32_t seen_seek_seq;
    double pos, rate;
    double ghost_pos;            /* declick source after a jump */
    int xfade_left;
    float play_gain;             /* smoothed 0/1 for click-free play/pause */
    float g_trim, g_fader, g_band[BD_BANDS];
    Split split[4];
    /* Phase compensation, one 2nd-order allpass per skipped downstream split,
     * with per-band state (IIR state is per-signal, never shared):
     * band0: AP@250, AP@2k, AP@8k · band1: AP@2k, AP@8k · band2: AP@8k */
    Biquad comp0[3], comp1[2], comp2[1];
    Biquad filt[2];              /* one-knob filter, 2 cascaded for slope */
    float cur_filter;            /* knob value the current coefficients use */
    _Atomic float env[BD_BANDS]; /* published post-EQ band envelopes */
    float env_l[BD_BANDS];
    float scratch[2][BD_MAX_BLOCK];
    float band_buf[BD_BANDS][2][BD_MAX_BLOCK];
    double posb[BD_MAX_BLOCK];   /* per-frame source position (for FX phase) */

    /* ---- beat FX — UI writes ---- */
    _Atomic int fx_type, fx_target;
    _Atomic bool fx_on, fx_rel;
    _Atomic double fx_beats;     /* cycle length in beats */
    _Atomic float fx_amount;     /* 0..1 → feedback / depth / drive */
    _Atomic double beat_src;     /* source samples per beat (0 = no grid) */
    _Atomic double beat0_at;
    _Atomic double pub_cyc;      /* render publishes cycle length (out frames) */

    /* ---- beat FX — render state ---- */
    Ring echo, cap, rel;         /* delay line · cycle capture · release line */
    int cur_type;
    bool fx_was_on;
    float fx_wet_g;              /* smoothed engage gain */
    float fx_wm[BD_BANDS];       /* smoothed band→wet-bus routing mask */
    double echo_D, rel_D;        /* slewed delay times, output frames */
    double last_phi, phi_free;
    int wrap_last_start;         /* cap index where the current cycle began */
    int wrap_prev_start, wrap_prev_len; /* last complete cycle in cap */
    int roll_start, roll_len;    /* latched slice while ROLL is engaged */
    double roll_k;
    int rel_state;               /* 0 idle · 1 held · 2 tail ringing out */
    float rel_in_g, rel_dry_g, rel_wet_g;
    float rel_blockpeak;
};

BDDeck *bd_deck_new(double sample_rate)
{
    BDDeck *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    d->sr = sample_rate;
    atomic_store(&d->target_rate, 1.0);
    atomic_store(&d->t_trim, 1.0f);
    atomic_store(&d->t_fader, 1.0f);
    for (int b = 0; b < BD_BANDS; b++) atomic_store(&d->t_band[b], 1.0f);
    for (int i = 0; i < BD_HOT_CUES; i++) atomic_store(&d->hot[i], -1.0);
    d->rate = 1.0;
    d->g_trim = 1.0f; d->g_fader = 1.0f;
    for (int b = 0; b < BD_BANDS; b++) d->g_band[b] = 1.0f;
    for (int s = 0; s < 4; s++) {
        for (int k = 0; k < 2; k++) {
            bq_design(&d->split[s].lp[k], BQ_LP, BD_XOVER[s], sample_rate, RT2I);
            bq_design(&d->split[s].hp[k], BQ_HP, BD_XOVER[s], sample_rate, RT2I);
        }
    }
    for (int c = 0; c < 3; c++)
        bq_design(&d->comp0[c], BQ_AP, BD_XOVER[c + 1], sample_rate, RT2I);
    for (int c = 0; c < 2; c++)
        bq_design(&d->comp1[c], BQ_AP, BD_XOVER[c + 2], sample_rate, RT2I);
    bq_design(&d->comp2[0], BQ_AP, BD_XOVER[3], sample_rate, RT2I);
    bq_design(&d->filt[0], BQ_LP, 0.49 * sample_rate, sample_rate, RT2I);
    bq_design(&d->filt[1], BQ_LP, 0.49 * sample_rate, sample_rate, RT2I);
    d->cur_filter = 0.0f;
    /* FX rings: 8 s covers a 4-beat cycle down to 30 bpm (×2 for capture);
     * the release line only ever repeats ≤ its 2 s. */
    ring_init(&d->echo, (int)(8.0 * sample_rate));
    ring_init(&d->cap,  (int)(8.0 * sample_rate));
    ring_init(&d->rel,  (int)(2.0 * sample_rate));
    atomic_store(&d->fx_target, BD_FXT_ALL);
    atomic_store(&d->fx_beats, 1.0);
    atomic_store(&d->fx_amount, 0.5f);
    for (int b = 0; b < BD_BANDS; b++) d->fx_wm[b] = 1.0f;
    d->rel_in_g = 1.0f; d->rel_dry_g = 1.0f;
    d->wrap_last_start = -1;
    return d;
}

void bd_deck_free(BDDeck *d)
{
    if (!d) return;
    ring_free(&d->echo); ring_free(&d->cap); ring_free(&d->rel);
    free(d->chan[0]); free(d->chan[1]);
    free(d);
}

void bd_deck_load(BDDeck *d, const float *left, const float *right,
                  int64_t n_samples, double bpm, double beat0_sample)
{
    atomic_store(&d->playing, false);
    atomic_store(&d->loaded, false);
    free(d->chan[0]); free(d->chan[1]);
    d->chan[0] = malloc((size_t)n_samples * sizeof(float));
    d->chan[1] = malloc((size_t)n_samples * sizeof(float));
    if (!d->chan[0] || !d->chan[1]) { free(d->chan[0]); free(d->chan[1]);
        d->chan[0] = d->chan[1] = NULL; d->n = 0; return; }
    memcpy(d->chan[0], left,  (size_t)n_samples * sizeof(float));
    memcpy(d->chan[1], right, (size_t)n_samples * sizeof(float));
    d->n = n_samples;
    d->bpm = bpm; d->beat0 = beat0_sample;
    d->pos = 0; d->ghost_pos = 0; d->xfade_left = 0;
    atomic_store(&d->pub_pos, 0.0);
    atomic_store(&d->cue, 0.0);
    atomic_store(&d->loop_on, false);
    for (int s = 0; s < 4; s++) for (int k = 0; k < 2; k++) {
        bq_reset(&d->split[s].lp[k]); bq_reset(&d->split[s].hp[k]);
    }
    for (int c = 0; c < 3; c++) bq_reset(&d->comp0[c]);
    for (int c = 0; c < 2; c++) bq_reset(&d->comp1[c]);
    bq_reset(&d->comp2[0]);
    bq_reset(&d->filt[0]); bq_reset(&d->filt[1]);
    /* FX render state restarts with the track (render is gated by `loaded`
     * while we touch the rings here) */
    ring_clear(&d->echo); ring_clear(&d->cap); ring_clear(&d->rel);
    d->fx_wet_g = 0; d->fx_was_on = false;
    d->echo_D = 0; d->rel_D = 0;
    d->last_phi = 0; d->phi_free = 0;
    d->wrap_last_start = -1; d->wrap_prev_len = 0;
    d->roll_len = 0; d->roll_k = 0;
    d->rel_state = 0; d->rel_in_g = 1; d->rel_dry_g = 1; d->rel_wet_g = 0;
    atomic_store(&d->beat_src, 0.0);
    atomic_store(&d->beat0_at, 0.0);
    atomic_store(&d->loaded, true);
}

bool bd_deck_loaded(const BDDeck *d) { return atomic_load(&d->loaded); }
int64_t bd_deck_length(const BDDeck *d) { return d->n; }
double bd_deck_bpm(const BDDeck *d) { return d->bpm; }

void bd_deck_play(BDDeck *d)  { atomic_store(&d->playing, true); }
void bd_deck_pause(BDDeck *d) { atomic_store(&d->playing, false); }
bool bd_deck_is_playing(const BDDeck *d) { return atomic_load(&d->playing); }
double bd_deck_position(const BDDeck *d) { return atomic_load(&d->pub_pos); }

void bd_deck_seek(BDDeck *d, double sample)
{
    atomic_store(&d->pending_seek, sample);
    atomic_fetch_add(&d->seek_seq, 1);
}

void bd_deck_set_rate(BDDeck *d, double rate)
{
    if (rate < 0.05) rate = 0.05;
    if (rate > 4.0) rate = 4.0;
    atomic_store(&d->target_rate, rate);
}
double bd_deck_rate(const BDDeck *d) { return atomic_load(&d->target_rate); }

void bd_deck_set_cue(BDDeck *d, double s) { atomic_store(&d->cue, s); }
double bd_deck_cue(const BDDeck *d) { return atomic_load(&d->cue); }
void bd_deck_set_hot_cue(BDDeck *d, int slot, double s)
{ if (slot >= 0 && slot < BD_HOT_CUES) atomic_store(&d->hot[slot], s); }
double bd_deck_hot_cue(const BDDeck *d, int slot)
{ return (slot >= 0 && slot < BD_HOT_CUES) ? atomic_load(&d->hot[slot]) : -1.0; }

void bd_deck_set_loop(BDDeck *d, double in, double out, bool active)
{
    atomic_store(&d->loop_in, in);
    atomic_store(&d->loop_out, out);
    atomic_store(&d->loop_on, active && out > in + 1.0);
}
bool bd_deck_loop_active(const BDDeck *d) { return atomic_load(&d->loop_on); }

void bd_deck_set_trim_db(BDDeck *d, float db)
{ atomic_store(&d->t_trim, powf(10.0f, db / 20.0f)); }
void bd_deck_set_fader(BDDeck *d, float v)
{ atomic_store(&d->t_fader, v < 0 ? 0 : v > 1 ? 1 : v); }

void bd_deck_set_eq(BDDeck *d, int band, float gain_db, bool kill)
{
    if (band < 0 || band >= BD_BANDS) return;
    float g = kill ? 0.0f : powf(10.0f, gain_db / 20.0f);
    atomic_store(&d->t_band[band], g);
}

void bd_deck_set_filter(BDDeck *d, float knob)
{ atomic_store(&d->t_filter, knob < -1 ? -1 : knob > 1 ? 1 : knob); }

void bd_deck_band_levels(const BDDeck *d, float out[BD_BANDS])
{ for (int b = 0; b < BD_BANDS; b++) out[b] = atomic_load(&d->env[b]); }

void bd_deck_set_grid(BDDeck *d, double beat_samples, double beat0_sample)
{
    atomic_store(&d->beat_src, beat_samples > 0 ? beat_samples : 0.0);
    atomic_store(&d->beat0_at, beat0_sample);
}

void bd_deck_set_fx(BDDeck *d, int type, int target, bool on)
{
    if (type < BD_FX_OFF || type > BD_FX_DRIVE) type = BD_FX_OFF;
    if (target < BD_FXT_LOW || target > BD_FXT_ALL) target = BD_FXT_ALL;
    atomic_store(&d->fx_type, type);
    atomic_store(&d->fx_target, target);
    atomic_store(&d->fx_on, on && type != BD_FX_OFF);
}

void bd_deck_set_fx_beats(BDDeck *d, double beats)
{
    if (beats < 1.0 / 16.0) beats = 1.0 / 16.0;
    if (beats > 8.0) beats = 8.0;
    atomic_store(&d->fx_beats, beats);
}

void bd_deck_set_fx_amount(BDDeck *d, float a)
{ atomic_store(&d->fx_amount, a < 0 ? 0 : a > 1 ? 1 : a); }

void bd_deck_set_fx_release(BDDeck *d, bool held)
{ atomic_store(&d->fx_rel, held); }

double bd_deck_fx_cycle(const BDDeck *d) { return atomic_load(&d->pub_cyc); }

/* cubic Hermite (Catmull-Rom) around integer i for fractional t */
static inline float herm(const float *x, int64_t n, double p)
{
    int64_t i = (int64_t)p;
    float t = (float)(p - (double)i);
    float xm1 = (i > 0) ? x[i - 1] : x[0];
    float x0  = x[i];
    float x1  = (i + 1 < n) ? x[i + 1] : x[n - 1];
    float x2  = (i + 2 < n) ? x[i + 2] : x[n - 1];
    float c1 = 0.5f * (x1 - xm1);
    float c2 = xm1 - 2.5f * x0 + 2.0f * x1 - 0.5f * x2;
    float c3 = 0.5f * (x2 - xm1) + 1.5f * (x0 - x1);
    return ((c3 * t + c2) * t + c1) * t + x0;
}

/* one-pole toward target; tc in seconds */
static inline float smooth(float cur, float target, float coef)
{
    float y = target + (cur - target) * coef;
    /* let a kill actually reach -inf: snap when inaudibly close */
    if (target == 0.0f && fabsf(y) < BD_SILENCE) y = 0.0f;
    return y;
}

/* Render one deck into d->scratch (post strip, pre-crossfader).
 * Returns frames written (always n; silence when idle). */
static void deck_render(BDDeck *d, int32_t n)
{
    double sr = d->sr;
    float coef_gain = expf(-1.0f / (0.003f * (float)sr));   /* ~3 ms */
    float coef_play = expf(-1.0f / (0.002f * (float)sr));   /* ~2 ms */
    double rate_coef = exp(-1.0 / (0.020 * sr));            /* ~20 ms */
    float env_decay = expf(-1.0f / (0.180f * (float)sr));   /* ~180 ms release */

    memset(d->scratch[0], 0, (size_t)n * sizeof(float));
    memset(d->scratch[1], 0, (size_t)n * sizeof(float));

    bool loaded = atomic_load(&d->loaded);
    bool playing = loaded && atomic_load(&d->playing);

    /* consume a pending seek (declicked via ghost crossfade) */
    uint32_t seq = atomic_load(&d->seek_seq);
    if (loaded && seq != d->seen_seek_seq) {
        d->seen_seek_seq = seq;
        double tgt = atomic_load(&d->pending_seek);
        if (tgt < 0) tgt = 0;
        if (tgt > (double)(d->n - 1)) tgt = (double)(d->n - 1);
        if (playing && d->play_gain > 0.5f) {
            d->ghost_pos = d->pos;
            d->xfade_left = BD_XFADE;
        }
        d->pos = tgt;
    }

    double target_rate = atomic_load(&d->target_rate);
    float tgt_play = playing ? 1.0f : 0.0f;

    /* strip targets */
    float t_trim = atomic_load(&d->t_trim);
    float t_fader = atomic_load(&d->t_fader);
    float t_band[BD_BANDS];
    for (int b = 0; b < BD_BANDS; b++) t_band[b] = atomic_load(&d->t_band[b]);

    /* one-knob filter: recompute coefficients when the knob moved */
    float knob = atomic_load(&d->t_filter);
    if (fabsf(knob - d->cur_filter) > 1e-4f) {
        d->cur_filter = knob;
        if (knob < -0.02f) {          /* low-pass sweep 20 kHz → 30 Hz */
            double fc = 20000.0 * pow(30.0 / 20000.0, (double)(-knob));
            bq_design(&d->filt[0], BQ_LP, fc, sr, 0.9);
            bq_design(&d->filt[1], BQ_LP, fc, sr, 0.9);
        } else if (knob > 0.02f) {    /* high-pass sweep 20 Hz → 10 kHz */
            double fc = 20.0 * pow(10000.0 / 20.0, (double)knob);
            bq_design(&d->filt[0], BQ_HP, fc, sr, 0.9);
            bq_design(&d->filt[1], BQ_HP, fc, sr, 0.9);
        } else {                      /* bypass: unity biquads */
            memset(&d->filt[0], 0, sizeof(Biquad)); d->filt[0].b0 = 1.0f;
            memset(&d->filt[1], 0, sizeof(Biquad)); d->filt[1].b0 = 1.0f;
        }
    }
    bool filter_on = fabsf(knob) > 0.02f;

    bool loop_on = atomic_load(&d->loop_on);
    double lin = atomic_load(&d->loop_in), lout = atomic_load(&d->loop_out);

    /* ---- transport + interpolation into scratch ---- */
    for (int32_t i = 0; i < n; i++) {
        d->posb[i] = d->pos;               /* FX phase source, per frame */
        d->play_gain = smooth(d->play_gain, tgt_play, coef_play);
        if (loaded && d->play_gain > 0.0f) {
            d->rate = target_rate + (d->rate - target_rate) * rate_coef;
            float l = herm(d->chan[0], d->n, d->pos);
            float r = herm(d->chan[1], d->n, d->pos);
            if (d->xfade_left > 0) {
                float w = (float)d->xfade_left / (float)BD_XFADE;  /* ghost 1→0 */
                float gl = herm(d->chan[0], d->n, d->ghost_pos);
                float gr = herm(d->chan[1], d->n, d->ghost_pos);
                l = l * (1.0f - w) + gl * w;
                r = r * (1.0f - w) + gr * w;
                d->ghost_pos += d->rate;
                if (d->ghost_pos > (double)(d->n - 2)) d->ghost_pos = (double)(d->n - 2);
                d->xfade_left--;
            }
            d->scratch[0][i] = l * d->play_gain;
            d->scratch[1][i] = r * d->play_gain;

            if (tgt_play == 1.0f) {
                d->pos += d->rate;
                if (loop_on && d->pos >= lout && lout > lin) {
                    d->ghost_pos = d->pos;
                    d->xfade_left = BD_XFADE;
                    d->pos = lin + (d->pos - lout);
                }
                if (d->pos >= (double)(d->n - 2)) {      /* end of track */
                    d->pos = (double)(d->n - 2);
                    atomic_store(&d->playing, false);
                    tgt_play = 0.0f;
                }
            }
        }
    }
    atomic_store(&d->pub_pos, d->pos);

    if (!loaded) { for (int b = 0; b < BD_BANDS; b++) {
        d->env_l[b] *= powf(env_decay, (float)n);
        atomic_store(&d->env[b], d->env_l[b]); } return; }

    /* ---- one-knob filter (before the isolator, like a channel filter) ---- */
    if (filter_on) {
        for (int ch = 0; ch < 2; ch++)
            for (int32_t i = 0; i < n; i++)
                d->scratch[ch][i] =
                    bq_tick(&d->filt[1], ch, bq_tick(&d->filt[0], ch, d->scratch[ch][i]));
    }

    /* ---- LR4 crossover tree into band_buf ----
     * split0@60:   LP→band0, HP→rest
     * split1@250:  LP→band1, HP→rest
     * split2@2000: LP→band2, HP→rest
     * split3@8000: LP→band3, HP→band4
     * comp: band0 += AP@250,2k,8k; band1 += AP@2k,8k; band2 += AP@8k
     * (comp biquads run stereo via their own 2-channel state)              */
    for (int ch = 0; ch < 2; ch++) {
        for (int32_t i = 0; i < n; i++) {
            float x = d->scratch[ch][i];
            float lo, rest = x;
            Split *sp;

            sp = &d->split[0];
            lo   = bq_tick(&sp->lp[1], ch, bq_tick(&sp->lp[0], ch, rest));
            rest = bq_tick(&sp->hp[1], ch, bq_tick(&sp->hp[0], ch, rest));
            lo = bq_tick(&d->comp0[0], ch, lo);
            lo = bq_tick(&d->comp0[1], ch, lo);
            lo = bq_tick(&d->comp0[2], ch, lo);
            d->band_buf[0][ch][i] = lo;

            sp = &d->split[1];
            lo   = bq_tick(&sp->lp[1], ch, bq_tick(&sp->lp[0], ch, rest));
            rest = bq_tick(&sp->hp[1], ch, bq_tick(&sp->hp[0], ch, rest));
            lo = bq_tick(&d->comp1[0], ch, lo);
            lo = bq_tick(&d->comp1[1], ch, lo);
            d->band_buf[1][ch][i] = lo;

            sp = &d->split[2];
            lo   = bq_tick(&sp->lp[1], ch, bq_tick(&sp->lp[0], ch, rest));
            rest = bq_tick(&sp->hp[1], ch, bq_tick(&sp->hp[0], ch, rest));
            lo = bq_tick(&d->comp2[0], ch, lo);
            d->band_buf[2][ch][i] = lo;

            sp = &d->split[3];
            lo   = bq_tick(&sp->lp[1], ch, bq_tick(&sp->lp[0], ch, rest));
            rest = bq_tick(&sp->hp[1], ch, bq_tick(&sp->hp[0], ch, rest));
            d->band_buf[3][ch][i] = lo;
            d->band_buf[4][ch][i] = rest;
        }
    }

    /* ---- beat FX prelude (block level) --------------------------------
     * Cycle length: beat_src × beats source samples → /rate output frames.
     * Without a grid the FX free-runs on a 0.5 s pseudo-beat.             */
    int fx_ty = atomic_load(&d->fx_type);
    int fx_tgt = atomic_load(&d->fx_target);
    bool fx_on = atomic_load(&d->fx_on);
    bool rel_held = atomic_load(&d->fx_rel);
    float fx_amt = atomic_load(&d->fx_amount);
    double fx_beats = atomic_load(&d->fx_beats);
    double bsrc = atomic_load(&d->beat_src);
    double b0 = atomic_load(&d->beat0_at);
    double cyc_src = bsrc * fx_beats;
    double rate_now = d->rate > 0.05 ? d->rate : 1.0;
    double cyc_out = bsrc > 0 ? cyc_src / rate_now : 0.5 * sr * fx_beats;
    double cap_max = d->cap.len > 16 ? (double)(d->cap.len / 2 - 4) : 64.0;
    if (cyc_out < 64.0) cyc_out = 64.0;
    if (cyc_out > cap_max) cyc_out = cap_max;
    atomic_store(&d->pub_cyc, cyc_out);

    if (fx_ty != d->cur_type) {          /* type swap: restart wet, keep rings */
        d->cur_type = fx_ty;
        d->fx_wet_g = 0.0f;
        d->roll_len = 0;
        d->echo_D = cyc_out;
    }
    if (d->echo_D <= 0) d->echo_D = cyc_out;
    if (d->rel_D <= 0) d->rel_D = cyc_out;
    /* ROLL engage: latch the last complete cycle, keyed at the current phase
     * so the grab continues seamlessly from what was just playing. */
    if (fx_on && !d->fx_was_on && d->cur_type == BD_FX_ROLL && d->wrap_prev_len > 1) {
        d->roll_start = d->wrap_prev_start;
        d->roll_len = d->wrap_prev_len;
        d->roll_k = d->last_phi * (double)d->roll_len;
    }
    d->fx_was_on = fx_on;

    float fx_fb = 0.25f + 0.60f * fx_amt;          /* echo feedback ≤ .85 */
    float fx_lvl = 0.35f + 0.65f * fx_amt;         /* echo wet level      */
    float drive_g = 1.0f + 24.0f * fx_amt;
    float drive_norm = 1.0f / tanhf(drive_g);
    float drive_mix = fx_amt < 0.83f ? fx_amt * 1.2f : 1.0f;
    float wet_tgt = fx_on ? 1.0f : 0.0f;
    float mtgt[BD_BANDS];                          /* band → wet-bus mask */
    for (int b = 0; b < BD_BANDS; b++) {
        bool in = fx_tgt == BD_FXT_ALL || (fx_tgt == BD_FXT_LOW && b <= 1) ||
                  (fx_tgt == BD_FXT_MID && b == 2) || (fx_tgt == BD_FXT_HI && b >= 3);
        mtgt[b] = in ? 1.0f : 0.0f;
    }
    bool fx_rings = d->echo.len > 0 && d->cap.len > 0 && d->rel.len > 0;
    double coefD = exp(-1.0 / (0.080 * sr));       /* delay-time glide ~80 ms */
    /* release punch-out state machine */
    if (rel_held) { if (d->rel_state != 1) d->rel_state = 1; }
    else if (d->rel_state == 1) d->rel_state = 2;  /* → tail rings out */
    d->rel_blockpeak = 0.0f;
    float rel_fb = 0.62f;

    /* ---- band gains + envelopes → FX buses → sum with trim/fader ---- */
    float g_master_frame;
    for (int32_t i = 0; i < n; i++) {
        d->g_trim = smooth(d->g_trim, t_trim, coef_gain);
        d->g_fader = smooth(d->g_fader, t_fader, coef_gain);
        g_master_frame = d->g_trim * d->g_fader;
        float wl = 0.0f, wr = 0.0f, dl = 0.0f, dr = 0.0f;
        for (int b = 0; b < BD_BANDS; b++) {
            d->g_band[b] = smooth(d->g_band[b], t_band[b], coef_gain);
            float bl = d->band_buf[b][0][i] * d->g_band[b];
            float br = d->band_buf[b][1][i] * d->g_band[b];
            float mag = fabsf(bl) > fabsf(br) ? fabsf(bl) : fabsf(br);
            float e = d->env_l[b] * env_decay;
            d->env_l[b] = mag > e ? mag : e;
            d->fx_wm[b] = smooth(d->fx_wm[b], mtgt[b], coef_gain);
            wl += bl * d->fx_wm[b]; wr += br * d->fx_wm[b];
            dl += bl * (1.0f - d->fx_wm[b]); dr += br * (1.0f - d->fx_wm[b]);
        }

        /* phase φ in the FX cycle, from this frame's source position */
        double phi;
        if (bsrc > 0) {
            double p = (d->posb[i] - b0) / cyc_src;
            phi = p - floor(p);
        } else {
            d->phi_free += 1.0 / cyc_out;
            if (d->phi_free >= 1.0) d->phi_free -= floor(d->phi_free);
            phi = d->phi_free;
        }
        bool wrapped = phi < d->last_phi;
        d->last_phi = phi;

        float owl = wl, owr = wr;
        if (fx_rings) {
            /* cycle capture (always recording; wrap marks delimit cycles) */
            if (wrapped) {
                if (d->wrap_last_start >= 0) {
                    int len = (d->cap.w - d->wrap_last_start + d->cap.len) % d->cap.len;
                    if (len >= 32 && len <= d->cap.len / 2) {
                        d->wrap_prev_start = d->wrap_last_start;
                        d->wrap_prev_len = len;
                    } else d->wrap_prev_len = 0;
                }
                d->wrap_last_start = d->cap.w;
            }
            ring_push(&d->cap, wl, wr);

            d->fx_wet_g = smooth(d->fx_wet_g, wet_tgt, coef_gain);
            float wg = d->fx_wet_g;
            switch (d->cur_type) {
            case BD_FX_ECHO: {
                d->echo_D = cyc_out + (d->echo_D - cyc_out) * coefD;
                float tl = ring_tap(&d->echo, 0, d->echo_D);
                float tr = ring_tap(&d->echo, 1, d->echo_D);
                ring_push(&d->echo, wl + tl * fx_fb * wg, wr + tr * fx_fb * wg);
                owl = wl + tl * fx_lvl * wg;
                owr = wr + tr * fx_lvl * wg;
                break;
            }
            case BD_FX_DUCK: {
                float c = 0.5f + 0.5f * cosf((float)(2.0 * M_PI * phi));
                float g = 1.0f - fx_amt * c * c * wg;
                owl = wl * g; owr = wr * g;
                break;
            }
            case BD_FX_ROLL:
                if (d->roll_len > 1) {
                    int off = (int)d->roll_k % d->roll_len;
                    float rl = ring_at(&d->cap, 0, d->roll_start + off);
                    float rr2 = ring_at(&d->cap, 1, d->roll_start + off);
                    d->roll_k += 1.0;
                    owl = wl * (1.0f - wg) + rl * wg;
                    owr = wr * (1.0f - wg) + rr2 * wg;
                }
                break;
            case BD_FX_REVERSE:
                if (d->wrap_prev_len > 1) {
                    int off = (int)((1.0 - phi) * (double)(d->wrap_prev_len - 1));
                    float rl = ring_at(&d->cap, 0, d->wrap_prev_start + off);
                    float rr2 = ring_at(&d->cap, 1, d->wrap_prev_start + off);
                    owl = wl * (1.0f - wg) + rl * wg;
                    owr = wr * (1.0f - wg) + rr2 * wg;
                }
                break;
            case BD_FX_DRIVE: {
                float m = drive_mix * wg;
                owl = wl * (1.0f - m) + tanhf(drive_g * wl) * drive_norm * m;
                owr = wr * (1.0f - m) + tanhf(drive_g * wr) * drive_norm * m;
                break;
            }
            default:
                break;
            }
            /* keep the echo line recording while unused so an engage (or a
             * type swap back to ECHO) has a first tap ready immediately */
            if (d->cur_type != BD_FX_ECHO)
                ring_push(&d->echo, wl, wr);
        }

        float fl = dl + owl, fr = dr + owr;

        /* release "echo out": beat-spaced repeats of the full deck signal,
         * dry muted while held, tail rings out after release. */
        if (fx_rings) {
            float in_t, wet_t, dry_t, fb;
            switch (d->rel_state) {
            case 1:  in_t = 0; wet_t = 1; dry_t = 0; fb = rel_fb; break;
            case 2:  in_t = 0; wet_t = 1; dry_t = 1; fb = rel_fb; break;
            default: in_t = 1; wet_t = 0; dry_t = 1; fb = 0;      break;
            }
            d->rel_in_g = smooth(d->rel_in_g, in_t, coef_gain);
            d->rel_wet_g = smooth(d->rel_wet_g, wet_t, coef_gain);
            d->rel_dry_g = smooth(d->rel_dry_g, dry_t, coef_gain);
            double relmax = (double)(d->rel.len - 4);
            double rtgt = cyc_out > relmax ? relmax : cyc_out;
            d->rel_D = rtgt + (d->rel_D - rtgt) * coefD;
            float tl = ring_tap(&d->rel, 0, d->rel_D);
            float tr = ring_tap(&d->rel, 1, d->rel_D);
            ring_push(&d->rel, fl * d->rel_in_g + tl * fb, fr * d->rel_in_g + tr * fb);
            float a = fabsf(tl) > fabsf(tr) ? fabsf(tl) : fabsf(tr);
            if (a > d->rel_blockpeak) d->rel_blockpeak = a;
            fl = fl * d->rel_dry_g + tl * d->rel_wet_g;
            fr = fr * d->rel_dry_g + tr * d->rel_wet_g;
        }

        d->scratch[0][i] = fl * g_master_frame;
        d->scratch[1][i] = fr * g_master_frame;
    }
    /* tail fully decayed → release line back to pass-through recording */
    if (d->rel_state == 2 && d->rel_blockpeak < 1e-4f) d->rel_state = 0;
    for (int b = 0; b < BD_BANDS; b++) atomic_store(&d->env[b], d->env_l[b]);
}

/* ------------------------------------------------------------- the mixer */

struct BDMixer {
    double sr;
    BDDeck *deck[2];
    _Atomic float t_x;         /* crossfader -1..1 */
    _Atomic int curve;
    _Atomic float t_master;
    float g_a, g_b, g_master;
    _Atomic float peak[2];
};

BDMixer *bd_mixer_new(double sample_rate)
{
    BDMixer *m = calloc(1, sizeof *m);
    if (!m) return NULL;
    m->sr = sample_rate;
    atomic_store(&m->t_master, 1.0f);
    m->g_a = m->g_b = 1.0f; m->g_master = 1.0f;
    return m;
}

void bd_mixer_free(BDMixer *m) { free(m); }
void bd_mixer_attach(BDMixer *m, BDDeck *a, BDDeck *b) { m->deck[0] = a; m->deck[1] = b; }
void bd_mixer_set_crossfader(BDMixer *m, float x, int curve)
{
    atomic_store(&m->t_x, x < -1 ? -1 : x > 1 ? 1 : x);
    atomic_store(&m->curve, curve);
}
void bd_mixer_set_master(BDMixer *m, float v)
{ atomic_store(&m->t_master, v < 0 ? 0 : v > 1 ? 1 : v); }

void bd_mixer_levels(const BDMixer *m, float out[2])
{ out[0] = atomic_load(&m->peak[0]); out[1] = atomic_load(&m->peak[1]); }

static void xfader_gains(float x, int curve, float *ga, float *gb)
{
    float t = (x + 1.0f) * 0.5f;          /* 0 = full A, 1 = full B */
    switch (curve) {
    case 1: {                             /* sharp: full through the middle */
        float a = (1.0f - t) * 5.0f, b = t * 5.0f;
        *ga = a > 1 ? 1 : a; *gb = b > 1 ? 1 : b;
        break;
    }
    case 2: {                             /* cut: edges only */
        *ga = t < 0.98f ? 1.0f : (1.0f - t) / 0.02f;
        *gb = t > 0.02f ? 1.0f : t / 0.02f;
        break;
    }
    default:                              /* constant power */
        *ga = cosf(t * (float)M_PI_2);
        *gb = sinf(t * (float)M_PI_2);
    }
}

void bd_mixer_render(BDMixer *m, float *out_left, float *out_right, int32_t n)
{
    if (n > BD_MAX_BLOCK) n = BD_MAX_BLOCK;
    memset(out_left, 0, (size_t)n * sizeof(float));
    memset(out_right, 0, (size_t)n * sizeof(float));

    float ta, tb;
    xfader_gains(atomic_load(&m->t_x), atomic_load(&m->curve), &ta, &tb);
    float tm = atomic_load(&m->t_master);
    float coef = expf(-1.0f / (0.003f * (float)m->sr));

    float pk_l = 0.0f, pk_r = 0.0f;
    for (int k = 0; k < 2; k++) {
        BDDeck *d = m->deck[k];
        if (!d) continue;
        deck_render(d, n);
    }
    for (int32_t i = 0; i < n; i++) {
        m->g_a = smooth(m->g_a, ta, coef);
        m->g_b = smooth(m->g_b, tb, coef);
        m->g_master = smooth(m->g_master, tm, coef);
        float l = 0.0f, r = 0.0f;
        if (m->deck[0]) { l += m->deck[0]->scratch[0][i] * m->g_a;
                          r += m->deck[0]->scratch[1][i] * m->g_a; }
        if (m->deck[1]) { l += m->deck[1]->scratch[0][i] * m->g_b;
                          r += m->deck[1]->scratch[1][i] * m->g_b; }
        l *= m->g_master; r *= m->g_master;
        out_left[i] = l; out_right[i] = r;
        if (fabsf(l) > pk_l) pk_l = fabsf(l);
        if (fabsf(r) > pk_r) pk_r = fabsf(r);
    }
    atomic_store(&m->peak[0], pk_l);
    atomic_store(&m->peak[1], pk_r);
}
