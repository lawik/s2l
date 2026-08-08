# Examples

Two self-contained scripts. Both use `Mix.install/1` with a path dependency on
this project, so there is nothing to set up — run them directly.

```sh
elixir examples/mic_analysis.exs   # terminal meter
elixir examples/virtual_led.exs    # browser LED strip on localhost:4000
```

The first run takes a while: it fetches Membrane and compiles PortAudio's
native bindings. Later runs start quickly.

## Requirements

PortAudio, which `membrane_portaudio_plugin` links against:

```sh
brew install portaudio          # macOS
apt install portaudio19-dev     # Debian/Ubuntu
```

On macOS the terminal needs microphone permission. The first run should prompt;
if it does not, add your terminal under System Settings → Privacy & Security →
Microphone. A pipeline that starts but reports pure silence is almost always
this.

Turn off any input processing your OS applies — noise suppression and automatic
gain both flatten exactly the transients beat detection depends on.

## `mic_analysis.exs`

Microphone into the analyzer, results onto one refreshing terminal line: a
level meter, a beat marker, the tempo estimate and running counts.

No Phoenix and no colour mapping — this is the script to reach for when
something looks wrong, because there is almost nothing between the microphone
and what you are reading. Expect onsets immediately and the tempo to settle
within a few seconds of steady music.

## `virtual_led.exs`

The same pipeline, feeding `S2l.ColorMapper`, rendered by a
[Phoenix Playground](https://hex.pm/packages/phoenix_playground) LiveView as a
virtual LED strip over a background wash.

On the page:

* **Graphic equalizer** with **peak-hold caps**. Position along the strip *is*
  frequency, colour comes from position, brightness is that band's energy.
  Colour is never averaged, which is what gives the top end a colour of its own.
  The caps sit at each band's recent maximum and fall steadily.
* **Waterfall** underneath, scrolling downward — the last few seconds of
  spectrum, built from `S2l.ColorMapper.history/1`. Because history lives in
  the mapper rather than the view, opening a tab mid-song draws a full
  waterfall immediately instead of an empty one that fills in.
* **Palettes**, switchable live. See `S2l.Palette`.
* **Colour by**, switchable live, which is the interesting comparison:
  * `position` — the GEQ mapping described above.
  * `pitch` — the whole strip takes its colour from the dominant frequency, so
    colour follows the melody rather than the spectrum. This is what WLED's
    Freqmap and Freqwave effects do.
  * `level` — colour follows loudness alone, ignoring frequency. Included
    mostly to show how much less it tells you.

The background wash is the averaged-hue approach — one colour for the whole
mix. Useful as a backdrop, but on its own it cannot distinguish a cymbal from a
bass note, because a spectral average over broadband audio barely moves.

The point of this one is what it *doesn't* do. There is no analysis and no
colour logic in the script: it subscribes to frames and turns them into CSS.
Everything that decides colour lives in `S2l.ColorMapper`, which has no
knowledge of Phoenix, so the tuning you do here against a browser is the same
tuning that will drive real LEDs. Kill the browser tab and the frames keep
coming — the LiveView is the disposable half.

Two ways to iterate without restarting:

* Edit the script and refresh. Phoenix Playground re-evaluates the file on every
  request, so changes to the LiveView — LED count, layout, CSS — show up
  immediately. That is also why the startup calls at the bottom are written to
  tolerate already having run.
* Adjust the colour mapping from an attached IEx session, which is where the
  decisions worth iterating on actually live:

  ```elixir
  S2l.ColorMapper.configure(decay: 0.05, beat_boost: 0.8, hue_range: {200.0, 360.0})
  ```

## Wiring

Both scripts ask PortAudio for `f32le` mono directly, which is what the
analyzer wants, so there is no resampling stage:

```
PortAudio.Source (f32le, mono) → S2l.Membrane.Analyzer → handler
```

Neither script pins a sample rate. The device's own rate travels through the
stream format into `S2l.Aubio.create/2`, which is what keeps the tempo estimate
honest on a 48 kHz device — hardcoding 44.1 kHz there would skew it by about
9% without any visible error.

If a device refuses `f32le` mono, put
[`membrane_ffmpeg_swresample_plugin`](https://hex.pm/packages/membrane_ffmpeg_swresample_plugin)'s
`Converter` between the source and the analyzer and let PortAudio produce
whatever it prefers.
