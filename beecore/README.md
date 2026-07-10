# beecore — the `.bee` portable native core

The production implementation of the `.bee` v0 two-layer audio container
(BEE_FORMAT_BLUEPRINT.md §3), built to run natively on **iOS, Android, macOS,
Windows, Linux** from one pure-Rust codebase (no C dependencies).

**Python stays the reference.** `beehive/beefile.py` is the single source of
truth for the format definition (blueprint §4c). This core's acceptance bar is
cross-implementation bit-exactness against it, both directions — enforced by
`interop/test_interop.py`.

## Layout

```
crates/bee-format   the core: container, codecs, npy/npz side-channel, `bee` CLI
crates/bee-ffi      C ABI (staticlib + cdylib) + include/bee.h
interop/            cross-implementation acceptance vs the Python reference
                    (test_interop.py) and the C ABI smoke test (smoke.c)
```

Deps (all pure Rust, cross-compile everywhere): `serde_json`, `miniz_oxide`
(zlib), `claxon` (FLAC decode), `flacenc` (FLAC encode), `crc32fast`.
The npy/npz subset numpy writes is implemented in `bee-format/src/npz.rs`
directly — no zip dependency.

## What v0 is (and what stays OPEN)

* **Layer 1 (audio payload)** — lossless on the decoded PCM arrays: FLAC for
  PCM_16/PCM_24 sources, raw+zlib otherwise. These are the deliberate
  **placeholders for blueprint §4(a)**, which remains OPEN (real
  predictive+entropy coding not decided). The `codec` manifest field is the
  slot where a real coder plugs in.
* **Layer 2 (helix side-channel)** — `A, I, chroma, engagement` (float32 npz)
  plus meta JSON, carried **verbatim**. It does not reconstruct audio
  (exp3: chroma is many-to-one in timbre); geometry is re-derived by the
  engine, not here.
* §4(b) (exact vs. near-duplicate loop dedup) and the bar/loop pool
  (§6 steps 2–4) are **not** in this crate — still Python-reference territory.

## Test status (2026-07-05)

* `cargo test --release` — 9/9 round-trip + malformed-input tests.
* `.venv/bin/python beecore/interop/test_interop.py` — **24/24**: for
  PCM_16 stereo (flac), PCM_24 mono (flac), float32 stereo (raw_zlib):
  Python-written `.bee` → Rust decode is sha256-identical PCM; Rust-written
  `.bee` → Python `read_bee` is bit-identical PCM **and** bit-identical
  Layer-2 arrays + meta.
* `interop/smoke.c` — 12/12 through the C ABI (open, meta, PCM, helix fields,
  write, reopen, PCM memcmp-identical), statically linked.

## Building for each platform

Host build + tests: `cargo build --release && cargo test --release`
(Homebrew rust works for the host).

Cross-targets use the rustup toolchain (installed user-local, no PATH
changes: `~/.cargo/bin`):

```sh
export PATH="$HOME/.cargo/bin:$PATH"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim \
                  aarch64-linux-android x86_64-pc-windows-msvc
cargo rustc -p bee-ffi --release --target <target> --crate-type staticlib
```

All four artifacts build from this machine (verified 2026-07-05):
`target/<target>/release/libbee_ffi.a` (`bee_ffi.lib` on Windows).

Packaging into app projects (needs the platform SDKs, not done here):

* **iOS/macOS**: wrap the device + simulator `.a` and `include/bee.h` in an
  `xcframework` (`xcodebuild -create-xcframework`), import from Swift via a
  module map. `BeehiveMac` remains the consumer — it links this, it does not
  reimplement the codec.
* **Android**: build the `cdylib` with the NDK linker
  (`cargo ndk -t arm64-v8a build --release`, needs `cargo-ndk` + NDK), load
  with `System.loadLibrary`, bind over JNI (or wrap `bee.h` with jextract-style
  bindings).
* **Windows**: link `bee_ffi.lib` (or build the cdylib `.dll`) and P/Invoke or
  `#include "bee.h"`.

## CLI

```
bee info <file.bee>
bee decode <file.bee> --pcm-out raw.bin [--audio-meta-out am.json]
bee extract-helix <file.bee> --npz-out h.npz --meta-out hm.json
bee encode --pcm raw.bin --audio-meta am.json \
           --helix-npz h.npz --helix-meta hm.json --out file.bee
```

Raw PCM files are little-endian interleaved samples (`ndarray.tobytes()` on a
little-endian host).
