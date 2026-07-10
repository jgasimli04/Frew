"""The foundation engine: a real song -> a HelixRecord.

Pipeline (derivation steps 1-6, on real audio for the first time):

  decode -> frames -> state s(n)=(A,I) -> force F=ds/dn -> climb h=integral||F||
         -> angle alpha=omega*t -> position R(n)=(r0 cos a, r0 sin a, h)
         -> timbral colour (chroma -> hue) -> HelixRecord (on standby).

Two modelling choices are made explicit here because the skill lists them as
open:

  * n is the hop/frame index. The angle advances with real elapsed time,
    alpha = omega_n * n with omega_n = omega * hop/sr (rad per frame), so a bar
    is still one 2*pi turn at the estimated tempo regardless of hop size.

  * the A-vs-I weighting inside ||F|| (the open "weighting" thread): A (dB) and I
    (semitones) are different units, so their derivatives are each divided by
    their own std over the track before being combined, then scaled by optional
    weights wA, wI (default 1). This makes ||F|| dimensionless and comparable
    across songs; the weights are the knob to revisit.

The helix position and the corrected curvature/torsion closed forms are inlined
in numpy here (mirroring the verified torch `helix.py`) so encoding has no torch
dependency; `tests/test_engine.py` asserts they agree with the torch reference.
"""

import datetime as _dt
import os
import math
import numpy as np

from .audio import content_hash, load_audio
from .features import (
    chroma_from_mag,
    chroma_weight_matrix,
    frame_signal,
    interval_semitones,
    loudness_db,
    stft_mag,
)
from .tempo import estimate_bpm

EPS = 1e-10
ENGINE_VERSION = "0.1.0"

# --- TOPOLOGICAL CONSTANTS ---
PHI = (1.0 + math.sqrt(5.0)) / 2.0 
MAX_PERCEPTUAL_LATENCY_SEC = 0.020
# -----------------------------

def _curvature_torsion(omega, r0, h1, h2, h3):
    """Corrected Frenet kappa, tau for R(n)=(r0 cos wn, r0 sin wn, h(n)).

    Numpy mirror of beehive.helix.curvature_torsion (note the omega**4 r0**2 term
    under the root -- the typo fixed in this project). Parametrised by n, so omega
    here is the per-frame angular step.
    """
    common = omega**4 * r0**2 + omega**2 * h1**2 + h2**2
    cross_norm = r0 * omega * np.sqrt(common)
    speed_sq = omega**2 * r0**2 + h1**2
    kappa = cross_norm / speed_sq**1.5
    tau = omega * (omega**2 * h1 + h3) / np.maximum(common, EPS)
    return kappa, tau


def _smooth(x, k):
    if k <= 1:
        return x
    kernel = np.ones(k) / k
    return np.convolve(x, kernel, mode="same")


def derive_dynamics(A, I, chroma, meta):
    """Reconstruct everything geometric from the independent state (A, I, chroma).

    This is what makes a record genuinely compact: only A, I, chroma (and the
    reserved engagement layer) are stored; the force, climb, helix position,
    curvature/torsion and colour are *functions* of that state plus the scalar
    meta (bpm/omega, r0, hop, sr, weighting), so they are recomputed on load
    rather than stored. encode_song and HelixRecord.load share this one function,
    so the in-memory record is always identical whether freshly encoded or
    reloaded.
    """
    A = np.asarray(A, np.float64)
    I = np.asarray(I, np.float64)
    chroma = np.asarray(chroma, np.float64)
    n = len(A)

    hop, sr = meta["hop"], meta["sr"]
    r0, f_ref = meta["r0"], meta["f_ref"]
    floor_db = meta["floor_db"]
    omega_n = meta["omega_rad_per_frame"]
    k = meta.get("smooth_frames", 1)
    w_amp = meta["force_weighting"]["w_amp"]
    w_int = meta["force_weighting"]["w_int"]

    # force F = ds/dn; normalise each component by its own std (dB vs semitones
    # are different units) so ||F|| is dimensionless and comparable across songs.
    dA = np.gradient(_smooth(A, k))
    dI = np.gradient(_smooth(I, k))
    sA = dA.std() or 1.0
    sI = dI.std() or 1.0
    F_mag = np.sqrt((w_amp * dA / sA) ** 2 + (w_int * dI / sI) ** 2)

    h = np.cumsum(F_mag)                                       # climb = integral ||F||

    n_idx = np.arange(n, dtype=np.float64)
    t = n_idx * hop / sr
    alpha = omega_n * n_idx
    x = r0 * np.cos(alpha)
    y = r0 * np.sin(alpha)
    z = h

    h2 = np.gradient(F_mag)
    h3 = np.gradient(h2)
    kappa, tau = _curvature_torsion(omega_n, r0, F_mag, h2, h3)

    pc_ang = 2.0 * np.pi * np.arange(12) / 12.0
    vec = chroma @ np.exp(1j * pc_ang)
    hue = (np.angle(vec) / (2.0 * np.pi)) % 1.0
    sat = np.abs(vec) / (chroma.sum(axis=1) + EPS)
    val = np.clip((A - floor_db) / (0.0 - floor_db), 0.0, 1.0)

    return dict(t=t, dA=dA, dI=dI, F_mag=F_mag, h=h, alpha=alpha,
                x=x, y=y, z=z, kappa=kappa, tau=tau, hue=hue, sat=sat, val=val)


def encode_song(
    path,
    *,
    n_fft=2048,
    hop=1024,
    B=4,
    r0=1.0,
    f_ref=440.0,
    sigma=0.5,
    floor_db=-80.0,
    bpm=None,
    bpm_range=(60.0, 200.0),
    w_amp=1.0,
    w_int=1.0,
    smooth_frames=1,
):
    """Encode an audio file into a HelixRecord (kept on standby in the helichain).

    Parameters mirror the open knobs: hop fixes n, B fixes bars-per-turn, r0 the
    radius (constant for now -- the radius law is still open), (w_amp, w_int) the
    force weighting, bpm overrides tempo estimation if given.
    """
    from .record import HelixRecord   # local import avoids a cycle

    y, sr = load_audio(path, mono=True)
    chash = content_hash(y)
    win = n_fft

    window = np.hanning(win).astype(np.float32)
    frames = frame_signal(y, win, hop)
    mag = stft_mag(frames, n_fft, window)
    freqs = np.fft.rfftfreq(n_fft, 1.0 / sr)

    # --- state s(n) = (A, I) ---
    A = loudness_db(frames, floor_db)
    I = interval_semitones(mag, freqs, f_ref)

    # --- timbral identity (for colour) ---
    w_mat = chroma_weight_matrix(freqs, sigma=sigma, f_ref=f_ref)
    chroma = chroma_from_mag(mag, w_mat)                       # (n_frames, 12)

    # --- tempo -> omega ---
    bpm_conf = None
    if bpm is None:
        bpm, bpm_conf = estimate_bpm(mag, sr, hop, *bpm_range)
    omega = 2.0 * np.pi * bpm / (60.0 * B)                     # rad / second
    omega_n = omega * hop / sr                                 # rad / frame

    # --- POLYMERASE PROOFREADING BOUNDARY ---
    hop_duration_sec = hop / sr
    
    # Calculate instantaneous state velocity
    dA_dt = np.gradient(A) / hop_duration_sec
    dI_dt = np.gradient(I) / hop_duration_sec
    
    # Track volatility is the combined standard deviation of the state velocity
    # Explicit float() cast prevents np.float64 leakage into the JSON manifest
    track_volatility = float(np.std(np.sqrt(dA_dt**2 + dI_dt**2)))
    
    # Bound to human perception and apply Golden Ratio constraint
    drift_rate_est = max(track_volatility * MAX_PERCEPTUAL_LATENCY_SEC, 1e-6)
    proofreading_tau = drift_rate_est * PHI
    # ----------------------------------------

    # --- engagement: reserved schema (the "most rewatched" layer) ---
    engagement = np.zeros(len(A), dtype=np.float32)

    stem = os.path.splitext(os.path.basename(path))[0]
    song_id = f"{stem}-{chash[:8]}"

    meta = {
        "engine_version": ENGINE_VERSION,
        "song_id": song_id,
        "source_path": os.path.abspath(path),
        "content_hash": chash,
        "created_at": _dt.datetime.now().isoformat(timespec="seconds"),
        "sr": sr,
        "n_samples": int(len(y)),
        "duration_s": float(len(y) / sr),
        "n_fft": n_fft,
        "hop": hop,
        "win": win,
        "n_frames": int(len(A)),
        "bpm": float(bpm),
        "bpm_confidence": (None if bpm_conf is None else float(bpm_conf)),
        "bpm_source": ("estimated" if bpm_conf is not None else "provided"),
        "B": B,
        "omega_rad_per_s": float(omega),
        "omega_rad_per_frame": float(omega_n),
        "r0": r0,
        "f_ref": f_ref,
        "sigma": sigma,
        "floor_db": floor_db,
        "smooth_frames": smooth_frames,
        
        # --- INJECT PROOFREADING CONSTRAINTS ---
        "drift_rate_est": float(drift_rate_est),
        "proofreading_tau": float(proofreading_tau),
        # ---------------------------------------

        "n_definition": "hop/frame index; angle alpha = omega_n * n, omega_n = omega*hop/sr",
        "state_definition": "A = loudness dB; I = spectral centroid in semitones above f_ref (energy-gated)",
        "force_weighting": {
            "w_amp": w_amp, "w_int": w_int,
            "normalization": "each derivative divided by its own std over the track",
            "note": "open knob (skill: 'weighting inside ||F||')",
        },
        "stored_state": "only A, I, chroma, engagement are stored; force/climb/geometry/colour are derived on load",
        "colour": "hue = circular mean of 12-d chroma; sat = concentration; val = loudness",
        "caveats": [
            "chroma->timbre is many-to-one (exp3): different timbres can share a hue",
            "bpm is a light autocorrelation estimate; half/double octave errors are common -- override with bpm=",
            "r0 constant: the radius law (completion = largest radius) is still open",
            "record is uniform-density: Polymerase predictive excision boundary (proofreading_tau) is calculated, awaiting Rust beecore implementation for variable-rate keyframing.",
        ],
        "engagement_schema": {
            "per_frame": "engagement[n] accumulates listener attention aligned to frame n",
            "status": "reserved; zeros until real playback/interaction capture exists",
            "intended_signals": ["volume-ups", "micro-jitters/replays (most-rewatched)"],
        },
    }

    der = derive_dynamics(A, I, chroma, meta)
    return HelixRecord(meta=meta, A=A, I=I, chroma=chroma, engagement=engagement, **der)