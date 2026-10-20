/* beemeasure.c — see beemeasure.h. SPSC ring + stimulus table player.
 *
 * The ring is the classic power-of-two head/tail pair: the producer owns head,
 * the consumer owns tail, and the only cross-thread reads are one acquire load
 * each. No CAS, no locks, no allocation past construction.
 */
#include "include/beemeasure.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

/* ---- stimulus player ---------------------------------------------------- */

struct BMPlayer {
    float *table;
    int64_t frames;
    _Atomic int64_t pos;
};

BMPlayer *bm_player_new(const float *table, int64_t frames) {
    if (frames <= 0) return NULL;
    BMPlayer *p = (BMPlayer *)calloc(1, sizeof(BMPlayer));
    if (!p) return NULL;
    p->table = (float *)malloc((size_t)frames * sizeof(float));
    if (!p->table) { free(p); return NULL; }
    memcpy(p->table, table, (size_t)frames * sizeof(float));
    p->frames = frames;
    atomic_store_explicit(&p->pos, 0, memory_order_relaxed);
    return p;
}

void bm_player_free(BMPlayer *p) {
    if (!p) return;
    free(p->table);
    free(p);
}

int bm_player_render(BMPlayer *p, float *l, float *r, int frames) {
    if (!p || frames <= 0) return 0;
    int64_t pos = atomic_load_explicit(&p->pos, memory_order_relaxed);
    int64_t remain = p->frames - pos;
    int n = 0;
    if (remain > 0) n = (int)(remain < (int64_t)frames ? remain : (int64_t)frames);

    for (int i = 0; i < n; i++) {
        float v = p->table[pos + i];
        l[i] = v;
        r[i] = v;
    }
    /* zero-pad the tail so the device never plays stale buffer contents */
    for (int i = n; i < frames; i++) { l[i] = 0.0f; r[i] = 0.0f; }

    atomic_store_explicit(&p->pos, pos + n, memory_order_relaxed);
    return n;
}

void bm_player_reset(BMPlayer *p) {
    if (p) atomic_store_explicit(&p->pos, 0, memory_order_release);
}

int64_t bm_player_position(const BMPlayer *p) {
    return p ? atomic_load_explicit(&p->pos, memory_order_acquire) : 0;
}

bool bm_player_done(const BMPlayer *p) {
    return p ? bm_player_position(p) >= p->frames : true;
}

/* ---- capture ring -------------------------------------------------------- */

struct BMRing {
    float *buf;
    size_t cap;            /* power of two */
    size_t mask;
    _Atomic size_t head;   /* producer writes */
    _Atomic size_t tail;   /* consumer writes */
    _Atomic uint64_t overruns;
};

static size_t round_pow2(size_t n) {
    size_t p = 1;
    while (p < n) p <<= 1;
    return p;
}

BMRing *bm_ring_new(size_t capacity_frames) {
    if (capacity_frames < 2) capacity_frames = 2;
    BMRing *r = (BMRing *)calloc(1, sizeof(BMRing));
    if (!r) return NULL;
    r->cap = round_pow2(capacity_frames);
    r->mask = r->cap - 1;
    r->buf = (float *)calloc(r->cap, sizeof(float));
    if (!r->buf) { free(r); return NULL; }
    atomic_store_explicit(&r->head, 0, memory_order_relaxed);
    atomic_store_explicit(&r->tail, 0, memory_order_relaxed);
    atomic_store_explicit(&r->overruns, 0, memory_order_relaxed);
    return r;
}

void bm_ring_free(BMRing *r) {
    if (!r) return;
    free(r->buf);
    free(r);
}

int bm_ring_write(BMRing *r, const float *src, int frames) {
    if (!r || frames <= 0) return 0;
    size_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
    size_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);
    size_t free_frames = r->cap - (head - tail) - 1;   /* keep one slot empty */
    size_t n = (size_t)frames < free_frames ? (size_t)frames : free_frames;

    for (size_t i = 0; i < n; i++) r->buf[(head + i) & r->mask] = src[i];
    atomic_store_explicit(&r->head, head + n, memory_order_release);

    if (n < (size_t)frames) {
        atomic_fetch_add_explicit(&r->overruns, (uint64_t)((size_t)frames - n),
                                  memory_order_relaxed);
    }
    return (int)n;
}

int bm_ring_read(BMRing *r, float *dst, int frames) {
    if (!r || frames <= 0) return 0;
    size_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
    size_t head = atomic_load_explicit(&r->head, memory_order_acquire);
    size_t avail = head - tail;
    size_t n = (size_t)frames < avail ? (size_t)frames : avail;

    for (size_t i = 0; i < n; i++) dst[i] = r->buf[(tail + i) & r->mask];
    atomic_store_explicit(&r->tail, tail + n, memory_order_release);
    return (int)n;
}

size_t bm_ring_available(const BMRing *r) {
    if (!r) return 0;
    size_t head = atomic_load_explicit(&r->head, memory_order_acquire);
    size_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);
    return head - tail;
}

uint64_t bm_ring_overruns(const BMRing *r) {
    return r ? atomic_load_explicit(&r->overruns, memory_order_relaxed) : 0;
}

void bm_ring_reset(BMRing *r) {
    if (!r) return;
    atomic_store_explicit(&r->head, 0, memory_order_relaxed);
    atomic_store_explicit(&r->tail, 0, memory_order_relaxed);
    atomic_store_explicit(&r->overruns, 0, memory_order_relaxed);
}

/* ---- timestamp marks ------------------------------------------------------ */

struct BMMark {
    _Atomic double t;
    _Atomic int armed;
    _Atomic int valid;
};

BMMark *bm_mark_new(void) {
    BMMark *m = (BMMark *)calloc(1, sizeof(BMMark));
    if (!m) return NULL;
    atomic_store_explicit(&m->t, 0.0, memory_order_relaxed);
    atomic_store_explicit(&m->armed, 0, memory_order_relaxed);
    atomic_store_explicit(&m->valid, 0, memory_order_relaxed);
    return m;
}

void bm_mark_free(BMMark *m) { free(m); }

void bm_mark_arm(BMMark *m) {
    if (!m) return;
    atomic_store_explicit(&m->valid, 0, memory_order_relaxed);
    atomic_store_explicit(&m->armed, 1, memory_order_release);
}

void bm_mark_stamp(BMMark *m, double sample_time) {
    if (!m) return;
    int expected = 1;
    /* exchange, so the stamp happens exactly once per arming */
    if (atomic_compare_exchange_strong_explicit(&m->armed, &expected, 0,
                                                memory_order_acq_rel,
                                                memory_order_relaxed)) {
        atomic_store_explicit(&m->t, sample_time, memory_order_relaxed);
        atomic_store_explicit(&m->valid, 1, memory_order_release);
    }
}

bool bm_mark_valid(const BMMark *m) {
    return m ? atomic_load_explicit(&m->valid, memory_order_acquire) != 0 : false;
}

double bm_mark_value(const BMMark *m) {
    return m ? atomic_load_explicit(&m->t, memory_order_relaxed) : 0.0;
}

/* Audio-thread start-of-measurement. The compare-exchange on `armed` is what
 * makes reset-and-stamp indivisible: whichever callback wins the exchange is
 * the one whose cycle the timestamp describes, and it is the same callback that
 * zeroes the cursor. */
void bm_emit_begin(BMPlayer *p, BMMark *m, double sample_time) {
    if (!p || !m) return;
    int expected = 1;
    if (atomic_compare_exchange_strong_explicit(&m->armed, &expected, 0,
                                                memory_order_acq_rel,
                                                memory_order_relaxed)) {
        atomic_store_explicit(&p->pos, 0, memory_order_relaxed);
        atomic_store_explicit(&m->t, sample_time, memory_order_relaxed);
        atomic_store_explicit(&m->valid, 1, memory_order_release);
    }
}

void bm_capture_begin(BMRing *r, BMMark *m, double sample_time) {
    if (!r || !m) return;
    int expected = 1;
    if (atomic_compare_exchange_strong_explicit(&m->armed, &expected, 0,
                                                memory_order_acq_rel,
                                                memory_order_relaxed)) {
        atomic_store_explicit(&r->head, 0, memory_order_relaxed);
        atomic_store_explicit(&r->tail, 0, memory_order_relaxed);
        atomic_store_explicit(&r->overruns, 0, memory_order_relaxed);
        atomic_store_explicit(&m->t, sample_time, memory_order_relaxed);
        atomic_store_explicit(&m->valid, 1, memory_order_release);
    }
}

/* ---- xrun detection ------------------------------------------------------ */

void bm_xrun_reset(BMXrun *x) {
    if (!x) return;
    x->next_expected = 0.0;
    x->discontinuities = 0;
    x->primed = false;
}

void bm_xrun_observe(BMXrun *x, double sample_time, int frames) {
    if (!x) return;
    if (x->primed) {
        double gap = sample_time - x->next_expected;
        if (gap > 0.5 || gap < -0.5) x->discontinuities++;
    }
    x->next_expected = sample_time + (double)frames;
    x->primed = true;
}
