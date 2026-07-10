//! The shared pipeline from snapshots to numbers — used identically by the
//! synthetic bench and the real-data runners, so the two can never drift.
//!
//! Per snapshot: refine speed → fold (lossless AND bounded) → per-rev states
//! → standard indicators → one row of metrics. Per life: feed every indicator
//! (including the format's own bits/sample — the claim) to the same alarm
//! rule and read off lead times against the failure time.

use crate::fold::{encode_snapshot, FoldConfig, Mode, FS_I16};
use crate::indicators::{crest, envelope_line_snr, first_alarm, kurtosis, rms, AlarmRule};
use crate::speed::refine_speed;
use crate::state::{states_from_revs, RevState};

pub const BOUNDED_EPS_FS: f64 = 0.001; // the wireless profile: 0.10% FS error bound

#[derive(Clone, Debug)]
pub struct SnapshotMetrics {
    pub t_h: f64,
    pub f_hz: f64,
    pub drift_hz_per_s: f64,
    /// the ALARM metric: steady-state coded bits per sample, exact stream —
    /// revolutions after the pool warmup only, so per-snapshot cold-start
    /// cost (which tracks load level, not health) stays out of the monitor
    pub bits_ll: f64,
    /// steady-state bits per sample, bounded stream (±0.10% FS)
    pub bits_bd: f64,
    /// the WIRE numbers: whole encoded snapshot (header + warmup included)
    pub bits_ll_stream: f64,
    pub bits_bd_stream: f64,
    /// zstd-19 on the raw i16 stream: bits per sample (the baseline to beat)
    pub bits_zstd: f64,
    pub rms_fs: f64,
    pub kurtosis: f64,
    pub crest: f64,
    pub env_line_snr: f64,
    pub max_err_fs: f64,
    pub rev_states: Vec<RevState>,
}

pub struct ProcessConfig {
    pub f_nominal_hz: f64,
    pub speed_tol_rel: f64,
    /// fault order the informed envelope baseline watches
    pub watch_order: f64,
    /// compute the zstd raw baseline (skippable for speed)
    pub with_zstd: bool,
}

/// One snapshot through the whole instrument stack.
pub fn process_snapshot(t_h: f64, x: &[i16], sr: f64, cfg: &ProcessConfig) -> SnapshotMetrics {
    let xf: Vec<f64> = x.iter().map(|&v| v as f64).collect();
    let sp = refine_speed(&xf, sr, cfg.f_nominal_hz, cfg.speed_tol_rel);

    let ll = encode_snapshot(x, sr, &sp, &FoldConfig { mode: Mode::Lossless, ..Default::default() });
    let bd = encode_snapshot(
        x,
        sr,
        &sp,
        &FoldConfig { mode: Mode::Bounded { eps_fs: BOUNDED_EPS_FS }, ..Default::default() },
    );
    debug_assert_eq!(ll.max_err_fs, 0.0);

    // paranoia in debug builds: the stream must actually decode
    #[cfg(debug_assertions)]
    {
        let (dec, _) = crate::fold::decode_snapshot(&ll.bytes);
        debug_assert_eq!(dec, x, "lossless stream failed to round-trip");
    }

    let bits_zstd = if cfg.with_zstd {
        let mut raw = Vec::with_capacity(x.len() * 2);
        for v in x {
            raw.extend_from_slice(&v.to_le_bytes());
        }
        let z = zstd::encode_all(&raw[..], 19).expect("zstd");
        z.len() as f64 * 8.0 / x.len() as f64
    } else {
        f64::NAN
    };

    // steady-state rate: revolutions after the pool warmup
    let warmup = FoldConfig::default().warmup_revs;
    let steady = |revs: &[crate::fold::RevStats]| -> f64 {
        let tail: Vec<_> = revs.iter().skip(warmup).collect();
        let bits: u64 = tail.iter().map(|r| r.bits).sum();
        let n: u32 = tail.iter().map(|r| r.n_samples).sum();
        if n == 0 {
            f64::NAN
        } else {
            bits as f64 / n as f64
        }
    };

    let xf_fs: Vec<f64> = xf.iter().map(|v| v / FS_I16).collect();
    SnapshotMetrics {
        t_h,
        f_hz: sp.f_hz,
        drift_hz_per_s: sp.drift_hz_per_s,
        bits_ll: steady(&ll.revs),
        bits_bd: steady(&bd.revs),
        bits_ll_stream: ll.bytes.len() as f64 * 8.0 / x.len() as f64,
        bits_bd_stream: bd.bytes.len() as f64 * 8.0 / x.len() as f64,
        bits_zstd,
        rms_fs: rms(&xf_fs),
        kurtosis: kurtosis(&xf),
        crest: crest(&xf),
        env_line_snr: envelope_line_snr(&xf, sr, sp.f_hz, cfg.watch_order),
        max_err_fs: bd.max_err_fs,
        // per-rev states from the BOUNDED stream — the deployed wire profile is
        // what the event detector (event.rs) timestamps against
        rev_states: states_from_revs(&bd.revs, t_h, sr),
    }
}

// ---------------------------------------------------------------------------
// life-level evaluation
// ---------------------------------------------------------------------------

pub struct IndicatorSeries {
    pub name: &'static str,
    /// needs to know the fault order? (the informed baseline is flagged)
    pub informed: bool,
    pub values: Vec<f64>,
}

pub fn indicator_table(series: &[SnapshotMetrics]) -> Vec<IndicatorSeries> {
    fn col(series: &[SnapshotMetrics], f: impl Fn(&SnapshotMetrics) -> f64) -> Vec<f64> {
        series.iter().map(f).collect()
    }
    vec![
        IndicatorSeries { name: "bits/sample (bounded)", informed: false, values: col(series, |m| m.bits_bd) },
        IndicatorSeries { name: "bits/sample (lossless)", informed: false, values: col(series, |m| m.bits_ll) },
        IndicatorSeries { name: "RMS", informed: false, values: col(series, |m| m.rms_fs) },
        IndicatorSeries { name: "kurtosis", informed: false, values: col(series, |m| m.kurtosis) },
        IndicatorSeries { name: "crest factor", informed: false, values: col(series, |m| m.crest) },
        IndicatorSeries { name: "envelope line @ fault order", informed: true, values: col(series, |m| m.env_line_snr) },
    ]
}

pub struct AlarmOutcome {
    pub name: &'static str,
    pub informed: bool,
    pub t_alarm_h: Option<f64>,
    pub lead_h: Option<f64>,
}

/// Same rule for every indicator; leads measured against `t_fail_h`.
pub fn evaluate_alarms(
    series: &[SnapshotMetrics],
    rule: &AlarmRule,
    t_fail_h: Option<f64>,
) -> Vec<AlarmOutcome> {
    let t: Vec<f64> = series.iter().map(|m| m.t_h).collect();
    indicator_table(series)
        .into_iter()
        .map(|ind| {
            let t_alarm = first_alarm(&t, &ind.values, rule);
            AlarmOutcome {
                name: ind.name,
                informed: ind.informed,
                t_alarm_h: t_alarm,
                lead_h: match (t_alarm, t_fail_h) {
                    (Some(a), Some(f)) => Some(f - a),
                    _ => None,
                },
            }
        })
        .collect()
}

/// The odometer readout: mean climb per revolution before and after a split
/// time (the rig's onset when known), from the ported dynamics.
pub fn odometer_bend(states: &[RevState], h: &[f64], split_t_h: f64) -> (f64, f64) {
    let mut pre = (0.0f64, 0usize);
    let mut post = (0.0f64, 0usize);
    for i in 1..states.len() {
        let dh = h[i] - h[i - 1];
        if states[i].t_h < split_t_h {
            pre = (pre.0 + dh, pre.1 + 1);
        } else {
            post = (post.0 + dh, post.1 + 1);
        }
    }
    (
        if pre.1 > 0 { pre.0 / pre.1 as f64 } else { 0.0 },
        if post.1 > 0 { post.0 / post.1 as f64 } else { 0.0 },
    )
}
