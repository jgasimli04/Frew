"""Independent symbolic re-derivation of the helix curvature kappa and torsion tau.

Per the project's verify-don't-guess norm: we do NOT transcribe the blueprint's
closed forms and test formula==formula (that would bless a typo). We build R(n)
from scratch, compute kappa and tau via the Frenet cross-product formulas in sympy,
simplify, and compare against:
  (a) the blueprint's STATED kappa  (omega**2 * r0**2 under the sqrt)
  (b) the blueprint's stated tau
  (c) the CORRECTED kappa           (omega**4 * r0**2 under the sqrt)

Expected outcome (the reason this script exists): tau matches, stated-kappa does
NOT, corrected-kappa does.
"""

import sympy as sp


def main():
    n = sp.symbols("n", real=True)
    omega, r0 = sp.symbols("omega r0", positive=True)
    h = sp.Function("h")(n)

    R = sp.Matrix([r0 * sp.cos(omega * n), r0 * sp.sin(omega * n), h])
    R1 = sp.diff(R, n)
    R2 = sp.diff(R, n, 2)
    R3 = sp.diff(R, n, 3)

    cross = R1.cross(R2)
    cross_norm = sp.sqrt(sp.simplify(cross.dot(cross)))
    speed = sp.sqrt(sp.simplify(R1.dot(R1)))

    kappa = sp.simplify(cross_norm / speed**3)
    tau = sp.simplify(cross.dot(R3) / cross.dot(cross))

    # Substitute h', h'', h''' -> named symbols for a readable comparison.
    h1, h2, h3 = sp.symbols("h1 h2 h3", real=True)
    subs = {sp.diff(h, n, 3): h3, sp.diff(h, n, 2): h2, sp.diff(h, n): h1}
    kappa_s = sp.simplify(kappa.subs(subs))
    tau_s = sp.simplify(tau.subs(subs))

    # Candidate closed forms.
    stated_kappa = omega * r0 * sp.sqrt(omega**2 * r0**2 + omega**2 * h1**2 + h2**2) \
        / (omega**2 * r0**2 + h1**2) ** sp.Rational(3, 2)
    corrected_kappa = omega * r0 * sp.sqrt(omega**4 * r0**2 + omega**2 * h1**2 + h2**2) \
        / (omega**2 * r0**2 + h1**2) ** sp.Rational(3, 2)
    stated_tau = omega * (omega**2 * h1 + h3) / (omega**4 * r0**2 + omega**2 * h1**2 + h2**2)

    def matches(a, b):
        return sp.simplify(a - b) == 0

    print("=== Independently derived (sympy) ===")
    print("kappa =", kappa_s)
    print("tau   =", tau_s)
    print()
    print("=== Comparisons ===")
    print("tau            == stated tau           :", matches(tau_s, stated_tau))
    print("kappa (derived)== blueprint STATED kappa:", matches(kappa_s, stated_kappa))
    print("kappa (derived)== CORRECTED kappa       :", matches(kappa_s, corrected_kappa))
    print()

    # Numeric spot-check at omega != 1 (where the typo is visible) against the
    # torch implementation's corrected form.
    import torch
    from beehive.helix import curvature_torsion
    vals = {omega: sp.Rational(3, 2), r0: 2, h1: sp.Rational(7, 10),
            h2: sp.Rational(-4, 10), h3: sp.Rational(11, 10)}
    k_num = float(kappa_s.subs(vals))
    t_num = float(tau_s.subs(vals))
    k_t, t_t = curvature_torsion(
        omega=1.5, r0=2.0,
        h1=torch.tensor(0.7, dtype=torch.float64),
        h2=torch.tensor(-0.4, dtype=torch.float64),
        h3=torch.tensor(1.1, dtype=torch.float64),
    )
    print("=== Numeric cross-check (omega=1.5) sympy vs torch impl ===")
    print(f"kappa: sympy={k_num:.10f}  torch={float(k_t):.10f}  match={abs(k_num-float(k_t))<1e-9}")
    print(f"tau:   sympy={t_num:.10f}  torch={float(t_t):.10f}  match={abs(t_num-float(t_t))<1e-9}")

    # Sanity: fully static climb -> torsion zero (flat circle).
    k0, t0 = curvature_torsion(
        omega=1.5, r0=2.0,
        h1=torch.tensor(0.0, dtype=torch.float64),
        h2=torch.tensor(0.0, dtype=torch.float64),
        h3=torch.tensor(0.0, dtype=torch.float64),
    )
    print(f"static climb -> tau={float(t0):.3e} (expect 0), kappa={float(k0):.6f} (expect 1/r0={1/2.0})")


if __name__ == "__main__":
    main()
