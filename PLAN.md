# Sound-Reactive LEDs — Proof of Concept Plan

**Goal:** Get the audio-to-LED logic good on the host, with no hardware. A LiveView fullscreen div stands in for the LED strip as a fast tuning loop. The end state is the same analysis core on a Nerves device driving LEDs through fledex — no Phoenix on the device.

**Context / knowns:** Membrane + PortAudio on Nerves is proven ground. Writing Membrane elements is routine. The **only genuine uncertainty is the aubio NIF module** — so the plan front-loads it and treats everything else as assembly.

**Structural rule:** everything that decides color lives in plain OTP modules with zero Phoenix dependencies. The LiveView is a disposable shell.

---

## 1. Architecture

```
PORTABLE CORE (plain OTP — ships to Nerves later)
┌────────────────────────────────────────────┐
│ Membrane Pipeline                          │
│  PortAudio.Source (OS mic)                 │
│    → SWResample.Converter (f32le, mono)    │
│    → HopChunker (512-sample frames)        │
│    → AubioAnalyzer (Unifex NIF)  ◄── the risk
│    → AnalysisSink                          │
│                                            │
│ ColorMapper (GenServer)                    │
│  analysis → {hue, level, beat}             │
│  smoothing / decay / beat-spike state      │
│  broadcasts frames at 30 Hz                │
└──────────────────┬─────────────────────────┘
                   │ subscribe
DEV HARNESS (host, disposable)               LATER (Nerves)
┌──────────────────▼───────────┐             ┌──────────────────────┐
│ LiveView: fullscreen div     │             │ fledex animation     │
│ background from color frames │             │ loop → LED strip     │
└──────────────────────────────┘             └──────────────────────┘
```

Formats locked up front: f32le mono for analysis (aubio's native `smpl_t`, zero-copy in the NIF), window 1024, hop 512. Sample rate is read from the stream format, never hardcoded — a 48k/44.1k mismatch silently skews BPM ~9%.

---

## 2. Milestones

### Milestone 1 — The aubio NIF (the whole point)

Built and validated in isolation, before any pipeline exists.

**Interface** (Unifex spec):
- `create(sample_rate, buf_size, hop_size, n_bands, onset_method)` → resource
  holding `aubio_tempo`, `aubio_onset`, `aubio_pvoc` + `aubio_filterbank`
  (mel coefficients, `n_bands` ≈ 16), plus preallocated output vectors.
- `process(resource, samples)` → `{beat?, bpm, onset?, bands :: [float]}`.
  One hop of f32le mono per call; size-checked, errors as tuples, never a crash.
- Destructor frees all aubio objects. Trackers are stateful → one resource per
  stream, hops fed in order.

**Implementation notes**
- Input binary is cast to a stack `fvec_t` view (`{length, data}`) — no copy.
  aubio only reads input vectors, so this is safe.
- `process` is microseconds of work → regular schedulers; `create` allocates →
  call from setup, not per-buffer.
- Onset method exposed as an option (`"hfc"` default for percussion;
  `"energy"`, `"complex"` for tuning later).

**De-risking steps, in order**
1. *C-only spike:* a standalone `verify.c` exercising the exact aubio calls
   against a synthesized 120 BPM click track — compiled with just gcc +
   libaubio-dev. Proves API usage, the zero-copy pattern, and expected
   behavior (tempo tracker needs ~4 s to lock; onsets fire immediately)
   before any Elixir is involved.
2. *Unifex glue:* bundlex native with `os_deps: [aubio: [{:pkg_config, "aubio"}]]`.
   Expected friction points: the generated-header include path in the public
   `.h`, and result-function signatures for the `[float]` return (Unifex floats
   are C doubles; aubio's `smpl_t` is float — small copy at the boundary).
3. *ExUnit anchor test:* the same click track synthesized in pure Elixir
   (no sox dependency), fed hop by hop; assert BPM within ±3, onsets ≥ 15/20,
   beats ≥ 5 (post-lock), bands non-negative and hot on clicks. This test is
   what the rest of the project trusts.
4. *Robustness:* wrong-size frames return `{:error, :bad_frame_size}`; fuzz
   with random-length binaries; GC-stress create/destroy in a loop.

**Exit criteria:** anchor test green; fuzz clean; a documented answer to
"which Unifex/bundlex versions and what did the glue actually require."

### Milestone 2 — Assembly: pipeline on host (known territory)

- `PortAudio.Source → SWResample.Converter (f32le/mono) → HopChunker →
  AubioAnalyzer element → AnalysisSink` broadcasting analysis on PubSub.
- HopChunker re-emits exact hop-sized buffers (source chunk sizes won't align).
- Analyzer element: NIF resource created in `handle_setup` from the incoming
  stream format's sample rate.
- **Exit criteria:** music in the room → `%{beat: true, bpm: ...}` messages in
  IEx landing on real beats (eyeball vs. a metronome app).

### Milestone 3 — ColorMapper + div

- `ColorMapper` GenServer (no Phoenix imports): hue from spectral balance
  (bass-heavy → red, treble → blue), level from total energy with exponential
  decay, brief beat spike; emits `{hue, level, beat?}` frames at a fixed 30 Hz.
  Constants (decay, boost, mapping) runtime-tunable — this module is where all
  the iteration happens, and it's what carries to fledex verbatim.
- LiveView subscribes, patches `background: hsl(...)` on a fullscreen div,
  CSS transition smooths between frames. No logic in the view.
- **Exit criteria:** page pulses on kicks, color tracks the mix, mic-to-pixel
  feels < ~150 ms. Killing the LiveView and watching frames in IEx works
  identically — the shell is disposable.

### Milestone 4 — Tuning

Onset methods and thresholds, band smoothing (fast attack / slow decay),
beat-spike feel, crash recovery (supervisor restart is fine — aubio state
rebuilds in ms).

---

## 3. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Unifex/bundlex glue friction (header paths, result signatures, versions) | Blocks M1 | The C-only spike isolates it: if step 1 passes and step 2 fails, the problem is provably glue, not DSP |
| **aubio cross-compile for the Nerves target** | The big device-side unknown | Early build spike once M1 works: aubio 0.4.9, waf build, only hard dep is libm (falls back to built-in ooura FFT without fftw). Buildroot package or bundlex compile against the Nerves toolchain |
| Sample-rate mismatch | Silent ~9% BPM skew | Rate flows from stream format into `create`; test with a 48 kHz fixture too |
| NIF crash takes down the BEAM | App dies | Size checks + fuzz test in M1 |
| OS input processing (AGC/noise suppression) on host | Muddy beat detection while tuning | Disable enhancements in OS sound settings; document |

---

## 4. Nerves + fledex (deferred, the actual target)

Firmware = portable core + a small consumer translating ColorMapper frames
into fledex animations. Deferred work: the cross-compile spike above, mic
hardware on device, and mapping `{hue, level, beat}` into per-LED spatial
effects in fledex — new creative work, not new architecture.

## 5. Definition of Done

Anchor test proves the NIF objectively (not vibes). Music makes the page
pulse in time. The core boots and emits correct color frames with Phoenix
not started — the audio-to-LED brain is ready to lift onto the device.
