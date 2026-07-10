"""Beehive vocoder — differentiable prototype.

Energy-driven 3D helix representation of audio, built as PyTorch-differentiable
functions so every piece can be trained with exact autograd gradients.

See ~/.claude/skills/beehive/SKILL.md for the full model and vocabulary, and
sonoFaig/BEEHIVE_BLUEPRINT.md for this build session's spec.
"""

from .helix import helix_position, curvature_torsion
from .formant import formant_envelope
from .chroma import soft_chroma_projection, hard_chroma_projection
from .signals import synth_harmonic_spectrum

# Foundation engine: real audio -> persistent helix record -> helichain.
from .audio import load_audio, content_hash
from .encode import encode_song
from .record import HelixRecord
from .helichain import Helichain

# .bee file format (the two-layer container: lossless payload + helix side-channel).
from .beefile import write_bee, read_bee, decode_bee_to_wav, bee_info

__all__ = [
    "helix_position",
    "curvature_torsion",
    "formant_envelope",
    "soft_chroma_projection",
    "hard_chroma_projection",
    "synth_harmonic_spectrum",
    "load_audio",
    "content_hash",
    "encode_song",
    "HelixRecord",
    "Helichain",
    "write_bee",
    "read_bee",
    "decode_bee_to_wav",
    "bee_info",
]
