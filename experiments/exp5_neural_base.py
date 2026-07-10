"""exp5 — the neural base-layer gate (BEE_LIGHT_BLUEPRINT.md §4).

Encode the three real tracks in ~/Desktop/Music through pretrained DAC 44kHz
(Kumar et al. 2023, the codec family LOOP_DEDUP/POOL_RESIDUAL point at as the
live path), decode, and report — honestly:

  1. real token-stream size (packed bits, not the inflated uint16 .dac file)
     vs the FLAC/AIFF source and vs today's FLAC-inside .bee;
  2. objective spectral distances (mel L1, multi-scale log-STFT) — *relative*
     reference numbers only, NOT a transparency claim;
  3. level-matched listening PAIRS in experiments/recon/ — THE gate is
     listening. No quality claim is made by this script.

Listening pairs are both normalized to -16 LUFS and written PCM_24, because a
naive "restore original loudness, write 16-bit" decode hard-clips 3.9-5.9% of
samples (DAC's reconstruction overshoots the source's peak structure at equal
loudness — measured 2026-07-06). Equal-loudness pairs with headroom mean the
ears judge the codec, not clipping. Pin for the container: the .bee decode
path must define an output headroom/true-peak policy, not blind-restore
loudness into a fixed-point sink.

Reproduce: .venv/bin/python experiments/exp5_neural_base.py
           [--model-bitrate 16kbps] [--device mps] [--win 10.0]

Notes pinned before anyone re-learns them:
  - DAC 44kHz is a mono model; compress() folds stereo channels into the batch
    dim (L and R coded independently). Mid/side or joint-stereo coding is an
    optimization left open.
  - compress() loudness-normalizes to -16 dB and decompress() restores
    input_db, so the recon is level-matched to the source.
  - RVQ codebooks are coarse-to-fine: decoding with fewer codebooks is a
    built-in progressive-quality ladder (the layered-streaming story). This
    script codes at full depth; the ladder sweep is follow-up work.
"""

import argparse
import math
import os
import pathlib
import sys
import time

import numpy as np
import soundfile as sf
import torch

import dac
from dac.model.base import DACFile
from audiotools import AudioSignal
from audiotools.metrics.spectral import MelSpectrogramLoss, MultiScaleSTFTLoss

LISTEN_DB = -16.0  # common loudness for A/B pairs; leaves peak headroom

REPO = pathlib.Path(__file__).resolve().parents[1]
MUSIC = pathlib.Path(os.path.expanduser("~/Desktop/Music"))
RECON = REPO / "experiments" / "recon"

TRACKS = [
    "15928052_Liverpool Street In The Rain_(Original Mix).flac",
    "17574893_Good Lies_(Original Mix).flac",
    "506206_Night_(Original Mix).aiff",
]


def load_signal(path):
    """Native-rate float32 AudioSignal, channels preserved."""
    data, sr = sf.read(str(path), dtype="float32", always_2d=True)  # (T, C)
    x = torch.from_numpy(data.T).unsqueeze(0)  # (1, C, T)
    return AudioSignal(x, sr)


def packed_token_bytes(dac_file, codebook_size):
    """Size of the token stream packed at its true bit width (what a real
    .bee base section would store), not the uint16 the .dac artifact uses."""
    bits_per_code = math.log2(codebook_size)
    assert bits_per_code == int(bits_per_code), codebook_size
    n = dac_file.codes.numel()  # channels-as-batch x codebooks x frames
    return math.ceil(n * int(bits_per_code) / 8)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--model-bitrate", default="16kbps", choices=["8kbps", "16kbps"])
    ap.add_argument("--device", default="mps")
    ap.add_argument("--win", type=float, default=10.0, help="compress window (s)")
    args = ap.parse_args()

    RECON.mkdir(exist_ok=True)

    print(f"downloading/locating DAC 44khz {args.model_bitrate} weights ...")
    model_path = dac.utils.download(model_type="44khz", model_bitrate=args.model_bitrate)
    model = dac.DAC.load(str(model_path))
    device = args.device
    try:
        model.to(device)
    except Exception as e:  # MPS op gap etc. — fall back, loudly
        print(f"  {device} unavailable ({e}); falling back to cpu")
        device = "cpu"
        model.to(device)
    model.eval()
    codebook_size = model.quantizer.quantizers[0].codebook_size
    n_codebooks = model.n_codebooks
    print(f"  model: {n_codebooks} codebooks x {codebook_size} entries, "
          f"hop {model.hop_length}, device {device}\n")

    mel_loss = MelSpectrogramLoss()
    stft_loss = MultiScaleSTFTLoss()

    rows = []
    for name in TRACKS:
        src_path = MUSIC / name
        stem = src_path.stem
        print(f"== {stem}")
        sig = load_signal(src_path)
        dur = sig.signal_duration

        dac_path = RECON / f"{stem}.dac"
        if dac_path.exists():
            df = DACFile.load(dac_path)
            t_enc = 0.0
            print("   reusing saved tokens:", dac_path.name)
        else:
            t0 = time.time()
            with torch.no_grad():
                df = model.compress(sig, win_duration=args.win, verbose=True)
            t_enc = time.time() - t0
            df.save(dac_path)

        t0 = time.time()
        with torch.no_grad():
            recon = model.decompress(df, verbose=True)
        t_dec = time.time() - t0

        # level-matched listening pair: both at LISTEN_DB LUFS, PCM_24.
        recon = recon.to("cpu")
        listen_src = sig.clone().to("cpu")
        recon.normalize(LISTEN_DB)
        listen_src.normalize(LISTEN_DB)
        peak = max(float(recon.audio_data.abs().max()),
                   float(listen_src.audio_data.abs().max()))
        if peak > 0.99:  # keep LUFS parity: same trim on both sides
            recon.audio_data = recon.audio_data * (0.99 / peak)
            listen_src.audio_data = listen_src.audio_data * (0.99 / peak)

        wav_path = RECON / f"{stem}.dac-{args.model_bitrate}.wav"
        src_copy_path = RECON / f"{stem}.source.wav"
        sf.write(str(wav_path), recon.audio_data[0].T.numpy(),
                 recon.sample_rate, subtype="PCM_24")
        sf.write(str(src_copy_path), listen_src.audio_data[0].T.numpy(),
                 listen_src.sample_rate, subtype="PCM_24")

        # spectral distances on the level-matched pair
        with torch.no_grad():
            mel = float(mel_loss(recon, listen_src))
            mstft = float(stft_loss(recon, listen_src))

        src_bytes = src_path.stat().st_size
        bee_path = src_path.with_suffix(".bee")
        bee_bytes = bee_path.stat().st_size if bee_path.exists() else None
        tok_bytes = packed_token_bytes(df, codebook_size)
        kbps = tok_bytes * 8 / dur / 1000

        rows.append((stem, dur, src_bytes, bee_bytes, tok_bytes, kbps, mel, mstft,
                     t_enc, t_dec, wav_path.name))
        print(f"   {dur/60:.2f} min | src {src_bytes/1e6:.1f} MB | "
              f"tokens {tok_bytes/1e6:.2f} MB ({kbps:.1f} kbps stereo) | "
              f"{src_bytes/tok_bytes:.0f}x lighter | "
              f"mel {mel:.3f} msSTFT {mstft:.3f} | "
              f"enc {t_enc:.0f}s dec {t_dec:.0f}s\n")

    print("\n== exp5 summary (model: DAC 44khz", args.model_bitrate,
          f"| {n_codebooks} codebooks, full depth) ==")
    print(f"{'track':34s} {'min':>5s} {'src MB':>7s} {'bee MB':>7s} "
          f"{'tok MB':>7s} {'kbps':>6s} {'ratio':>6s} {'mel':>6s} {'msSTFT':>7s}")
    for (stem, dur, src_b, bee_b, tok_b, kbps, mel, mstft, te, td, wav) in rows:
        bee_s = f"{bee_b/1e6:7.1f}" if bee_b else "      -"
        print(f"{stem[:34]:34s} {dur/60:5.2f} {src_b/1e6:7.1f} {bee_s} "
              f"{tok_b/1e6:7.2f} {kbps:6.1f} {src_b/tok_b:5.0f}x {mel:6.3f} {mstft:7.3f}")
    print(f"\nlistening pairs (the actual gate) in {RECON}/ — both files of a "
          f"pair are at {LISTEN_DB} LUFS, PCM_24; A/B them at one volume:")
    for (stem, *_, wav) in rows:
        print(f"  {wav}  vs  {stem}.source.wav")
    print("\nHONESTY: mel/msSTFT are relative references, not transparency "
          "claims. The gate is your ears (then ABX/ViSQOL before any public "
          "quality claim). Sizes are real packed-token sizes.")


if __name__ == "__main__":
    main()
