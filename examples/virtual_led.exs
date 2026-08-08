# Mic in, virtual LED strip out, in the browser.
#
#   elixir examples/virtual_led.exs
#
# Opens http://localhost:4000 with a graphic equalizer, peak-hold caps, a
# scrolling waterfall, and switchable palettes, all driven by the microphone.
#
# The interesting part is what this file does *not* contain. There is no
# analysis here, no smoothing, no colour decisions, and no arithmetic mapping
# bands onto pixels. Every one of those lives in the library — `S2l.ColorMapper`
# and `S2l.Strip` — and none of them knows Phoenix exists. What is left below is
# a pipeline definition, some CSS, and a loop turning `{r, g, b}` into style
# attributes.
#
# That is the point: driving real LEDs with fledex means keeping the calls to
# `S2l.Strip` and throwing this file away.

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
  alias S2l.Strip

  @leds 48
  @waterfall_rows 40
  @waterfall_cols 32

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: ColorMapper.subscribe()

    # History means a tab opened mid-song draws a full waterfall immediately
    # rather than an empty one that fills in over the next few seconds.
    {:ok,
     socket
     |> assign(palette: :rainbow, color_by: :position)
     |> paint(ColorMapper.frame(), Enum.take(ColorMapper.history(), @waterfall_rows))}
  end

  @impl true
  def handle_info({:s2l_frame, frame}, socket) do
    rows = Enum.take([frame | socket.assigns.rows], @waterfall_rows)

    {:noreply, paint(socket, frame, rows)}
  end

  @impl true
  def handle_event("palette", %{"name" => name}, socket) do
    socket = assign(socket, palette: String.to_existing_atom(name))

    {:noreply, paint(socket, socket.assigns.frame, socket.assigns.rows)}
  end

  def handle_event("color_by", %{"name" => name}, socket) do
    socket = assign(socket, color_by: String.to_existing_atom(name))

    {:noreply, paint(socket, socket.assigns.frame, socket.assigns.rows)}
  end

  # The only place this file touches colour, and it does so entirely by asking
  # the library. Bar heights come from the frame's own band levels resampled to
  # the strip length; everything else is a call to S2l.Strip.
  defp paint(socket, frame, rows) do
    opts = [palette: socket.assigns.palette, color_by: socket.assigns.color_by]

    assign(socket,
      frame: frame,
      rows: rows,
      # Zipped into one list per bar so the template iterates once rather than
      # indexing into four parallel lists.
      bars:
        Enum.zip([
          Strip.resample(frame.bands, @leds),
          Strip.render(frame, @leds, opts),
          Strip.resample(frame.peaks, @leds),
          # floor: 1.0 pins caps to full brightness, so they stay legible
          # against the bar they are sitting on.
          Strip.render(frame, @leds, [source: :peaks, floor: 1.0] ++ opts)
        ]),
      wash: Strip.wash(frame, [floor: 0.04, gain: 0.35] ++ opts),
      waterfall: Strip.waterfall(rows, @waterfall_cols, opts)
    )
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

    <div class="stage" style={"background-color: #{Palette.hex(@wash)}"}>
      <div class="controls">
        <div class="group">
          <b>PALETTE</b>
          <button :for={name <- Palette.names()} phx-click="palette" phx-value-name={name}
                  class={if name == @palette, do: "on"}>{name}</button>
        </div>
        <div class="group">
          <b>COLOUR BY</b>
          <button :for={name <- [:position, :pitch, :centroid, :level]}
                  phx-click="color_by" phx-value-name={name}
                  class={if name == @color_by, do: "on"}>{name}</button>
        </div>
      </div>

      <div class="middle">
        <div class="strip">
          <div :for={{height, colour, cap_height, cap_colour} <- @bars} class="bar">
            <div class="fill"
                 style={"height: #{round(height * 100)}%; background-color: #{Palette.hex(colour)}"}>
            </div>
            <div class="cap"
                 style={"bottom: calc(#{round(cap_height * 100)}% - 1px); background-color: #{Palette.hex(cap_colour)}"}>
            </div>
          </div>
        </div>

        <div class="waterfall">
          <div :for={row <- @waterfall} class="row">
            <div :for={colour <- row} class="cell"
                 style={"background-color: #{Palette.hex(colour)}"}>
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
