# Measurements

Numbers about this engine and about rooms come from here and nowhere else.

Every run writes a dated JSON file into this directory carrying the number *and
the conditions it was taken under*. Prose — docs, commit messages, `Spatial.swift`
defaults — may quote a number only if that number is in one of these files. A
figure that is not in a run record is not a measurement.

Two tools, plus the gate that must pass before either is worth trusting.

---

## 0. The gate: analysis self-test

```
beehive-cli --measure-selftest
```

Runs the analysis against synthetic input whose answer is known exactly:
convolution scaling against a delta, lag recovery at known integer delays (with
and without noise), sweep ⊛ inverse collapsing to a delta, a synthetic room with
a built-in T60, refusal on a decay that is really noise, and the ring buffer and
xrun detector.

**It measures nothing.** It needs no audio device and touches no hardware. Its
job is to tell you, when a physical measurement later looks wrong, whether the
analysis is broken or the cable, clock or gain is. Run it first; it takes about
a second.

Last run: all checks pass. Recovered T30 on the synthetic room was within 0.2%
of the 0.800 s built into it, and sweep ⊛ inverse came out 28.6 dB down off-peak.

---

## 1. Round-trip latency

### Physical setup

| | |
|---|---|
| Cable | Short 1/4" TS, **interface output 1 → interface input 1** |
| Output level | Unity. No processing, no EQ, no limiter anywhere in the path |
| Input gain | Set so the captured peak sits near **−12 dBFS**. The tool warns above −1 dBFS (clipping) and below −40 dBFS (SNR) |
| Devices | **Input and output must be the same device.** See the clock note below |

### Run

```
beehive-cli --measure-latency                          # 20 repeats, buffers 64…1024
beehive-cli --measure-latency --repeats 40 --chirp     # if the impulse is too low-SNR
beehive-cli --measure-latency --buffers 256            # one size only
```

### The clock note

The tool **refuses to run** if the default input and output are different
devices. Two devices means two free-running clocks, and a lag measured across
them drifts between repeats — which shows up as a believable standard deviation
rather than as an error. Fix it by selecting one interface for both directions,
or in Audio MIDI Setup: **+ → Create Aggregate Device**, tick both, set one as
clock source, then select the aggregate as system input and output.

There is a diagnostics-only escape hatch, `--allow-clock-mismatch`, which runs
the rig on mismatched clocks to prove the plumbing executes. It prints a warning,
and **writes nothing** — no run record is ever created from a mismatched-clock
run. It is not a way to take a measurement without the cable.

### What it reports, and why three numbers

```
total round trip
  − device-reported offset   (kAudioDevicePropertyLatency + kAudioDevicePropertySafetyOffset
                              + stream latency, queried on both input and output)
  = residual                 ← this engine's own render latency
```

Only the residual belongs to our code. The rest is the device, and quoting the
total as "our latency" would overstate it by whatever the interface costs.

Alignment is exact, not inferred: each side stamps the host's `mSampleTime` for
its own frame 0 from inside its own audio callback (`bm_emit_begin`,
`bm_capture_begin`), so the round trip is the correlation lag plus a known clock
offset. Doing the reset from the control thread instead would leave a ±1-buffer
ambiguity — at 64 frames that is 1.3 ms of invented precision.

**Any run with an xrun or a ring overrun is discarded, never averaged in.** The
discard count is printed and recorded.

---

## 2. Impulse response

### Run the loopback validation FIRST

```
beehive-cli --measure-ir --loopback --duration 10 --label loopback-check
```

With the same cable patched as above, the IR **must** collapse to a near-delta:
off-peak energy more than 20 dB below the direct peak. The tool asserts this and
exits non-zero if it fails. A chain that cannot reproduce a delta cannot measure
a room, and a room measured through a dirty chain is invalid — that failure is
the point of running this first.

### Then the room

```
beehive-cli --measure-ir --duration 10 --mic "<mic model>" --label "<position>"
```

Exponential sine sweep (Farina), 20 Hz – 20 kHz over 10 s by default,
deconvolved with the analytically-derived inverse filter — the time-reversed
sweep with a −6 dB/oct amplitude correction, which pushes harmonic distortion
products ahead of the linear response where they are cut away.

### Output

- `<date>-ir-<label>.wav` — the impulse response, 32-bit float, at the device rate
- `<date>-ir-<label>.json` — sample rate, timestamp, device, buffer size, OS,
  sweep parameters, gain/peak, mic identifier, xrun counts, and the metrics

### Metrics, and when they refuse to exist

T20 and T30 by Schroeder backward integration; C50, D50, and
direct-to-reverberant ratio. The report always names the **noise floor** and the
**truncation point** used for the integration.

A decay time is reported as `unavailable`, with the reason, rather than
estimated, when any of these fails:

- fewer than 25 dB (T20) or 35 dB (T30) usable — the smaller of the Schroeder
  curve's range and the peak-to-noise ratio
- the fit segment is shorter than 20 ms or 16 samples — a step, not a decay
- the fit is not straight (r² < 0.95) — ISO 3382 non-linearity

That last one is what catches a clean direct arrival sitting on flat noise: it
has a large peak-to-noise ratio and a steep-looking curve, and a naive fit
returns a confident reverberation time for a room that was never measured.

---

## Reproducing a number

Each JSON file is self-describing: device, sample rate, buffer size, OS, stimulus,
repeat count, discard count. To reproduce, match those conditions and re-run the
same command. Two run records taken under the same conditions are directly
diffable; two taken under different ones are not comparable and the fields say so.

## Status

- Analysis self-test: **passing** (see §0).
- Round-trip latency: **not yet measured** — needs the loopback cable patched.
- Room IR: **not yet measured** — needs §2's loopback validation to pass first.

Until the first two land here, `Spatial.swift` carries no latency constant.
