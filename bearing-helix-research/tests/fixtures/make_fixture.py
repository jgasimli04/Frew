"""Generate the geometry parity fixtures from the audio project's own source.

Run from the sonoFaig repo root (so `beehive` imports):

    python3 bearing-helix-research/tests/fixtures/make_fixture.py

Writes two TSVs next to itself. These are committed, so `cargo test` never
needs Python; this script exists to regenerate them if beehive/encode.py ever
changes. The Rust port under test: src/geometry.rs.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.getcwd())
from beehive.encode import derive_dynamics, _smooth  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))

# --- dynamics fixture: smooth_frames=1 (identity smoothing) => exact parity ---
n = 96
idx = np.arange(n, dtype=np.float64)
A = -30.0 + 6.0 * np.sin(0.13 * idx) + 1.5 * np.sin(0.531 * idx + 0.2)
I = 2.0 + 3.0 * np.cos(0.07 * idx) + 0.7 * np.sin(0.29 * idx + 1.1)
chroma = np.full((n, 12), 1.0 / 12.0)  # colour path unused by the port
meta = {
    "hop": 1024, "sr": 20480, "r0": 1.0, "f_ref": 440.0, "floor_db": -80.0,
    "omega_rad_per_frame": 2.0 * np.pi / 64.0, "smooth_frames": 1,
    "force_weighting": {"w_amp": 1.0, "w_int": 1.3},
}
der = derive_dynamics(A, I, chroma, meta)

cols = ["A", "I", "dA", "dI", "F_mag", "h", "kappa", "tau"]
data = np.column_stack([A, I, der["dA"], der["dI"], der["F_mag"], der["h"],
                        der["kappa"], der["tau"]])
with open(os.path.join(HERE, "dynamics_parity.tsv"), "w") as f:
    f.write(f"# omega_n={meta['omega_rad_per_frame']!r} r0=1.0 w_amp=1.0 w_int=1.3 smooth_frames=1\n")
    f.write("\t".join(cols) + "\n")
    for row in data:
        f.write("\t".join(repr(float(v)) for v in row) + "\n")

# --- smoothing fixture: k=5, numpy mode="same" (zero-padded edges) ------------
x = 3.0 + np.sin(0.4 * idx) * 2.0 + np.cos(1.3 * idx)
y = _smooth(x, 5)
with open(os.path.join(HERE, "smooth_parity.tsv"), "w") as f:
    f.write("# k=5; y is numpy convolve mode='same' -- interior must match the "
            "Rust port exactly, edges are the documented deviation\n")
    f.write("x\ty_numpy\n")
    for xi, yi in zip(x, y):
        f.write(f"{float(xi)!r}\t{float(yi)!r}\n")

print("wrote", os.path.join(HERE, "dynamics_parity.tsv"))
print("wrote", os.path.join(HERE, "smooth_parity.tsv"))
