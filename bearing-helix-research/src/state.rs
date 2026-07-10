//! The (A, I) mapping — where the machine enters the helix.
//!
//! The audio engine's state is s(n) = (A, I): loudness in dB and interval in
//! semitones (`beehive/encode.py` l.157-159). The bearing analogue, computed
//! per revolution by fold.rs where the revolutions already exist:
//!
//!   A(rev) = 20·log10(rms_fs)            — the revolution's loudness, dB re FS
//!   I(rev) = 12·log2(zcr_hz / 1000 Hz)   — dominant-frequency proxy, in
//!                                          semitones above 1 kHz
//!
//! The zero-crossing rate is a deliberately crude spectral centroid stand-in:
//! it is computable inside the codec loop for free, and it moves hard when
//! impulsive high-frequency content (a defect ringing the resonance) enters
//! the signal. n is the revolution index; one helix turn = TURN_REVS
//! revolutions (geometry.rs, theory/00).

use crate::fold::RevStats;
use crate::geometry::{derive_dynamics, Dynamics, DynamicsMeta};

#[derive(Clone, Copy, Debug)]
pub struct RevState {
    /// absolute machine time of the revolution, hours
    pub t_h: f64,
    pub a_db: f64,
    pub i_semi: f64,
    /// the format's own metering for this revolution, coded bits per sample —
    /// the per-rev series the event detector (event.rs) timestamps against
    pub bits: f64,
}

/// Map one snapshot's per-rev accounting to helix state points.
pub fn states_from_revs(revs: &[RevStats], snapshot_t_h: f64, sr: f64) -> Vec<RevState> {
    let mut t = snapshot_t_h;
    revs.iter()
        .map(|r| {
            let dt_h = r.n_samples as f64 / sr / 3600.0;
            let s = RevState {
                t_h: t,
                a_db: 20.0 * (r.rms_fs.max(1e-9)).log10(),
                i_semi: 12.0 * (r.zcr_hz.max(1.0) / 1000.0).log2(),
                bits: r.bits as f64 / r.n_samples.max(1) as f64,
            };
            t += dt_h;
            s
        })
        .collect()
}

/// Run the ported dynamics over a whole life of revolution states.
/// `smooth_revs` tames rev-to-rev estimator noise before differentiation
/// (edge-safe smoothing — see geometry::smooth).
pub fn machine_dynamics(states: &[RevState], smooth_revs: usize) -> Dynamics {
    let a: Vec<f64> = states.iter().map(|s| s.a_db).collect();
    let i: Vec<f64> = states.iter().map(|s| s.i_semi).collect();
    let meta = DynamicsMeta { smooth_frames: smooth_revs, ..Default::default() };
    derive_dynamics(&a, &i, &meta)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn steady_revolutions_produce_a_flat_odometer() {
        // Identical revolutions => the state never moves => zero climb.
        let revs: Vec<RevStats> = (0..64)
            .map(|_| RevStats { bits: 5000, n_samples: 614, rms_fs: 0.018, zcr_hz: 900.0 })
            .collect();
        let st = states_from_revs(&revs, 0.0, 20480.0);
        let dyn_ = machine_dynamics(&st, 1);
        assert!(dyn_.h.last().unwrap().abs() < 1e-12);
    }
}
