# S2L - Sound 2 Light

NIF and Membrane Element for turning sound samples into RGB values suited for reactivity to music.

## Requirements

A C compiler, `make`, `tar`, and `curl` or `wget`. There is nothing to install
first — [aubio](https://aubio.org) is downloaded, checksummed and compiled from
source as part of `mix compile`, then linked statically into the NIF.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `s2l` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:s2l, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/s2l>.

## Usage

Feed the analyzer one hop of `f32le` mono at a time, in order:

```elixir
{:ok, analyzer} = S2l.Aubio.create(44_100)

{:ok, analysis} = S2l.Aubio.process(analyzer, frame)
#=> %{beat: false, bpm: 120.1, confidence: 1.4, onset: true, bands: [...]}
```

`S2l.Aubio.frame_size/1` gives the exact byte size each call expects. Pass the
stream's real sample rate to `create/2`; analyzing 48 kHz audio as 44.1 kHz
reports a tempo about 9% off rather than failing.

Two modules turn that into colour, neither of which depends on a framework, so
both carry to a device unchanged:

* `S2l.ColorMapper` — smooths analysis into paced frames carrying level, hue,
  spectral centroid, dominant pitch, per-band levels, peak-hold caps and a
  history buffer for waterfall displays.
* `S2l.Palette` — position in, RGB out, with built-in palettes and support for
  your own.
* `S2l.Strip` — fits a frame onto however many LEDs you have, and turns it into
  a list of `{r, g, b}`. Band count and LED count are unrelated, so something
  has to interpolate going up and aggregate going down; this is that something.

`S2l.Membrane.Analyzer` is the Membrane sink that drives the whole thing from
an audio stream. See `examples/` for both wired up.

## Native build

The NIF is built with [elixir_make](https://hex.pm/packages/elixir_make):
`mix compile` runs the `Makefile`, which fetches the pinned aubio release,
verifies its SHA-256, compiles it into a static archive and links that into
`_build/$MIX_ENV/lib/s2l/priv`. Nothing is generated, so
`c_src/s2l_aubio_nif.c` is the whole binding. The resulting `.so` depends only
on libc and libm — there is no libaubio to install or ship.

Only aubio's DSP sources are compiled. Its `io/` layer (libsndfile, ffmpeg,
CoreAudio) and `synth/sampler` are excluded, and no external FFT backend is
enabled, so aubio uses its bundled ooura implementation. aubio's own `waf`
build is bypassed entirely — the `HAVE_*` macros it would write into a
`config.h` are passed on the command line instead, which is what removes Python
from the build requirements.

### Cross-compiling (Nerves)

Because aubio is built from source with the same compiler as the NIF, a
cross-build is just a matter of pointing the toolchain at it. The Makefile
honours `CC`, `AR`, `CFLAGS`, `LDFLAGS` and `CROSS_COMPILE`, and resolves `CC`
and `AR` from `CROSS_COMPILE` when the caller has not set them.

For builds without network access, supply the source directly:

```sh
AUBIO_TARBALL=/path/to/aubio-0.4.9.tar.bz2 mix compile   # local tarball
AUBIO_SOURCE_DIR=/path/to/aubio-0.4.9 mix compile        # extracted tree
```

The download is cached under `_build`, so it happens once. Two mirrors are
tried in order, each pinned to its own checksum.

### Verifying the DSP without the BEAM

`make verify` builds and runs `c_src/verify.c`, a standalone C program that
drives the same aubio call sequence over a synthesized 120 BPM click track and
exits non-zero if the analysis misses its thresholds.

It shares those thresholds, and its exact input signal, with the ExUnit anchor
test in `test/s2l/aubio_test.exs`. When both agree the binding is faithful; when
`make verify` passes and `mix test` does not, the fault is in the Elixir/C glue
rather than the audio analysis.

## License

GPL-3.0-or-later, in full in [LICENSE.md](LICENSE.md).

This follows from aubio, which is GPL-3.0-or-later and is compiled into the NIF
as described above. Anything built on this library inherits the same terms.
