"""Experiment 2 -- f0/pitch trainability, properly powered.

The prior session found, with finite differences, that the f0 -> chroma loss
landscape is non-convex and multimodal, and plain gradient descent gets stuck.
The open question for THIS session: does a better optimiser (Adam) plus multiple
restarts, or a coarse grid warm-start, actually solve what plain GD couldn't?

Method, made apples-to-apples (per advisor):
  * One shared, SEEDED set of random f0 inits, reused across optimiser methods.
  * Fixed step budget per init.
  * A stated success criterion in cents (musically meaningful), reported as the
    FRACTION of inits that converge -- not one lucky run.
  * Everything optimises theta = log(f0) so the parameter scale is natural and a
    single learning rate is meaningful (gives plain GD its fair shot too).

The honest answer may be "no". If so, reporting it with numbers IS the result;
we do not tune until it turns green.
"""

import torch

import pathlib
import sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))  # repo root, for `beehive`

from beehive.signals import synth_harmonic_spectrum
from beehive.chroma import soft_chroma_projection

torch.set_default_dtype(torch.float64)
torch.manual_seed(0)

F0_TRUE = 220.0
N_HARM = 24
SIGMA = 0.5
F_LO, F_HI = 80.0, 600.0       # search range (Hz)
N_INITS = 24
BUDGET = 600
CENTS_TOL = 50.0               # within half a semitone of true f0 == success

# Fixed, known formants (vowel-like) -- timbre is held constant; only f0 varies.
CENTERS = torch.tensor([600.0, 2200.0])
WIDTHS = torch.tensor([120.0, 240.0])
GAINS = torch.tensor([1.0, 0.55])


def l2norm(v):
    return v / v.norm().clamp_min(1e-12)


def chroma_of_f0(f0):
    freqs, amps = synth_harmonic_spectrum(f0, CENTERS, WIDTHS, GAINS, n_harmonics=N_HARM)
    return soft_chroma_projection(freqs, amps, sigma=SIGMA)


TARGET = l2norm(chroma_of_f0(torch.tensor(F0_TRUE))).detach()


def loss_of_f0(f0):
    return ((l2norm(chroma_of_f0(f0)) - TARGET) ** 2).sum()


def cents(f_est, f_true=F0_TRUE):
    return 1200.0 * torch.log2(torch.as_tensor(f_est) / f_true).item()


def cents_octave_folded(f_est):
    c = cents(f_est)
    return ((c + 600.0) % 1200.0) - 600.0      # fold into (-600, 600]


# --------------------------------------------------------------------------
# 1. Characterise the landscape on a fine grid.
# --------------------------------------------------------------------------
def characterise_landscape():
    grid = torch.linspace(F_LO, F_HI, 6000)
    losses = torch.stack([loss_of_f0(f) for f in grid])
    # Local minima: interior points strictly below both neighbours, with a small
    # prominence so we don't count numerical ripples.
    lo = losses[1:-1]
    is_min = (lo < losses[:-2]) & (lo < losses[2:]) & (lo < losses.max() * 0.5)
    minima_f = grid[1:-1][is_min]
    g_idx = torch.argmin(losses)
    return {
        "n_local_minima": int(is_min.sum()),
        "minima_hz": [round(x, 1) for x in minima_f.tolist()],
        "global_min_hz": round(grid[g_idx].item(), 2),
        "loss_min": losses.min().item(),
        "loss_max": losses.max().item(),
    }


# --------------------------------------------------------------------------
# 2. Optimiser runs (all on theta = log f0).
# --------------------------------------------------------------------------
def run(theta_init, make_opt, steps):
    theta = torch.as_tensor(theta_init, dtype=torch.float64).clone().detach().requires_grad_(True)
    opt = make_opt([theta])
    for _ in range(steps):
        opt.zero_grad()
        loss = loss_of_f0(torch.exp(theta))
        loss.backward()
        opt.step()
    return torch.exp(theta).item()


def sweep_method(name, make_opt_factory, inits, lrs):
    """For a given optimiser family, try several lrs; report the BEST lr's
    fraction-converged (best-case for that optimiser)."""
    best = None
    for lr in lrs:
        finals = [run(ti, make_opt_factory(lr), BUDGET) for ti in inits]
        exact = sum(1 for f in finals if abs(cents(f)) < CENTS_TOL)
        folded = sum(1 for f in finals if abs(cents_octave_folded(f)) < CENTS_TOL)
        rec = {"lr": lr, "exact": exact, "folded": folded, "finals": finals}
        if best is None or exact > best["exact"] or (exact == best["exact"] and folded > best["folded"]):
            best = rec
    print(f"  {name:28s} best lr={best['lr']:<6} "
          f"exact {best['exact']:2d}/{N_INITS}  octave-folded {best['folded']:2d}/{N_INITS}")
    return best


def grid_warm_start():
    """Coarse grid -> pick best -> Adam fine-tune. Deterministic."""
    coarse = torch.linspace(F_LO, F_HI, 60)
    cl = torch.stack([loss_of_f0(f) for f in coarse])
    f_start = coarse[torch.argmin(cl)].item()
    f_final = run(torch.log(torch.tensor(f_start)),
                  lambda p: torch.optim.Adam(p, lr=0.02), 300)
    return f_start, f_final


def main():
    print("=== Experiment 2: f0 -> chroma trainability ===")
    print(f"true f0 = {F0_TRUE} Hz, search [{F_LO}, {F_HI}] Hz, "
          f"{N_INITS} shared seeded inits, budget {BUDGET}, tol {CENTS_TOL} cents\n")

    land = characterise_landscape()
    print("Landscape (fine grid, 6000 pts):")
    print(f"  local minima (prominent): {land['n_local_minima']}  at {land['minima_hz']} Hz")
    print(f"  global min at {land['global_min_hz']} Hz (true {F0_TRUE})")
    print(f"  loss range: {land['loss_min']:.4f} .. {land['loss_max']:.4f}")
    print(f"  -> multimodal: {land['n_local_minima'] > 1}\n")

    # Shared seeded inits (same theta_inits used by every optimiser method).
    g = torch.Generator().manual_seed(42)
    init_f0 = (torch.rand(N_INITS, generator=g) * (F_HI - F_LO) + F_LO)
    inits = torch.log(init_f0).tolist()
    print(f"Convergence (fraction of {N_INITS} shared inits reaching <{CENTS_TOL} cents):")

    a = sweep_method("A. plain GD (SGD)",
                     lambda lr: (lambda p: torch.optim.SGD(p, lr=lr)),
                     inits, lrs=[0.003, 0.01, 0.03, 0.1, 0.3])
    b = sweep_method("B. Adam",
                     lambda lr: (lambda p: torch.optim.Adam(p, lr=lr)),
                     inits, lrs=[0.01, 0.02, 0.05, 0.1])

    # C. Adam + multiple restarts == best-of-N across the shared inits.
    best_final = min(b["finals"], key=lambda f: abs(cents_octave_folded(f)))
    c_exact = any(abs(cents(f)) < CENTS_TOL for f in b["finals"])
    c_folded = any(abs(cents_octave_folded(f)) < CENTS_TOL for f in b["finals"])
    print(f"  {'C. Adam + restarts (best-of-N)':28s} "
          f"exact-hit {c_exact}  octave-folded-hit {c_folded}  "
          f"best final {best_final:.2f} Hz ({cents_octave_folded(best_final):+.1f} cents folded)")

    # D. grid warm-start.
    f_start, f_final = grid_warm_start()
    d_exact = abs(cents(f_final)) < CENTS_TOL
    print(f"  {'D. grid warm-start + Adam':28s} "
          f"start {f_start:.1f} Hz -> {f_final:.2f} Hz  "
          f"({cents(f_final):+.1f} cents)  success {d_exact}")

    print("\n--- Verdict on the open question ---")
    print(f"Plain GD best-case fraction:        {a['exact']}/{N_INITS} exact, {a['folded']}/{N_INITS} octave-folded")
    print(f"Adam best-case fraction:            {b['exact']}/{N_INITS} exact, {b['folded']}/{N_INITS} octave-folded")
    print(f"Adam + restarts solves it:          {c_folded} (octave-folded)")
    print(f"Grid warm-start solves it:          {d_exact}")
    return {"A": a, "B": b, "C": (c_exact, c_folded), "D": (f_final, d_exact), "land": land}


if __name__ == "__main__":
    main()
