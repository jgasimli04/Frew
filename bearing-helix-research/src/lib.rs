//! bearing-helix-research: the beehive helix framework pointed at rolling-element
//! bearing vibration.
//!
//! The object under test is a *storage format* (fold.rs): revolutions are
//! segmented at fractional sample boundaries, predicted by a closed-loop
//! time-synchronous-average pool, and the residual is entropy coded — so the
//! stream's own byte rate is a health indicator. The helix state/geometry
//! (state.rs → geometry.rs) rides on top as the odometer.
//!
//! This crate is a faithful local reconstruction of the spec built in remote
//! session commit 6fe0551 (container unreachable; see README). All numbers in
//! docs/ were produced by THIS code on THIS machine.

pub mod dsp;
pub mod event;
pub mod fold;
pub mod geometry;
pub mod indicators;
pub mod io;
pub mod life;
pub mod speed;
pub mod state;
pub mod synth;
