"""Experiment 3 -- synthetic encode/decode sanity check.

"Is this representation actually informative?" Encode a synthetic tone with known
f0 and known formants, then try to identify (f0, formant shape) back out of the
encoding. Two encodings are compared, because they answer different questions:

  (1) FULL spectral representation -- the formant-shaped harmonic spectrum
      rendered onto a frequency grid (what the pipeline has before the chroma
      collapse). Tests whether the underlying signal is identifiable at all.

  (2) CHROMA-only -- the 12-dim pitch-class projection the model uses as
      "timbral identity". Tests whether that bottleneck alone is invertible.

f0 is recovered with a coarse grid warm-start (the fix that worked in exp2) plus
Adam joint fine-tuning of f0 and the 6 formant params.
"""

import torch

import pathlib
import sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))  # repo root, for `beehive`

from beehive.signals import synth_harmonic_spectrum
from beehive.chroma import soft_chroma_projection

torch.set_default_dtype(torch.float64)
torch.manual_seed(0)

F0_TRUE = 196.0
N_HARM = 24
SIGMA = 0.5
CENTS_TOL = 50.0

TRUE_CENTERS = torch.tensor([550.0, 1800.0])
TRUE_WIDTHS = torch.tensor([100.0, 220.0])
TRUE_GAINS = torch.tensor([1.0, 0.6])

# Spectral-render grid (a smoothed magnitude spectrum).
GRID = torch.linspace(0.0, 5000.0, 1000)
KW = 25.0


def cents(f_est, f_true=F0_TRUE):
    return 1200.0 * torch.log2(torch.as_tensor(f_e) / f_true).item()


def cents_fold(f_est):
    c = cents(f_est)
    return ((c + 600.0) % 1200.0) - 600.0


def render_spectrum(freqs, amps):
    f = GRID.unsqueeze(-1)                                  # (G,1)
    return (amps * torch.exp(-(f - freqs) ** 2 / (2 * KW**2))).sum(dim=-1)


def make_params(f0_start):
    """Learnable (log f0, formant deltas) reparametrised to O(1)."""
    log_f0 = torch.log(torch.tensor(float(f0_start))).requires_grad_(True)
    c_anchor = torch.tensor([500.0, 1500.0])
    w_anchor = torch.tensor([150.0, 150.0])
    g_anchor = torch.tensor([0.8, 0.8])
    dc = torch.zeros(2, requires_grad=True)
    dw = torch.zeros(2, requires_grad=True)
    dg = torch.zeros(2, requires_grad=True)

    def unpack():
        f0 = torch.exp(log_f0)
        centers = c_anchor + 200.0 * dc
        widths = w_anchor * torch.exp(dw)
        gains = g_anchor * torch.exp(dg)
        return f0, centers, widths, gains

    return [log_f0, dc, dw, dg], unpack


def _fine_tune(target_loss, f0_start, steps):
    params, unpack = make_params(f0_start)
    opt = torch.optim.Adam([
        {"params": [params[0]], "lr": 0.01},          # log f0
        {"params": params[1:], "lr": 0.05},           # formant deltas
    ])
    for _ in range(steps):
        opt.zero_grad()
        f0, c, w, g = unpack()
        freqs, amps = synth_harmonic_spectrum(f0, c, w, g, n_harmonics=N_HARM)
        loss = target_loss(freqs, amps)
        loss.backward()
        opt.step()
    f0, c, w, g = unpack()
    return f0.item(), c.detach(), w.detach(), g.detach(), loss.item()


def decode(target_loss, steps=400, n_starts=60):
    """Multi-restart decode (the method exp2 established is required for f0).

    Fine-tune jointly from every coarse-grid f0 start and keep the lowest-loss
    solution -- best-of-N restarts, no cherry-picking of a single warm-start.
    """
    starts = torch.linspace(80.0, 600.0, n_starts)
    best = None
    for f0_start in starts.tolist():
        res = _fine_tune(target_loss, f0_start, steps)
        if best is None or res[4] < best[4]:
            best = res + (f0_start,)
    return best  # (f0, c, w, g, loss, best_start)


def main():
    print("=== Experiment 3: synthetic encode/decode sanity check ===")
    print(f"source: f0={F0_TRUE} Hz, centers={TRUE_CENTERS.tolist()}, "
          f"widths={TRUE_WIDTHS.tolist()}, gains={TRUE_GAINS.tolist()}\n")

    true_freqs, true_amps = synth_harmonic_spectrum(
        torch.tensor(F0_TRUE), TRUE_CENTERS, TRUE_WIDTHS, TRUE_GAINS, n_harmonics=N_HARM)
    true_render = render_spectrum(true_freqs, true_amps).detach()
    true_chroma = soft_chroma_projection(true_freqs, true_amps, sigma=SIGMA).detach()
    true_chroma_n = true_chroma / true_chroma.norm()

    # (1) Decode from the FULL spectral representation.
    def spec_loss(freqs, amps):
        return ((render_spectrum(freqs, amps) - true_render) ** 2).mean()

    f0_s, c_s, w_s, g_s, l_s, start_s = decode(spec_loss)
    cerr_s = (c_s - TRUE_CENTERS).abs()
    print("(1) FULL spectral representation")
    print(f"    f0: recovered {f0_s:.2f} Hz  (true {F0_TRUE})  -> {cents(f0_s):+.1f} cents")
    print(f"    formant centers: {[round(x,1) for x in c_s.tolist()]}  "
          f"(true {TRUE_CENTERS.tolist()})  abs err {[round(x,1) for x in cerr_s.tolist()]} Hz")
    print(f"    final spectral loss: {l_s:.3e}")
    pass1 = abs(cents(f0_s)) < CENTS_TOL and bool((cerr_s < 50.0).all())
    print(f"    identifiable: {pass1}\n")

    # (2) Decode from CHROMA-only.
    def chroma_loss(freqs, amps):
        ch = soft_chroma_projection(freqs, amps, sigma=SIGMA)
        return ((ch / ch.norm().clamp_min(1e-12) - true_chroma_n) ** 2).sum()

    f0_c, c_c, w_c, g_c, l_c, start_c = decode(chroma_loss)
    cerr_c = (c_c - TRUE_CENTERS).abs()
    print("(2) CHROMA-only (12-dim timbral-identity vector)")
    print(f"    f0: recovered {f0_c:.2f} Hz  -> {cents(f0_c):+.1f} cents "
          f"(octave-folded {cents_fold(f0_c):+.1f})")
    print(f"    formant centers: {[round(x,1) for x in c_c.tolist()]}  "
          f"(true {TRUE_CENTERS.tolist()})  abs err {[round(x,1) for x in cerr_c.tolist()]} Hz")
    print(f"    final chroma loss: {l_c:.3e}  (how well the 12-dim target was matched)")
    # The diagnostic: chroma can be matched well (low loss) while the recovered
    # generative params are wrong -> the encoding is many-to-one (not invertible).
    chroma_matched = l_c < 1e-3
    params_wrong = abs(cents(f0_c)) >= CENTS_TOL or bool((cerr_c >= 50.0).any())
    print(f"    chroma matched (loss<1e-3): {chroma_matched};  "
          f"yet generative params off: {params_wrong}")
    print(f"    -> chroma alone invertible to source: {not params_wrong}\n")

    print("--- Verdict ---")
    print(f"Full spectral representation identifies source f0 & formants: {pass1}")
    print(f"Chroma-only bottleneck identifies source f0 & formants:       {not params_wrong}")
    if chroma_matched and params_wrong:
        print("Chroma is a low-loss MATCH but many-to-one: a similarity/identity")
        print("descriptor, not an invertible code. Pairing it with one absolute-scale")
        print("anchor (e.g. recovered f0 from the full spectrum) is what makes the")
        print("representation invertible.")
    return {"full_pass": pass1, "chroma_invertible": not params_wrong,
            "chroma_loss": l_c, "f0_full": f0_s, "f0_chroma": f0_c}


if __name__ == "__main__":
    main()
