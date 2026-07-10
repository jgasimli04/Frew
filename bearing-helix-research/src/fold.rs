//! The fold — the cycle-pool storage format. This module IS the claim.
//!
//! A rotating machine's vibration is one short story retold every revolution,
//! plus whatever is new. So the format folds the stream at the shaft period:
//!
//!  * revolutions are segmented at *fractional* sample boundaries from the
//!    refined speed model (samples-per-rev is never an integer);
//!  * a pool — a time-synchronous average on a fixed phase grid — predicts
//!    every sample from the story so far; the pool is updated from
//!    *reconstructed* samples (closed loop), so the decoder mirrors it exactly
//!    and no pool data is ever transmitted;
//!  * the prediction residual is quantised (step q: q=1 is lossless for i16
//!    sources; q>1 gives a hard ±q/2 error bound) and Rice-coded in blocks
//!    that never straddle a revolution, so bytes-per-rev is exact.
//!
//! The monitoring claim rides on the residual: a healthy machine's residual is
//! the sensor noise floor, so the byte rate is flat; a growing defect writes
//! non-repeating impulses into the residual and the byte rate climbs — the
//! format's own accounting is the health indicator. The helix state (A, I) is
//! computed per revolution right here, where the revolutions already exist.

use crate::speed::SpeedEstimate;

pub const FS_I16: f64 = 32768.0;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Mode {
    /// q = 1: bit-exact reconstruction of the i16 stream.
    Lossless,
    /// max abs reconstruction error ≤ eps_fs (fraction of full scale).
    Bounded { eps_fs: f64 },
}

impl Mode {
    /// Quantiser step in ADC counts. Uniform quantiser ⇒ error ≤ q/2, so
    /// q = 2·eps·FS gives |err| ≤ eps·FS.
    pub fn q(&self) -> u16 {
        match *self {
            Mode::Lossless => 1,
            Mode::Bounded { eps_fs } => ((2.0 * eps_fs * FS_I16).floor() as u16).max(1),
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct FoldConfig {
    /// pool grid points per revolution; 0 = auto (largest power of two below
    /// samples-per-rev, so every grid bin is hit every revolution)
    pub grid: usize,
    /// revolutions of pure averaging before the pool becomes an EMA
    pub warmup_revs: usize,
    /// steady-state EMA weight = 1 / 2^ema_shift
    pub ema_shift: u8,
    pub mode: Mode,
}

impl Default for FoldConfig {
    fn default() -> Self {
        FoldConfig { grid: 0, warmup_revs: 8, ema_shift: 6, mode: Mode::Lossless }
    }
}

/// Per-revolution accounting — the format's own metering, and the source of
/// the helix state (state.rs).
#[derive(Clone, Copy, Debug)]
pub struct RevStats {
    /// coded payload bits spent on this revolution
    pub bits: u64,
    pub n_samples: u32,
    /// RMS of the source samples, as a fraction of full scale
    pub rms_fs: f64,
    /// zero-crossing rate of the source samples, Hz
    pub zcr_hz: f64,
}

pub struct FoldResult {
    pub bytes: Vec<u8>,
    pub revs: Vec<RevStats>,
    /// max |source − reconstruction| as a fraction of full scale
    pub max_err_fs: f64,
    /// final pool state (for the decoder-mirror test)
    pub pool: Vec<f64>,
}

// ---------------------------------------------------------------------------
// bit i/o
// ---------------------------------------------------------------------------

struct BitWriter {
    buf: Vec<u8>,
    cur: u8,
    used: u8,
}

impl BitWriter {
    fn new() -> Self {
        BitWriter { buf: Vec::new(), cur: 0, used: 0 }
    }
    fn bits_written(&self) -> u64 {
        self.buf.len() as u64 * 8 + self.used as u64
    }
    fn push_bit(&mut self, b: u32) {
        self.cur = (self.cur << 1) | (b as u8 & 1);
        self.used += 1;
        if self.used == 8 {
            self.buf.push(self.cur);
            self.cur = 0;
            self.used = 0;
        }
    }
    fn push_bits(&mut self, v: u64, n: u8) {
        for i in (0..n).rev() {
            self.push_bit(((v >> i) & 1) as u32);
        }
    }
    fn finish(mut self) -> Vec<u8> {
        if self.used > 0 {
            self.cur <<= 8 - self.used;
            self.buf.push(self.cur);
        }
        self.buf
    }
}

struct BitReader<'a> {
    data: &'a [u8],
    pos: usize,
    bit: u8,
}

impl<'a> BitReader<'a> {
    fn new(data: &'a [u8]) -> Self {
        BitReader { data, pos: 0, bit: 0 }
    }
    fn read_bit(&mut self) -> u32 {
        let b = (self.data[self.pos] >> (7 - self.bit)) & 1;
        self.bit += 1;
        if self.bit == 8 {
            self.bit = 0;
            self.pos += 1;
        }
        b as u32
    }
    fn read_bits(&mut self, n: u8) -> u64 {
        let mut v = 0u64;
        for _ in 0..n {
            v = (v << 1) | self.read_bit() as u64;
        }
        v
    }
}

// ---------------------------------------------------------------------------
// Rice coding — blocks of ≤ RICE_BLOCK residuals, k chosen exactly per block
// ---------------------------------------------------------------------------

const RICE_BLOCK: usize = 256;
const RICE_ESC_Q: u64 = 32; // quotient cap; then 18-bit raw zigzag value
const RICE_RAW_BITS: u8 = 18; // |resid| ≤ 65535 ⇒ zigzag < 2^17

fn zigzag(v: i64) -> u64 {
    ((v << 1) ^ (v >> 63)) as u64
}
fn unzigzag(u: u64) -> i64 {
    ((u >> 1) as i64) ^ -((u & 1) as i64)
}

fn rice_cost(us: &[u64], k: u8) -> u64 {
    let mut bits = 5; // k header
    for &u in us {
        let q = u >> k;
        bits += if q >= RICE_ESC_Q { RICE_ESC_Q + RICE_RAW_BITS as u64 } else { q + 1 + k as u64 };
    }
    bits
}

fn rice_write_block(w: &mut BitWriter, vals: &[i64]) {
    let us: Vec<u64> = vals.iter().map(|&v| zigzag(v)).collect();
    let k = (0..=16u8).min_by_key(|&k| rice_cost(&us, k)).unwrap();
    w.push_bits(k as u64, 5);
    for &u in &us {
        let q = u >> k;
        if q >= RICE_ESC_Q {
            for _ in 0..RICE_ESC_Q {
                w.push_bit(1);
            }
            w.push_bits(u, RICE_RAW_BITS);
        } else {
            for _ in 0..q {
                w.push_bit(1);
            }
            w.push_bit(0);
            w.push_bits(u & ((1u64 << k) - 1), k);
        }
    }
}

fn rice_read_block(r: &mut BitReader, n: usize, out: &mut Vec<i64>) {
    let k = r.read_bits(5) as u8;
    for _ in 0..n {
        let mut q = 0u64;
        loop {
            if q == RICE_ESC_Q {
                let u = r.read_bits(RICE_RAW_BITS);
                out.push(unzigzag(u));
                break;
            }
            if r.read_bit() == 0 {
                let low = r.read_bits(k);
                out.push(unzigzag((q << k) | low));
                break;
            }
            q += 1;
        }
    }
}

// ---------------------------------------------------------------------------
// the pool
// ---------------------------------------------------------------------------

struct Pool {
    grid: Vec<f64>,
    acc: Vec<f64>,
    wsum: Vec<f64>,
    revs_done: u64,
    warmup: u64,
    ema: f64,
}

impl Pool {
    fn new(grid: usize, warmup: usize, ema_shift: u8) -> Self {
        Pool {
            grid: vec![0.0; grid],
            acc: vec![0.0; grid],
            wsum: vec![0.0; grid],
            revs_done: 0,
            warmup: warmup as u64,
            ema: 1.0 / (1u64 << ema_shift) as f64,
        }
    }

    /// Circular linear interpolation of the pool at phase frac ∈ [0, 1).
    fn predict(&self, frac: f64) -> f64 {
        let g = frac * self.grid.len() as f64;
        let j0 = g.floor() as usize % self.grid.len();
        let j1 = (j0 + 1) % self.grid.len();
        let w = g - g.floor();
        self.grid[j0] * (1.0 - w) + self.grid[j1] * w
    }

    /// Splat a reconstructed sample onto the accumulation grid.
    fn accumulate(&mut self, frac: f64, recon: f64) {
        let n = self.grid.len();
        let g = frac * n as f64;
        let j0 = g.floor() as usize % n;
        let j1 = (j0 + 1) % n;
        let w = g - g.floor();
        self.acc[j0] += recon * (1.0 - w);
        self.wsum[j0] += 1.0 - w;
        self.acc[j1] += recon * w;
        self.wsum[j1] += w;
    }

    /// Fold the completed revolution into the pool (pure average during
    /// warmup, then EMA) and clear the accumulator. Decoder-mirrored.
    fn finish_rev(&mut self) {
        self.revs_done += 1;
        let eta_avg = 1.0 / self.revs_done as f64;
        let eta = if self.revs_done <= self.warmup { eta_avg } else { eta_avg.max(self.ema) };
        for j in 0..self.grid.len() {
            if self.wsum[j] > 1e-12 {
                let rev_val = self.acc[j] / self.wsum[j];
                self.grid[j] += eta * (rev_val - self.grid[j]);
            }
            self.acc[j] = 0.0;
            self.wsum[j] = 0.0;
        }
    }
}

// ---------------------------------------------------------------------------
// phase model — shared verbatim by encoder and decoder (determinism!)
// ---------------------------------------------------------------------------

/// φ in revolutions at sample i: f0 centred, linear drift across the snapshot.
#[inline]
fn phase_revs(i: usize, sr: f64, n: usize, f0: f64, drift: f64) -> f64 {
    let t = i as f64 / sr;
    let dur = n as f64 / sr;
    f0 * t + 0.5 * drift * t * (t - dur)
}

const MAGIC: u32 = 0x42484631; // "BHF1"
const HEADER_BYTES: usize = 4 + 1 + 1 + 2 + 4 + 4 + 1 + 3 + 8 + 8 + 8 + 4;

fn write_header(out: &mut Vec<u8>, cfg: &FoldConfig, grid: usize, sr: f64, sp: &SpeedEstimate, n: usize) {
    out.extend_from_slice(&MAGIC.to_le_bytes());
    out.push(1u8); // version
    out.push(match cfg.mode {
        Mode::Lossless => 0,
        Mode::Bounded { .. } => 1,
    });
    out.extend_from_slice(&cfg.mode.q().to_le_bytes());
    out.extend_from_slice(&(grid as u32).to_le_bytes());
    out.extend_from_slice(&(cfg.warmup_revs as u32).to_le_bytes());
    out.push(cfg.ema_shift);
    out.extend_from_slice(&[0u8; 3]);
    out.extend_from_slice(&sr.to_le_bytes());
    out.extend_from_slice(&sp.f_hz.to_le_bytes());
    out.extend_from_slice(&sp.drift_hz_per_s.to_le_bytes());
    out.extend_from_slice(&(n as u32).to_le_bytes());
}

struct Header {
    q: u16,
    grid: usize,
    warmup: usize,
    ema_shift: u8,
    sr: f64,
    f0: f64,
    drift: f64,
    n: usize,
}

fn read_header(data: &[u8]) -> Header {
    assert_eq!(u32::from_le_bytes(data[0..4].try_into().unwrap()), MAGIC, "bad magic");
    let q = u16::from_le_bytes(data[6..8].try_into().unwrap());
    let grid = u32::from_le_bytes(data[8..12].try_into().unwrap()) as usize;
    let warmup = u32::from_le_bytes(data[12..16].try_into().unwrap()) as usize;
    let ema_shift = data[16];
    let sr = f64::from_le_bytes(data[20..28].try_into().unwrap());
    let f0 = f64::from_le_bytes(data[28..36].try_into().unwrap());
    let drift = f64::from_le_bytes(data[36..44].try_into().unwrap());
    let n = u32::from_le_bytes(data[44..48].try_into().unwrap()) as usize;
    Header { q, grid, warmup, ema_shift, sr, f0, drift, n }
}

/// Encode one snapshot. Returns the bytes plus the per-rev metering that the
/// monitoring side (life.rs) and the helix state (state.rs) consume.
pub fn encode_snapshot(x: &[i16], sr: f64, sp: &SpeedEstimate, cfg: &FoldConfig) -> FoldResult {
    let n = x.len();
    let spr = sr / sp.f_hz; // samples per revolution (fractional)
    let grid = if cfg.grid == 0 { crate::dsp::prev_pow2(spr as usize).max(8) } else { cfg.grid };
    let q = cfg.mode.q() as i64;

    let mut out = Vec::new();
    write_header(&mut out, cfg, grid, sr, sp, n);

    let mut pool = Pool::new(grid, cfg.warmup_revs, cfg.ema_shift);
    let mut w = BitWriter::new();
    let mut revs: Vec<RevStats> = Vec::new();
    let mut max_err = 0.0f64;

    let mut block: Vec<i64> = Vec::with_capacity(RICE_BLOCK);
    let mut cur_rev: u64 = 0;
    let mut rev_start_bits: u64 = 0;
    let mut rev_first_sample: usize = 0;

    // per-rev source stats
    let (mut sumsq, mut zc, mut prev_sign) = (0.0f64, 0u32, 0i32);

    for i in 0..n {
        let phi = phase_revs(i, sr, n, sp.f_hz, sp.drift_hz_per_s);
        let rev = phi.floor().max(0.0) as u64;
        if rev != cur_rev {
            // flush the coding block at the revolution boundary so bits/rev is exact
            if !block.is_empty() {
                rice_write_block(&mut w, &block);
                block.clear();
            }
            pool.finish_rev();
            let n_rev = (i - rev_first_sample) as u32;
            revs.push(RevStats {
                bits: w.bits_written() - rev_start_bits,
                n_samples: n_rev,
                rms_fs: (sumsq / n_rev.max(1) as f64).sqrt() / FS_I16,
                zcr_hz: 0.5 * zc as f64 * sr / n_rev.max(1) as f64,
            });
            rev_start_bits = w.bits_written();
            rev_first_sample = i;
            sumsq = 0.0;
            zc = 0;
            cur_rev = rev;
        }

        let frac = phi - phi.floor();
        let pred = pool.predict(frac).round();
        let resid = x[i] as i64 - pred as i64;
        let rq = if q == 1 {
            resid
        } else {
            // round-to-nearest quantisation, exact in f64 for this range
            (resid as f64 / q as f64).round() as i64
        };
        block.push(rq);
        if block.len() == RICE_BLOCK {
            rice_write_block(&mut w, &block);
            block.clear();
        }

        let recon = (pred as i64 + rq * q).clamp(i16::MIN as i64, i16::MAX as i64);
        let err = (x[i] as i64 - recon).abs() as f64 / FS_I16;
        if err > max_err {
            max_err = err;
        }
        pool.accumulate(frac, recon as f64);

        let s = x[i] as f64;
        sumsq += s * s;
        let sign = if x[i] >= 0 { 1 } else { -1 };
        if i > rev_first_sample && sign != prev_sign {
            zc += 1;
        }
        prev_sign = sign;
    }
    if !block.is_empty() {
        rice_write_block(&mut w, &block);
    }
    // final (usually partial) revolution
    let n_rev = (n - rev_first_sample) as u32;
    if n_rev > 0 {
        revs.push(RevStats {
            bits: w.bits_written() - rev_start_bits,
            n_samples: n_rev,
            rms_fs: (sumsq / n_rev as f64).sqrt() / FS_I16,
            zcr_hz: 0.5 * zc as f64 * sr / n_rev as f64,
        });
    }

    out.extend_from_slice(&w.finish());
    FoldResult { bytes: out, revs, max_err_fs: max_err, pool: pool.grid }
}

/// Decode a snapshot produced by [`encode_snapshot`]. Returns the samples and
/// the final pool state; the pool must equal the encoder's bit for bit.
///
/// Structure: the pool's grid only changes at revolution boundaries and Rice
/// blocks never straddle one, so the decoder walks rev by rev — read a whole
/// block of residuals (its length is derivable from the phase model alone),
/// then reconstruct those samples against the frozen pool, then fold the rev.
pub fn decode_snapshot(data: &[u8]) -> (Vec<i16>, Vec<f64>) {
    let h = read_header(data);
    let q = h.q as i64;
    let mut pool = Pool::new(h.grid, h.warmup, h.ema_shift);
    let mut r = BitReader::new(&data[HEADER_BYTES..]);
    let mut out: Vec<i16> = Vec::with_capacity(h.n);

    // revolution segment boundaries from the shared phase model
    let mut rev_starts: Vec<usize> = vec![0];
    let mut cur_rev = 0u64;
    for i in 0..h.n {
        let rev = phase_revs(i, h.sr, h.n, h.f0, h.drift).floor().max(0.0) as u64;
        if rev != cur_rev {
            rev_starts.push(i);
            cur_rev = rev;
        }
    }
    rev_starts.push(h.n);

    let mut resids: Vec<i64> = Vec::new();
    for seg in rev_starts.windows(2) {
        let (start, end) = (seg[0], seg[1]);
        if start > 0 {
            pool.finish_rev(); // encoder folds the pool when a new rev BEGINS
        }
        let mut i = start;
        while i < end {
            let take = (end - i).min(RICE_BLOCK);
            resids.clear();
            rice_read_block(&mut r, take, &mut resids);
            for (j, &rq) in resids.iter().enumerate() {
                let idx = i + j;
                let phi = phase_revs(idx, h.sr, h.n, h.f0, h.drift);
                let frac = phi - phi.floor();
                let pred = pool.predict(frac).round();
                let recon = (pred as i64 + rq * q).clamp(i16::MIN as i64, i16::MAX as i64);
                pool.accumulate(frac, recon as f64);
                out.push(recon as i16);
            }
            i += take;
        }
    }
    (out, pool.grid)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::speed::SpeedEstimate;

    fn splitmix(state: &mut u64) -> u64 {
        *state = state.wrapping_add(0x9E3779B97F4A7C15);
        let mut z = *state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
        z ^ (z >> 31)
    }

    /// A quick shaft-like signal: harmonics + noise + a few outliers.
    fn test_signal(n: usize, sr: f64, f: f64, seed: u64) -> Vec<i16> {
        let mut s = seed;
        (0..n)
            .map(|i| {
                let t = i as f64 / sr;
                let mut v = 1200.0 * (2.0 * std::f64::consts::PI * f * t).cos()
                    + 500.0 * (2.0 * std::f64::consts::PI * 2.0 * f * t + 0.7).cos();
                // uniform-ish noise
                v += (splitmix(&mut s) as f64 / u64::MAX as f64 - 0.5) * 400.0;
                if i % 997 == 0 {
                    v += 9000.0; // outliers exercise the Rice escape path
                }
                v.round().clamp(-32768.0, 32767.0) as i16
            })
            .collect()
    }

    #[test]
    fn lossless_roundtrip_is_bit_exact_and_pools_mirror() {
        let sr = 20480.0;
        let sp = SpeedEstimate { f_hz: 33.34721, drift_hz_per_s: 0.011 };
        let x = test_signal(20480, sr, sp.f_hz, 7);
        let cfg = FoldConfig { mode: Mode::Lossless, ..Default::default() };
        let enc = encode_snapshot(&x, sr, &sp, &cfg);
        assert_eq!(enc.max_err_fs, 0.0, "lossless mode must have zero error");
        let (dec, pool) = decode_snapshot(&enc.bytes);
        assert_eq!(dec, x, "lossless roundtrip must be bit-exact");
        assert_eq!(pool, enc.pool, "decoder pool must mirror the encoder exactly");
    }

    #[test]
    fn bounded_mode_respects_its_error_bound() {
        let sr = 12000.0;
        let sp = SpeedEstimate { f_hz: 29.532, drift_hz_per_s: -0.02 };
        let x = test_signal(12000, sr, sp.f_hz, 99);
        let eps = 0.001; // 0.10% full scale
        let cfg = FoldConfig { mode: Mode::Bounded { eps_fs: eps }, ..Default::default() };
        let enc = encode_snapshot(&x, sr, &sp, &cfg);
        let (dec, pool) = decode_snapshot(&enc.bytes);
        assert_eq!(pool, enc.pool);
        let mut worst = 0.0f64;
        for (a, b) in x.iter().zip(&dec) {
            worst = worst.max((*a as f64 - *b as f64).abs() / FS_I16);
        }
        assert!(worst <= eps + 1e-12, "bound violated: {worst} > {eps}");
        assert!((enc.max_err_fs - worst).abs() < 1e-15, "encoder must report the true max error");
        assert!(
            enc.bytes.len() * 8 < x.len() * 16 / 2,
            "bounded mode should beat half of raw on this signal"
        );
    }

    #[test]
    fn rice_blocks_roundtrip_across_the_value_range() {
        let mut w = BitWriter::new();
        let vals: Vec<i64> =
            (-70000i64..70000).step_by(977).chain([0, 1, -1, 65535, -65535]).collect();
        rice_write_block(&mut w, &vals);
        let bytes = w.finish();
        let mut r = BitReader::new(&bytes);
        let mut out = Vec::new();
        rice_read_block(&mut r, vals.len(), &mut out);
        assert_eq!(out, vals);
    }

    #[test]
    fn revolutions_tile_the_snapshot_exactly() {
        let sr = 20480.0;
        let sp = SpeedEstimate { f_hz: 33.3, drift_hz_per_s: 0.0 };
        let x = test_signal(20480, sr, sp.f_hz, 3);
        let enc = encode_snapshot(&x, sr, &sp, &FoldConfig::default());
        let total: u32 = enc.revs.iter().map(|r| r.n_samples).sum();
        assert_eq!(total as usize, x.len(), "rev segments must cover every sample once");
        // samples-per-rev must hover around sr/f (fractional segmentation)
        let spr = sr / sp.f_hz;
        for r in &enc.revs[..enc.revs.len() - 1] {
            assert!((r.n_samples as f64 - spr).abs() <= 1.0, "spr wandered: {}", r.n_samples);
        }
    }
}
