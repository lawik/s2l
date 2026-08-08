# Mic in, analysis out.
#
#   elixir examples/mic_analysis.exs
#
# The smaller of the two examples and the one to reach for when something looks
# wrong: no Phoenix, no color mapping, nothing but the pipeline and what aubio
# makes of what it hears. Play music at your machine and the meter should move
# with it, BEAT should land on the beat, and the tempo should settle within a
# few seconds.

Mix.install([
  {:s2l, path: Path.expand("..", __DIR__)},
  {:membrane_portaudio_plugin, "~> 0.19"}
])

# Membrane narrates every link and state change at :debug, which would scribble
# over the meter below. Warnings and errors still get through.
Logger.configure(level: :warning)

defmodule MicAnalysis.Reporter do
  @moduledoc """
  Redraws a single terminal line from the analysis stream.

  A `GenServer` rather than raw `IO.puts` from the pipeline: analysis arrives
  about 86 times a second, which is far more often than a terminal can usefully
  be redrawn, so this throttles to something readable.
  """

  use GenServer

  @redraw_interval 50
  @bar_width 40

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def report(analysis) do
    GenServer.cast(__MODULE__, {:analysis, analysis})
  end

  @impl GenServer
  def init(_arg) do
    Process.send_after(self(), :redraw, @redraw_interval)

    {:ok, %{analysis: nil, peak: 0.0, beats: 0, onsets: 0, beat_flash: 0}}
  end

  @impl GenServer
  def handle_cast({:analysis, analysis}, state) do
    {:noreply,
     %{
       state
       | analysis: analysis,
         peak: max(Enum.sum(analysis.bands), state.peak * 0.999),
         beats: state.beats + if(analysis.beat, do: 1, else: 0),
         onsets: state.onsets + if(analysis.onset, do: 1, else: 0),
         beat_flash: if(analysis.beat, do: 6, else: max(state.beat_flash - 1, 0))
     }}
  end

  @impl GenServer
  def handle_info(:redraw, %{analysis: nil} = state) do
    Process.send_after(self(), :redraw, @redraw_interval)

    {:noreply, state}
  end

  def handle_info(:redraw, state) do
    analysis = state.analysis
    energy = Enum.sum(analysis.bands)
    level = if state.peak > 0, do: energy / state.peak, else: 0.0
    filled = round(level * @bar_width)

    bar = String.duplicate("█", filled) <> String.duplicate("·", @bar_width - filled)
    beat = if state.beat_flash > 0, do: "BEAT", else: "    "

    IO.write(
      "\r#{bar} #{beat} " <>
        "bpm #{:io_lib.format(~c"~6.1f", [analysis.bpm])} " <>
        "conf #{:io_lib.format(~c"~5.2f", [analysis.confidence])} " <>
        "beats #{state.beats} onsets #{state.onsets}  "
    )

    Process.send_after(self(), :redraw, @redraw_interval)

    {:noreply, state}
  end
end

defmodule MicAnalysis.Pipeline do
  @moduledoc """
  Microphone straight into the analyzer.

  PortAudio converts to `f32le` mono for us, so there is no resampling stage.
  Note that the sample rate is *not* set here: the device's own rate flows
  through the stream format into the analyzer, which is what keeps tempo honest
  on a 48 kHz device.
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
      |> child(:analyzer, %S2l.Membrane.Analyzer{
        handler: &MicAnalysis.Reporter.report/1
      })

    {[spec: spec], %{}}
  end
end

{:ok, _pid} = MicAnalysis.Reporter.start_link([])
{:ok, _supervisor, _pipeline} = Membrane.Pipeline.start_link(MicAnalysis.Pipeline)

IO.puts("Listening. Play something. Ctrl-C twice to stop.\n")

Process.sleep(:infinity)
