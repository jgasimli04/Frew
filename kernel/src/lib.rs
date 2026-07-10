//! Demo 1 — the loop-clocked, **adaptive-time-step** audio kernel.
//!
//! The thesis (SKILL_updated.md): a song is a 3-D helix that *rotates* at a rate
//! set by tempo and *climbs* at a rate set by how fast the music is changing,
//! `‖F‖`. Static passages cost almost nothing; busy passages carry the detail.
//!
//! This crate makes the "costs almost nothing" claim **checkable**. Instead of
//! emitting one point per analysis frame, the [`Kernel`] walks frames accumulating
//! the climb energy `‖F‖` and emits a **tick only when the accumulated energy
//! since the last tick reaches `ε_h`** — equal-energy ticks: long steps in static
//! passages, short steps where the music moves. This is error-controlled
//! step-size sampling (cf. adaptive Runge–Kutta / equal-arc-length). `ε_h` is the
//! one knob.
//!
//! ## Matching the Python reference (`beehive/encode.py`)
//!
//! The state `s(k) = (A, I)`, the force `F = ds/dk`, and the climb `h = ∫‖F‖` are
//! defined by `beehive/encode.py`, which is the spec. Reproduced here **exactly**:
//!
//! * `A(k)` — loudness in dB from the **un-windowed** frame:
//!   `max(20·log10(rms+ε), floor_db)`, `rms = sqrt(mean(x²)+ε)`, ε = 1e-10.
//! * `I(k)` — spectral centroid in semitones above `f_ref`, `12·log2(centroid/f_ref)`,
//!   on the **Hann-windowed** magnitude spectrum, **energy-gated** (frames below
//!   1% of the track's median frame energy hold the last valid interval; leading
//!   silence is 0).
//! * `F` — `np.gradient` of A and I (central difference interior, one-sided at the
//!   two ends), **each component divided by its own std over the track**
//!   (`w_amp = w_int = 1`), so `‖F‖` is dimensionless. `h = cumsum(‖F‖)`.
//!
//! `np.gradient` (central difference) is used over the prompt's informal
//! `A(k)−A(k−1)`, because acceptance #1 binds to `encode.py` and a backward
//! difference misses `h` by far more than 1e-3.
//!
//! ## Real-time shape, and the two honest phases
//!
//! The I-gate (median frame energy) and the force normalizers (std of dA, dI) are
//! whole-track statistics — there is no single streaming pass that reproduces
//! `encode.py` exactly. So the demo is two phases, matching the roadmap's
//! "Python measures, the engine runs" split:
//!
//! 1. [`calibrate`] — a measurement pass producing `{energy_thresh, s_a, s_i}`.
//! 2. [`Kernel::step`] — the real-time hot path. Given the calibrated constants it
//!    streams frames, reproduces A/I, finalizes the force one frame behind (the
//!    central difference needs the following frame), accumulates `h`, and emits
//!    equal-energy ticks. **Zero heap allocation** (see [`Kernel::step`]).
//!
//! In Demo 2 the WAV driver is swapped for a cpal callback feeding `step` live;
//! the kernel does not change. The calibration constants would then come from a
//! warm-up / rolling estimate (out of scope here — a non-goal).

use rustfft::{num_complex::Complex, Fft, FftPlanner};
use std::f64::consts::PI;
use std::sync::Arc;

/// The numerical floor used throughout `beehive` (mirrors `EPS` in the Python).
pub const EPS: f64 = 1e-10;

/// Fixed analysis + helix parameters for one run.
#[derive(Clone, Copy, Debug)]
pub struct Params {
    pub n_fft: usize,
    pub hop: usize,
    pub sr: u32,
    /// Beats per bar `B` (one bar = one full 2π turn).
    pub b: f64,
    pub bpm: f64,
    pub r0: f64,
    pub f_ref: f64,
    pub floor_db: f64,
    pub energy_floor_ratio: f64,
    /// The one knob: climb energy per tick.
    pub eps_h: f64,
}

impl Params {
    /// Reference defaults (2048 Hann / 512 hop / B=4 / r0=1 / f_ref=440 / floor=-80).
    /// `sr`, `bpm`, `eps_h` must still be set by the caller.
    pub fn reference(sr: u32, bpm: f64, eps_h: f64) -> Self {
        Params {
            n_fft: 2048,
            hop: 512,
            sr,
            b: 4.0,
            bpm,
            r0: 1.0,
            f_ref: 440.0,
            floor_db: -80.0,
            energy_floor_ratio: 1e-2,
            eps_h,
        }
    }

    /// Angular step per frame: `ω·hop/sr` with `ω = 2π·bpm/(60·B)`. A bar is one
    /// 2π turn regardless of hop size (encode.py: `omega_rad_per_frame`).
    pub fn omega_n(&self) -> f64 {
        (2.0 * PI * self.bpm / (60.0 * self.b)) * (self.hop as f64) / (self.sr as f64)
    }

    /// Number of full (un-padded) frames: frame k covers `[k·hop, k·hop+n_fft)`.
    pub fn num_frames(&self, n_samples: usize) -> usize {
        if n_samples < self.n_fft {
            0
        } else {
            (n_samples - self.n_fft) / self.hop + 1
        }
    }
}

/// One adaptive kernel tick — the equal-energy sample that the controller emits.
#[derive(Clone, Copy, Debug)]
pub struct Tick {
    /// Frame index at which the tick fired.
    pub n: usize,
    pub t_seconds: f64,
    pub alpha: f64,
    pub x: f64,
    pub y: f64,
    /// Climb height `h(n)` at the tick.
    pub h: f64,
    /// Instantaneous `‖F(n)‖` at the tick frame.
    pub f_norm: f64,
    /// Frames since the previous tick — the adaptive step length.
    pub step_frames: usize,
}

/// Per-frame finalized state — emitted for *every* frame (a byproduct of `step`),
/// used to verify A/I/‖F‖/h against the Python reference. Not the adaptive output.
#[derive(Clone, Copy, Debug)]
pub struct FrameState {
    pub n: usize,
    pub a: f64,
    pub i: f64,
    pub f_norm: f64,
    pub h: f64,
}

/// Raw per-frame features before the force stage.
#[derive(Clone, Copy, Debug)]
struct RawFeat {
    a: f64,
    centroid: f64,
    energy: f64,
}

/// Whole-track calibration constants — the only thing the streaming kernel needs
/// that cannot be computed causally. Produced by [`calibrate`].
#[derive(Clone, Copy, Debug)]
pub struct Calibration {
    /// 1% of the median positive frame energy — the I energy gate.
    pub energy_thresh: f64,
    /// std of dA over the track (the A-derivative normalizer), or 1.0 if zero.
    pub s_a: f64,
    /// std of dI over the track (the I-derivative normalizer), or 1.0 if zero.
    pub s_i: f64,
    /// Total climb `h(M-1)` — used to choose a sensible default `ε_h`.
    pub h_total: f64,
    /// Mean `‖F‖` per frame — a natural unit for `ε_h`.
    pub mean_fmag: f64,
    pub m: usize,
}

// ----------------------------------------------------------------------------
// Feature extraction (shared by calibrate and Kernel) — zero-alloc per frame.
// ----------------------------------------------------------------------------

/// Computes `A`, the spectral centroid, and the frame energy for one frame.
/// All buffers are preallocated in [`FeatureExtractor::new`]; [`FeatureExtractor::frame`]
/// does no heap allocation (FFT uses caller-owned scratch).
struct FeatureExtractor {
    n_fft: usize,
    f_ref: f64,
    floor_db: f64,
    fft: Arc<dyn Fft<f64>>,
    /// `np.hanning(n_fft)` (symmetric, denominator `n_fft-1`).
    window: Vec<f64>,
    /// `rfftfreq(n_fft, 1/sr)`, length `n_fft/2+1`.
    freqs: Vec<f64>,
    /// FFT working buffer (real input, processed in place).
    buf: Vec<Complex<f64>>,
    /// FFT scratch — sized by `get_inplace_scratch_len()`.
    scratch: Vec<Complex<f64>>,
}

impl FeatureExtractor {
    fn new(p: &Params) -> Self {
        let mut planner = FftPlanner::new();
        let fft = planner.plan_fft_forward(p.n_fft);
        let scratch_len = fft.get_inplace_scratch_len();
        // np.hanning(M) = 0.5 - 0.5*cos(2π n/(M-1)); M=1 -> [1.0].
        let denom = if p.n_fft > 1 { (p.n_fft - 1) as f64 } else { 1.0 };
        let window: Vec<f64> = (0..p.n_fft)
            .map(|n| 0.5 - 0.5 * (2.0 * PI * n as f64 / denom).cos())
            .collect();
        let n_bins = p.n_fft / 2 + 1;
        let freqs: Vec<f64> = (0..n_bins)
            .map(|i| i as f64 * p.sr as f64 / p.n_fft as f64)
            .collect();
        FeatureExtractor {
            n_fft: p.n_fft,
            f_ref: p.f_ref,
            floor_db: p.floor_db,
            fft,
            window,
            freqs,
            buf: vec![Complex::new(0.0, 0.0); p.n_fft],
            scratch: vec![Complex::new(0.0, 0.0); scratch_len],
        }
    }

    #[inline]
    fn frame(&mut self, samples: &[f32]) -> RawFeat {
        debug_assert_eq!(samples.len(), self.n_fft);

        // A: loudness in dB from the RAW (un-windowed) frame, computed in f64.
        let mut sumsq = 0.0f64;
        for &s in samples {
            let v = s as f64;
            sumsq += v * v;
        }
        let rms = (sumsq / self.n_fft as f64 + EPS).sqrt();
        let a = (20.0 * (rms + EPS).log10()).max(self.floor_db);

        // Windowed real FFT, in place, with preallocated scratch (no alloc).
        for i in 0..self.n_fft {
            self.buf[i].re = samples[i] as f64 * self.window[i];
            self.buf[i].im = 0.0;
        }
        self.fft.process_with_scratch(&mut self.buf, &mut self.scratch);

        // Magnitude over the non-redundant half (bins 0..=n_fft/2 == numpy rfft).
        // Quantize to f32 to mirror `stft_mag`'s `.astype(np.float32)`, so the
        // energy gate threshold compares exactly against the Python reference.
        let mut total = 0.0f64;
        let mut wsum = 0.0f64;
        for i in 0..self.freqs.len() {
            let m = (self.buf[i].norm() as f32) as f64;
            total += m;
            wsum += m * self.freqs[i];
        }
        let centroid = if total > 0.0 { wsum / total } else { self.f_ref };
        RawFeat {
            a,
            centroid,
            energy: total,
        }
    }

    /// Test/diagnostic helper: fill `out` with the windowed magnitude spectrum
    /// (f64, not f32-quantized) of one frame, for cross-checking the FFT.
    fn spectrum_into(&mut self, samples: &[f32], out: &mut [f64]) {
        for i in 0..self.n_fft {
            self.buf[i].re = samples[i] as f64 * self.window[i];
            self.buf[i].im = 0.0;
        }
        self.fft.process_with_scratch(&mut self.buf, &mut self.scratch);
        for i in 0..self.freqs.len() {
            out[i] = self.buf[i].norm();
        }
    }
}

// ----------------------------------------------------------------------------
// Calibration pass (measurement) — allowed to allocate; not the hot path.
// ----------------------------------------------------------------------------

/// numpy-style population std: `sqrt(mean((x-mean)^2))`.
fn std_pop(x: &[f64]) -> f64 {
    let n = x.len() as f64;
    if n == 0.0 {
        return 0.0;
    }
    let mean = x.iter().sum::<f64>() / n;
    let var = x.iter().map(|&v| (v - mean) * (v - mean)).sum::<f64>() / n;
    var.sqrt()
}

/// numpy.gradient with unit spacing and `edge_order=1`:
/// interior `(f[k+1]-f[k-1])/2`, ends one-sided.
fn gradient(f: &[f64]) -> Vec<f64> {
    let n = f.len();
    let mut g = vec![0.0; n];
    if n == 1 {
        return g; // numpy raises; here the kernel never hits n==1.
    }
    g[0] = f[1] - f[0];
    g[n - 1] = f[n - 1] - f[n - 2];
    for k in 1..n - 1 {
        g[k] = (f[k + 1] - f[k - 1]) / 2.0;
    }
    g
}

/// numpy.median (linear interpolation for even length) over the *positive* values.
fn median_positive(x: &[f64]) -> f64 {
    let mut v: Vec<f64> = x.iter().copied().filter(|&e| e > 0.0).collect();
    if v.is_empty() {
        return 0.0;
    }
    v.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let n = v.len();
    if n % 2 == 1 {
        v[n / 2]
    } else {
        0.5 * (v[n / 2 - 1] + v[n / 2])
    }
}

/// Phase 1: the measurement pass. Streams every frame once to gather the global
/// statistics the streaming kernel cannot compute causally.
pub fn calibrate(samples: &[f32], p: &Params) -> Calibration {
    let mut fe = FeatureExtractor::new(p);
    let m = p.num_frames(samples.len());

    let mut a = Vec::with_capacity(m);
    let mut centroid = Vec::with_capacity(m);
    let mut energy = Vec::with_capacity(m);
    for k in 0..m {
        let start = k * p.hop;
        let f = fe.frame(&samples[start..start + p.n_fft]);
        a.push(f.a);
        centroid.push(f.centroid);
        energy.push(f.energy);
    }

    let energy_thresh = p.energy_floor_ratio * median_positive(&energy);

    // I with the energy gate + causal hold-last (forward-fill in encode.py).
    let mut i = vec![0.0; m];
    let mut last_valid: Option<f64> = None;
    for k in 0..m {
        if energy[k] > energy_thresh {
            let inter = 12.0 * (centroid[k].max(EPS) / p.f_ref).log2();
            i[k] = inter;
            last_valid = Some(inter);
        } else {
            i[k] = last_valid.unwrap_or(0.0);
        }
    }

    let da = gradient(&a);
    let di = gradient(&i);
    // `sA = dA.std() or 1.0`: numpy treats std==0.0 as falsy.
    let s_a = {
        let s = std_pop(&da);
        if s == 0.0 {
            1.0
        } else {
            s
        }
    };
    let s_i = {
        let s = std_pop(&di);
        if s == 0.0 {
            1.0
        } else {
            s
        }
    };

    let mut h_total = 0.0;
    for k in 0..m {
        let fa = da[k] / s_a;
        let fi = di[k] / s_i;
        h_total += (fa * fa + fi * fi).sqrt();
    }
    let mean_fmag = if m > 0 { h_total / m as f64 } else { 0.0 };

    Calibration {
        energy_thresh,
        s_a,
        s_i,
        h_total,
        mean_fmag,
        m,
    }
}

// ----------------------------------------------------------------------------
// The Kernel — Phase 2 streaming hot path.
// ----------------------------------------------------------------------------

/// The adaptive-time-step kernel: feed frames with [`Kernel::step`], finish with
/// [`Kernel::flush`]. Holds *all* running state; every buffer is preallocated in
/// [`Kernel::new`].
pub struct Kernel {
    fe: FeatureExtractor,
    // fixed params used in the hot path
    hop: usize,
    sr: f64,
    r0: f64,
    f_ref: f64,
    omega_n: f64,
    eps_h: f64,
    // calibration constants
    thresh: f64,
    s_a: f64,
    s_i: f64,
    // running force state (central difference needs A[k-2], A[k-1] to finalize k-1)
    k: usize,        // next frame index to ingest
    a_prev1: f64,    // A[k-1]
    a_prev2: f64,    // A[k-2]
    i_prev1: f64,    // I[k-1]
    i_prev2: f64,    // I[k-2]
    last_valid_i: Option<f64>,
    // running climb + tick controller
    h: f64,
    acc: f64,        // accumulated ‖F‖ since the last equal-energy tick
    last_tick_n: usize,
    // most recent finalized frame (overwritten each step; no alloc)
    last_finalized: Option<FrameState>,
}

impl Kernel {
    pub fn new(p: &Params, cal: &Calibration) -> Self {
        Kernel {
            fe: FeatureExtractor::new(p),
            hop: p.hop,
            sr: p.sr as f64,
            r0: p.r0,
            f_ref: p.f_ref,
            omega_n: p.omega_n(),
            eps_h: p.eps_h,
            thresh: cal.energy_thresh,
            s_a: cal.s_a,
            s_i: cal.s_i,
            k: 0,
            a_prev1: 0.0,
            a_prev2: 0.0,
            i_prev1: 0.0,
            i_prev2: 0.0,
            last_valid_i: None,
            h: 0.0,
            acc: 0.0,
            last_tick_n: 0,
            last_finalized: None,
        }
    }

    /// Feed one frame of `n_fft` samples. Returns a [`Tick`] if the accumulated
    /// climb energy reached `ε_h` at the frame finalized by this call (or a
    /// boundary anchor at frame 0).
    ///
    /// # Allocation-free
    /// The hot path allocates nothing on the heap. Justification, end to end:
    /// * The FFT plan, Hann window, bin frequencies, the complex FFT buffer and
    ///   its scratch are all built once in [`Kernel::new`].
    /// * The FFT runs via `process_with_scratch` into caller-owned scratch — the
    ///   default `process` *would* allocate, so it is not used.
    /// * Loudness / centroid / gate / gradient / climb are scalar arithmetic over
    ///   preallocated buffers; the last finalized frame is a single `Copy` struct.
    /// * `Tick` / `FrameState` are returned by value (stack). No `Vec` grows.
    /// `tests/alloc.rs` asserts zero allocations across a `step` with a counting
    /// global allocator.
    #[inline]
    pub fn step(&mut self, frame: &[f32]) -> Option<Tick> {
        let feat = self.fe.frame(frame);
        let a_k = feat.a;
        let i_k = if feat.energy > self.thresh {
            let inter = 12.0 * (feat.centroid.max(EPS) / self.f_ref).log2();
            self.last_valid_i = Some(inter);
            inter
        } else {
            self.last_valid_i.unwrap_or(0.0)
        };

        let k = self.k;
        self.last_finalized = None;
        let mut tick = None;

        if k >= 1 {
            // Finalize frame j = k-1. Forward diff at j==0, central diff otherwise.
            let j = k - 1;
            let (da, di) = if j == 0 {
                (a_k - self.a_prev1, i_k - self.i_prev1) // (A[1]-A[0], I[1]-I[0])
            } else {
                (
                    (a_k - self.a_prev2) / 2.0, // (A[k]-A[k-2])/2
                    (i_k - self.i_prev2) / 2.0,
                )
            };
            tick = self.finalize(j, self.a_prev1, self.i_prev1, da, di, j == 0);
        }

        // Shift the 3-frame history forward.
        self.a_prev2 = self.a_prev1;
        self.a_prev1 = a_k;
        self.i_prev2 = self.i_prev1;
        self.i_prev1 = i_k;
        self.k = k + 1;
        tick
    }

    /// Finish the stream: finalize the last frame (one-sided backward difference)
    /// and emit a closing boundary anchor so the reconstruction spans the whole
    /// frame grid. Call once, after the last [`Kernel::step`].
    pub fn flush(&mut self) -> Option<Tick> {
        self.last_finalized = None;
        if self.k == 0 {
            return None; // no frames at all
        }
        let j = self.k - 1; // last ingested frame index
        let (da, di) = if j == 0 {
            // Single-frame stream: numpy.gradient is undefined; treat force as 0.
            (0.0, 0.0)
        } else {
            (self.a_prev1 - self.a_prev2, self.i_prev1 - self.i_prev2) // backward diff
        };
        self.finalize(j, self.a_prev1, self.i_prev1, da, di, true)
    }

    /// Common force → climb → tick step for a finalized frame `j`.
    #[inline]
    fn finalize(&mut self, j: usize, a_j: f64, i_j: f64, da: f64, di: f64, anchor: bool) -> Option<Tick> {
        let fa = da / self.s_a;
        let fi = di / self.s_i;
        let f_norm = (fa * fa + fi * fi).sqrt();
        self.h += f_norm;
        self.last_finalized = Some(FrameState {
            n: j,
            a: a_j,
            i: i_j,
            f_norm,
            h: self.h,
        });

        // Equal-energy controller: fire when ‖F‖ accumulated since the last tick
        // crosses ε_h (carry the remainder). Boundary anchors fire additionally.
        self.acc += f_norm;
        let fire_energy = self.acc >= self.eps_h;
        if fire_energy {
            self.acc -= self.eps_h;
        }
        if anchor || fire_energy {
            let step_frames = j - self.last_tick_n;
            self.last_tick_n = j;
            let alpha = self.omega_n * j as f64;
            Some(Tick {
                n: j,
                t_seconds: j as f64 * self.hop as f64 / self.sr,
                alpha,
                x: self.r0 * alpha.cos(),
                y: self.r0 * alpha.sin(),
                h: self.h,
                f_norm,
                step_frames,
            })
        } else {
            None
        }
    }

    /// The frame finalized by the most recent [`Kernel::step`]/[`Kernel::flush`]
    /// (if any). Read it after each call to collect the per-frame A/I/‖F‖/h arrays.
    #[inline]
    pub fn last_finalized(&self) -> Option<FrameState> {
        self.last_finalized
    }

    /// Current climb height `h`.
    pub fn climb(&self) -> f64 {
        self.h
    }
}

// ----------------------------------------------------------------------------
// Driver helpers (shared by main and the tests).
// ----------------------------------------------------------------------------

/// Decode a WAV to a mono f32 waveform, normalized like libsndfile/soundfile
/// (16-bit → /32768, 24-bit → /2^23, 32-bit int → /2^31, float passthrough);
/// channels are averaged (matches `y.mean(axis=1)`).
pub fn read_wav_mono(path: &str) -> Result<(Vec<f32>, u32), String> {
    let mut reader = hound::WavReader::open(path).map_err(|e| format!("open {path}: {e}"))?;
    let spec = reader.spec();
    let ch = spec.channels as usize;
    let sr = spec.sample_rate;
    let interleaved: Vec<f32> = match (spec.sample_format, spec.bits_per_sample) {
        (hound::SampleFormat::Int, 16) => reader
            .samples::<i16>()
            .map(|s| s.unwrap() as f32 / 32768.0)
            .collect(),
        (hound::SampleFormat::Int, 24) => reader
            .samples::<i32>()
            .map(|s| s.unwrap() as f32 / 8_388_608.0)
            .collect(),
        (hound::SampleFormat::Int, 32) => reader
            .samples::<i32>()
            .map(|s| s.unwrap() as f32 / 2_147_483_648.0)
            .collect(),
        (hound::SampleFormat::Float, 32) => reader.samples::<f32>().map(|s| s.unwrap()).collect(),
        other => return Err(format!("unsupported WAV format {other:?}")),
    };
    if ch <= 1 {
        return Ok((interleaved, sr));
    }
    let n = interleaved.len() / ch;
    let mut mono = Vec::with_capacity(n);
    for i in 0..n {
        let mut s = 0.0f32;
        for c in 0..ch {
            s += interleaved[i * ch + c];
        }
        mono.push(s / ch as f32);
    }
    Ok((mono, sr))
}

/// Output of a full run: the adaptive ticks and the per-frame state (for verification).
pub struct RunOutput {
    pub ticks: Vec<Tick>,
    pub frames: Vec<FrameState>,
}

/// Run the kernel over a whole waveform: feed every frame, then flush.
pub fn run(samples: &[f32], p: &Params, cal: &Calibration) -> RunOutput {
    let m = p.num_frames(samples.len());
    let mut kernel = Kernel::new(p, cal);
    let mut ticks = Vec::new();
    let mut frames = Vec::with_capacity(m);
    for k in 0..m {
        let start = k * p.hop;
        let tick = kernel.step(&samples[start..start + p.n_fft]);
        if let Some(fs) = kernel.last_finalized() {
            frames.push(fs);
        }
        if let Some(t) = tick {
            ticks.push(t);
        }
    }
    let tick = kernel.flush();
    if let Some(fs) = kernel.last_finalized() {
        frames.push(fs);
    }
    if let Some(t) = tick {
        ticks.push(t);
    }
    RunOutput { ticks, frames }
}

/// Reconstruction error of the adaptive helix vs the full fixed-step helix.
#[derive(Clone, Copy, Debug)]
pub struct ReconError {
    /// max |h_true − h_interp| over all frames (climb error).
    pub max_dh: f64,
    /// max Euclidean (x,y) error of the linearly-interpolated tick polyline vs the
    /// true circle (chord error; grows with the angular gap between ticks).
    pub max_xy: f64,
    pub max_step_frames: usize,
    /// Largest angular gap between consecutive ticks, `ω·max_step_frames`.
    pub max_dalpha: f64,
}

/// Interpolate the adaptive ticks back onto the frame grid and measure the worst
/// deviation from the true per-frame helix. Ticks include frame-0 and final-frame
/// anchors, so every frame is bracketed.
pub fn recon_error(out: &RunOutput, p: &Params) -> ReconError {
    let omega_n = p.omega_n();
    let ticks = &out.ticks;
    let mut max_dh = 0.0f64;
    let mut max_xy = 0.0f64;
    if ticks.is_empty() {
        return ReconError {
            max_dh: 0.0,
            max_xy: 0.0,
            max_step_frames: 0,
            max_dalpha: 0.0,
        };
    }
    let mut seg = 0usize; // current tick interval [ticks[seg], ticks[seg+1]]
    for fs in &out.frames {
        let k = fs.n;
        while seg + 1 < ticks.len() && ticks[seg + 1].n <= k {
            seg += 1;
        }
        let (h_rec, x_rec, y_rec) = if seg + 1 < ticks.len() {
            let t0 = &ticks[seg];
            let t1 = &ticks[seg + 1];
            let span = (t1.n - t0.n) as f64;
            let frac = if span > 0.0 {
                (k - t0.n) as f64 / span
            } else {
                0.0
            };
            (
                t0.h + frac * (t1.h - t0.h),
                t0.x + frac * (t1.x - t0.x),
                t0.y + frac * (t1.y - t0.y),
            )
        } else {
            let t = &ticks[seg];
            (t.h, t.x, t.y)
        };
        let alpha = omega_n * k as f64;
        let x_true = p.r0 * alpha.cos();
        let y_true = p.r0 * alpha.sin();
        let dh = (fs.h - h_rec).abs();
        let dxy = ((x_true - x_rec).powi(2) + (y_true - y_rec).powi(2)).sqrt();
        if dh > max_dh {
            max_dh = dh;
        }
        if dxy > max_xy {
            max_xy = dxy;
        }
    }
    let mut max_step_frames = 0usize;
    for t in ticks {
        if t.step_frames > max_step_frames {
            max_step_frames = t.step_frames;
        }
    }
    ReconError {
        max_dh,
        max_xy,
        max_step_frames,
        max_dalpha: omega_n * max_step_frames as f64,
    }
}

// Expose the FFT path for the FFT cross-check test without making the extractor public.
#[doc(hidden)]
pub fn debug_spectrum(p: &Params, frame: &[f32]) -> Vec<f64> {
    let mut fe = FeatureExtractor::new(p);
    let mut out = vec![0.0; p.n_fft / 2 + 1];
    fe.spectrum_into(frame, &mut out);
    out
}
