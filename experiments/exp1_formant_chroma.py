"""Experiment 1 -- differentiability regression test: formant shape -> chroma.

Re-runs the prior session's finding (finite-diff: loss 0.458 -> 0.138, 69.8%
reduction, smooth) but with REAL autograd + Adam. Pass criterion (per advisor):
a large, smooth loss drop with sane gradients -- NOT matching the exact 0.138,
since a different optimizer and exact-vs-finite-diff gradients give a different
trajectory.

The model has 6 learnable parameters (2 Gaussian formants: center/width/gain
each). f0 is FIXED here -- this isolates the formant->chroma map, which is the
part the prior session showed trains cleanly.
"""

import torch

import pathlib
import sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))  # repo root, for `beehive`

from beehive.signals import synth_harmonic_spectrum
from beehive.chroma import soft_chroma_projection

torch.set_default_dtype(torch.float64)
torch.manual_seed(0)

F0 = 220.0
N_HARM = 24
SIGMA = 0.5
STEPS = 300


def l2norm(v):
    return v / v.norm().clamp_min(1e-12)


def chroma_of(f0, centers, widths, gains):
    freqs, amps = synth_harmonic_spectrum(
        torch.as_tensor(f0), centers, widths, gains, n_harmonics=N_HARM)
    return soft_chroma_projection(freqs, amps, sigma=SIGMA)


def main():
    # Ground-truth (target) formants -- a vowel-like two-resonance shape.
    true_centers = torch.tensor([600.0, 2200.0])
    true_widths = torch.tensor([120.0, 240.0])
    true_gains = torch.tensor([1.0, 0.55])
    target = l2norm(chroma_of(F0, true_centers, true_widths, true_gains)).detach()

    # Learnable model, reparametrised so all raw params are O(1) and one Adam lr
    # works: center = anchor + 200*dc, width = w_anchor*exp(dw), gain = g_anchor*exp(dg).
    # Anchors are the (wrong) STARTING point; the optimiser moves the deltas.
    c_anchor = torch.tensor([450.0, 2600.0])   # off from true [600, 2200]
    w_anchor = torch.tensor([200.0, 160.0])    # off from true [120, 240]
    g_anchor = torch.tensor([0.6, 0.9])        # off from true [1.0, 0.55]
    dc = torch.zeros(2, requires_grad=True)
    dw = torch.zeros(2, requires_grad=True)
    dg = torch.zeros(2, requires_grad=True)

    def model_params():
        return c_anchor + 200.0 * dc, w_anchor * torch.exp(dw), g_anchor * torch.exp(dg)

    opt = torch.optim.Adam([dc, dw, dg], lr=0.05)

    losses, grad_norms = [], []
    for step in range(STEPS):
        opt.zero_grad()
        centers, widths, gains = model_params()
        pred = l2norm(chroma_of(F0, centers, widths, gains))
        loss = ((pred - target) ** 2).sum()
        loss.backward()
        gn = torch.cat([dc.grad.flatten(), dw.grad.flatten(), dg.grad.flatten()]).norm()
        opt.step()
        losses.append(loss.item())
        grad_norms.append(gn.item())

    loss0, lossN = losses[0], losses[-1]
    reduction = 100.0 * (loss0 - lossN) / loss0
    any_nan = any(t != t for t in losses + grad_norms)
    # Smoothness: fraction of steps where loss did not increase.
    monotone = sum(1 for a, b in zip(losses, losses[1:]) if b <= a + 1e-12) / (len(losses) - 1)

    print("=== Experiment 1: formant-shape -> chroma (autograd + Adam) ===")
    print(f"params: 6 (2 formants x center/width/gain), f0 fixed at {F0} Hz")
    print(f"loss start : {loss0:.4f}")
    print(f"loss end   : {lossN:.4f}")
    print(f"reduction  : {reduction:.1f}%")
    print(f"loss@ steps 0/50/150/299: "
          f"{losses[0]:.4f} / {losses[50]:.4f} / {losses[150]:.4f} / {losses[299]:.4f}")
    print(f"grad norm start/end: {grad_norms[0]:.3e} / {grad_norms[-1]:.3e}")
    print(f"NaN/inf present: {any_nan}")
    print(f"fraction of steps non-increasing (smoothness): {monotone:.3f}")

    c, w, g = model_params()
    print("recovered centers:", [round(x, 1) for x in c.tolist()],
          " true:", true_centers.tolist())

    passed = (reduction > 50.0) and (not any_nan) and (monotone > 0.9)
    print(f"\nPASS (large smooth drop, sane grads): {passed}")
    return passed


if __name__ == "__main__":
    main()
