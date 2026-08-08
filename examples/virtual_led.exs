# Mic in, virtual LED strip out, in the browser.
#
#   elixir examples/virtual_led.exs
#
# Opens http://localhost:4000 showing a strip of LEDs driven by whatever the
# microphone hears, on a background wash that follows the overall colour.
#
# The interesting part is what this file *does not* contain: no analysis, no
# smoothing, no colour decisions. Those all live in `S2l.ColorMapper`, which
# knows nothing about Phoenix. This script is the disposable half — the same
# frames it renders as div backgrounds are what will drive real LEDs, so tuning
# done here against a browser is not thrown away.

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

  @leds 48

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: S2l.ColorMapper.subscribe()

    # The first, disconnected render has no subscription yet, so it has to
    # derive its LEDs from the current frame the same way the live path does.
    # Otherwise the page paints a dark strip and then jumps once the socket
    # connects.
    frame = S2l.ColorMapper.frame()

    {:ok, assign(socket, frame: frame, leds: spread(frame.bands, @leds))}
  end

  @impl true
  def handle_info({:s2l_frame, frame}, socket) do
    {:noreply, assign(socket, frame: frame, leds: spread(frame.bands, @leds))}
  end

  # Stretches however many analysis bands there are across however many LEDs
  # are being drawn, so the strip length and the band count stay independent.
  # This is the same mapping a real strip will need.
  defp spread([], count), do: List.duplicate(0.0, count)

  defp spread(bands, count) do
    band_count = length(bands)
    indexed = List.to_tuple(bands)

    Enum.map(0..(count - 1), fn led ->
      elem(indexed, min(div(led * band_count, count), band_count - 1))
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <style>
      * { box-sizing: border-box; }
      body { margin: 0; background: #05060a; overflow: hidden; }
      .stage {
        height: 100vh; display: flex; flex-direction: column;
        align-items: center; justify-content: center; gap: 3rem;
        font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
        /* The wash is the plan's original fullscreen div: one colour for the
           whole mix. The transition is what turns 30 discrete frames a second
           into something that reads as continuous. */
        transition: background-color 60ms linear;
      }
      .strip { display: flex; gap: 4px; padding: 0 4vw; width: 100%; }
      .led {
        flex: 1; aspect-ratio: 1 / 2.2; border-radius: 4px;
        transition: background-color 60ms linear, box-shadow 60ms linear;
      }
      .readout { color: rgba(255,255,255,.75); font-size: 14px; letter-spacing: .18em; }
      .beat { color: #fff; font-weight: 700; }
    </style>

    <div class="stage" style={"background-color: #{wash(@frame)}"}>
      <div class="strip">
        <div :for={{level, i} <- Enum.with_index(@leds)} class="led" style={led(@frame, level, i)}>
        </div>
      </div>

      <div class="readout">
        <span class={if @frame.beat, do: "beat"}>{if @frame.beat, do: "BEAT", else: "····"}</span>
        &nbsp; BPM {:erlang.float_to_binary(@frame.bpm, decimals: 1)} &nbsp; LEVEL {:erlang.float_to_binary(@frame.level, decimals: 2)}
      </div>
    </div>
    """
  end

  # Kept dark: a background at full lightness would drown the strip.
  defp wash(frame) do
    "hsl(#{round(frame.hue)} 70% #{round(4 + frame.level * 14)}%)"
  end

  # Each LED takes its hue from its position in the strip and its brightness
  # from its band, lifted by the overall level so the whole strip breathes.
  defp led(frame, level, index) do
    hue = round(frame.hue + index * 1.2)
    lightness = round(6 + level * frame.level * 60)
    glow = level * frame.level

    "background-color: hsl(#{hue} 95% #{lightness}%); " <>
      "box-shadow: 0 0 #{round(glow * 26)}px hsl(#{hue} 95% 60% / #{Float.round(glow, 2)})"
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
