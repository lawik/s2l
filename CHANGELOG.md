# Changelog

## v0.1.0

Initial release.

### Analysis

- `S2l.Aubio` — beat, onset and spectral-band analysis through a NIF around
  [aubio](https://aubio.org), fed one hop of `f32le` mono at a time. Reports
  beats, tempo with a confidence, onsets, mel-spaced band energies, and the
  dominant frequency interpolated between FFT bins.
- The sample rate comes from the caller rather than being assumed, and the mel
  bands cover a configurable frequency range defaulting to 40 Hz - 12 kHz.
- aubio is downloaded from a pinned release, checksummed and compiled from
  source as part of the build, then linked statically. No system libaubio is
  needed and the resulting NIF depends only on libc and libm, which is what
  lets it cross-compile for a device.

### Colour

- `S2l.ColorMapper` — a plain `GenServer` with no framework dependencies that
  turns jittery, unbounded analysis into bounded frames on a fixed clock.
  Automatic gain, asymmetric attack and decay, beat spikes, per-band peak hold,
  a history buffer for waterfall displays, and a hue that adapts to the range
  the current material actually occupies. Every constant is adjustable at
  runtime.
- `S2l.Palette` — position in, RGB out, interpolating between stops. Eight
  built-in palettes, and custom stop lists anywhere a name is accepted.
- `S2l.Strip` — fits a frame onto any number of LEDs, interpolating when there
  are more LEDs than bands and aggregating when there are fewer, so no band is
  silently dropped in either direction.

### Audio input

- `S2l.Membrane.Analyzer` — a Membrane sink that runs the analysis over a
  stream, buffering partial hops so source buffer sizes need not align.

### Examples

- `examples/mic_analysis.exs` — microphone to a terminal meter.
- `examples/virtual_led.exs` — microphone to a browser LED strip with a
  graphic equalizer, peak-hold caps, a waterfall and switchable palettes,
  built with [Phoenix Playground](https://hex.pm/packages/phoenix_playground).
