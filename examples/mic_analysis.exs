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
  Redraws a single terminal line from the colour mapper's frames.

  Counting beats and onsets is the only state kept here, and only because it is
  a property of this display rather than of the audio. Levels, automatic gain
  and pacing all come from `S2l.ColorMapper`: analysis arrives about 86 times a
  second in arbitrary units, and turning that into something bounded and steady
  is exactly the job it already does.
  """

  use GenServer

  @bar_width 40

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Counts an analysis. Levels come from the mapper, so only the tallies live here.
  """
  def count(analysis) do
    GenServer.cast(__MODULE__, {:analysis, analysis})
  end

  @impl GenServer
  def init(_arg) do
    S2l.ColorMapper.subscribe()

    {:ok, %{beats: 0, onsets: 0}}
  end

  @impl GenServer
  def handle_cast({:analysis, analysis}, state) do
    {:noreply,
     %{
       state
       | beats: state.beats + if(analysis.beat, do: 1, else: 0),
         onsets: state.onsets + if(analysis.onset, do: 1, else: 0)
     }}
  end

  # Frames arrive on the mapper's clock, which is already a sane redraw rate.
  @impl GenServer
  def handle_info({:s2l_frame, frame}, state) do
    filled = round(frame.level * @bar_width)
    bar = String.duplicate("█", filled) <> String.duplicate("·", @bar_width - filled)

    IO.write(
      "\r#{bar} #{if frame.beat, do: "BEAT", else: "    "} " <>
        "bpm #{:io_lib.format(~c"~6.1f", [frame.bpm])} " <>
        "peak #{:io_lib.format(~c"~6.0f", [frame.peak_freq])} Hz " <>
        "beats #{state.beats} onsets #{state.onsets}  "
    )

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
      |> child(:analyzer, %S2l.Membrane.Analyzer{handler: &MicAnalysis.handle/1})

    {[spec: spec], %{}}
  end
end

defmodule MicAnalysis do
  @moduledoc """
  Every hop goes to the colour mapper, which does the real work, and to the
  reporter, which only tallies.
  """

  def handle(analysis) do
    S2l.ColorMapper.push(analysis)
    MicAnalysis.Reporter.count(analysis)
  end
end

{:ok, _pid} = S2l.ColorMapper.start_link()
{:ok, _pid} = MicAnalysis.Reporter.start_link([])
{:ok, _supervisor, _pipeline} = Membrane.Pipeline.start_link(MicAnalysis.Pipeline)

IO.puts("Listening. Play something. Ctrl-C twice to stop.\n")

Process.sleep(:infinity)
