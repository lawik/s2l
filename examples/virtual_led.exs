# Mic in, virtual LED strip out, in the browser.
#
#   elixir examples/virtual_led.exs
#
# Opens http://localhost:4000 with a graphic equalizer, peak-hold caps, a
# scrolling waterfall, and switchable palettes, all driven by the microphone.
#
# The interesting part is what this file *does not* contain: no analysis, no
# smoothing, no colour decisions. Those all live in `S2l.ColorMapper` and
# `S2l.Palette`, neither of which knows anything about Phoenix. This script is
# the disposable half — the same frames it renders as div backgrounds are what
# will drive real LEDs, so tuning done here against a browser is not thrown
# away.

Mix.install([
  {:s2l, path: Path.expand("..", __DIR__)},
  {:membrane_portaudio_plugin, "~> 0.19"},
  {:phoenix_playground, "~> 0.1"}
])

# Membrane's per-buffer debug chatter drowns out anything worth reading.
Logger.configure(level: :info)

defmodule VirtualLed.Pipeline do
  @moduledoc """
  Microphone into the analyzer, analyzer into the colour mapper.

  PortAudio is asked for `f32le` mono, which is what the analyzer wants, so no
  resampling stage is needed. The sample rate deliberately is not pinned: it
  comes from the device via the stream format.
  """

  use Membrane.Pipeline

  @impl true
  def handle_init(_ctx, _opts) do
    spec =
      child(:mic, %Membrane.PortAudio.Source{
        sample_format: :f32le,
        channels: 1,
        latency: :low
      })
      |> child(:analyzer, %S2l.Membrane.Analyzer{handler: &S2l.ColorMapper.push/1})

    {[spec: spec], %{}}
  end
end

defmodule VirtualLed.Live do
  use Phoenix.LiveView

  alias S2l.ColorMapper
  alias S2l.Palette

  @leds 48
  @waterfall_rows 40
  @waterfall_cols 32

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: ColorMapper.subscribe()

    # The first, disconnected render has no subscription yet, so it derives
    # what it can from the mapper directly. History means a tab opened
    # mid-song draws a full waterfall immediately instead of an empty one that
    # fills in over the next few seconds.
    frame = ColorMapper.frame()

    {:ok,
     socket
     |> assign(palette: :rainbow, mode: :spectrum, frame: frame)
     # Counts travel as assigns because inside ~H a module attribute name is
     # read as an assign, so @leds in the template would be the list, not 48.
     |> assign(bar_count: @leds, col_count: @waterfall_cols)
     |> assign(bars: spread(frame.bands, @leds), caps: spread(frame.peaks, @leds))
     |> assign(rows: Enum.take(ColorMapper.history(), @waterfall_rows))}
  end

  @impl true
  def handle_info({:s2l_frame, frame}, socket) do
    rows = [frame | socket.assigns.rows] |> Enum.take(@waterfall_rows)

    {:noreply,
     socket
     |> assign(frame: frame, rows: rows)
     |> assign(bars: spread(frame.bands, @leds), caps: spread(frame.peaks, @leds))}
  end

  @impl true
  def handle_event("palette", %{"name" => name}, socket) do
    {:noreply, assign(socket, palette: String.to_existing_atom(name))}
  end

  def handle_event("mode", %{"name" => name}, socket) do
    {:noreply, assign(socket, mode: String.to_existing_atom(name))}
  end

  # Stretches however many analysis bands there are across however many LEDs
  # are being drawn, so the strip length and the band count stay independent.
  # This is the same mapping a real strip will need.
  defp spread([], count), do: List.duplicate(0.0, count)

  defp spread(values, count) do
    source = List.to_tuple(values)
    size = tuple_size(source)

    Enum.map(0..(count - 1), fn index ->
      elem(source, min(div(index * size, count), size - 1))
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      * { box-sizing: border-box; }
      body { margin: 0; background: #05060a; overflow: hidden;
             font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
      .stage { height: 100vh; display: flex; flex-direction: column;
               transition: background-color 60ms linear; }
      .controls { display: flex; gap: 1.5rem; padding: 1rem 4vw 0; flex-wrap: wrap;
                  align-items: center; }
      .group { display: flex; gap: 4px; align-items: center; }
      .group b { color: rgba(255,255,255,.35); font-weight: 400; font-size: 11px;
                 letter-spacing: .18em; margin-right: .4rem; }
      button { background: rgba(255,255,255,.06); color: rgba(255,255,255,.7);
               border: 1px solid rgba(255,255,255,.12); border-radius: 5px;
               padding: 5px 11px; font: inherit; font-size: 11px; cursor: pointer;
               letter-spacing: .1em; }
      button.on { background: rgba(255,255,255,.92); color: #05060a; border-color: transparent; }
      .middle { flex: 1; display: flex; flex-direction: column; justify-content: center;
                gap: 2.5rem; padding: 0 4vw; }
      .strip { display: flex; gap: 4px; height: 32vh; align-items: flex-end; }
      .bar { flex: 1; position: relative; height: 100%; }
      .fill { position: absolute; bottom: 0; width: 100%; border-radius: 3px;
              transition: height 60ms linear, background-color 60ms linear; }
      .cap { position: absolute; width: 100%; height: 3px; border-radius: 2px;
             transition: bottom 90ms linear; }
      .waterfall { display: flex; flex-direction: column; gap: 1px; height: 22vh; }
      .row { display: flex; gap: 1px; flex: 1; }
      .cell { flex: 1; border-radius: 1px; }
      .readout { display: flex; gap: 2rem; padding: 0 4vw 1.2rem;
                 color: rgba(255,255,255,.55); font-size: 12px; letter-spacing: .16em; }
      .beat { color: #fff; font-weight: 700; }
    </style>

    <div class="stage" style={"background-color: #{wash(@frame, @palette, @mode)}"}>
      <div class="controls">
        <div class="group">
          <b>PALETTE</b>
          <button :for={name <- Palette.names()} phx-click="palette" phx-value-name={name}
                  class={if name == @palette, do: "on"}>{name}</button>
        </div>
        <div class="group">
          <b>COLOUR BY</b>
          <button :for={{name, label} <- [spectrum: "position", pitch: "pitch", level: "level"]}
                  phx-click="mode" phx-value-name={name}
                  class={if name == @mode, do: "on"}>{label}</button>
        </div>
      </div>

      <div class="middle">
        <div class="strip">
          <div :for={{level, i} <- Enum.with_index(@bars)} class="bar">
            <div class="fill"
                 style={"height: #{round(level * 100)}%; background-color: #{led(@frame, @palette, @mode, level, i, @bar_count)}"}>
            </div>
            <div class="cap"
                 style={"bottom: calc(#{round(Enum.at(@caps, i, 0.0) * 100)}% - 1px); background-color: #{cap(@frame, @palette, @mode, i, @bar_count)}"}>
            </div>
          </div>
        </div>

        <div class="waterfall">
          <div :for={row <- @rows} class="row">
            <div :for={{level, i} <- Enum.with_index(spread(row.bands, @col_count))} class="cell"
                 style={"background-color: #{Palette.hex(Palette.at(@palette, position(row, @mode, i, @col_count), brightness: level))}"}>
            </div>
          </div>
        </div>
      </div>

      <div class="readout">
        <span class={if @frame.beat, do: "beat"}>{if @frame.beat, do: "BEAT", else: "····"}</span>
        <span>BPM {:erlang.float_to_binary(@frame.bpm, decimals: 1)}</span>
        <span>PEAK {round(@frame.peak_freq)} Hz</span>
        <span>PITCH {:erlang.float_to_binary(@frame.pitch, decimals: 2)}</span>
        <span>LEVEL {:erlang.float_to_binary(@frame.level, decimals: 2)}</span>
      </div>
    </div>
    """
  end

  # Where in the palette a given bar sits. This is the whole difference between
  # the three modes, and worth understanding before tuning anything:
  #
  #   :spectrum — position along the strip *is* frequency, so the top end always
  #     has a colour of its own. The graphic-equalizer mapping WLED and friends
  #     use, and the only one of the three that can distinguish a cymbal from a
  #     bass note at a glance.
  #   :pitch — the whole strip takes its colour from the dominant frequency, so
  #     colour tracks the melody instead of the spectrum.
  #   :level — colour follows loudness, ignoring frequency entirely.
  defp position(frame, mode, index, count)
  defp position(_frame, :spectrum, index, count), do: index / max(count - 1, 1)
  defp position(frame, :pitch, _index, _count), do: frame.pitch
  defp position(frame, :level, _index, _count), do: frame.level

  defp led(frame, palette, mode, level, index, count) do
    # Brightness is that band's own energy, lifted by the overall level so the
    # strip breathes rather than just twitching.
    brightness = 0.25 + 0.75 * level * (0.4 + 0.6 * frame.level)

    palette
    |> Palette.at(position(frame, mode, index, count), brightness: brightness)
    |> Palette.hex()
  end

  defp cap(frame, palette, mode, index, count) do
    palette
    |> Palette.at(position(frame, mode, index, count), brightness: 1.0)
    |> Palette.hex()
  end

  # One colour for the whole mix, kept dark so it cannot drown the strip. This
  # is the averaged-hue approach: useful as a backdrop, but on its own it
  # cannot tell a cymbal from a bass note, because a spectral average over
  # broadband audio barely moves.
  defp wash(frame, palette, mode) do
    palette
    |> Palette.at(position(frame, mode, 0, 1) * 0.5 + frame.centroid * 0.5,
      brightness: 0.05 + frame.level * 0.12
    )
    |> Palette.hex()
  end
end

# Phoenix Playground re-evaluates this entire file on every request so that
# edits show up on refresh, which means everything below runs again each time.
# Both starts therefore have to tolerate already being started: without the
# guards the second request is a 500, and a second pipeline would sit there
# fighting the first one for the microphone.
case S2l.ColorMapper.start_link() do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

# The web server goes up before the pipeline deliberately. On macOS the first
# run blocks inside PortAudio waiting on a microphone permission prompt, and a
# page rendering black is a far better symptom than a terminal that hangs with
# nothing to look at.
PhoenixPlayground.start(live: VirtualLed.Live)

if is_nil(Process.whereis(VirtualLed.Pipeline)) do
  {:ok, _supervisor, _pipeline} =
    Membrane.Pipeline.start_link(VirtualLed.Pipeline, nil, name: VirtualLed.Pipeline)
end
