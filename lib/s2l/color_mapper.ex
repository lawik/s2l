defmodule S2l.ColorMapper do
  @moduledoc """
  Turns a stream of `S2l.Aubio` analyses into a steady stream of color frames.

  Analysis arrives at whatever rate the audio hops along at, jitters, and is in
  arbitrary units that depend on how loud the room is. A display wants
  something smooth, bounded, and paced. This module is the part that bridges
  those, and it is the module worth iterating on — everything about how music
  becomes color lives here.

      {:ok, _pid} = S2l.ColorMapper.start_link()
      S2l.ColorMapper.subscribe()

      # in the audio pipeline
      S2l.ColorMapper.push(analysis)

      receive do
        {:s2l_frame, frame} -> frame.hue
      end

  There are no framework dependencies here on purpose. A LiveView and an LED
  strip are both just subscribers, so the tuning done against a browser carries
  over to hardware unchanged.

  ## What it does

  * **Hue** follows the spectral centre of mass: bass-heavy leans red, treble
    leans blue. Smoothed, so it drifts rather than flickers.
  * **Level** follows total energy through an automatic gain stage, so a quiet
    room and a loud one both use the full range. It rises fast and falls slowly,
    the way a VU meter does, because instant decay reads as flicker.
  * **Beat** adds a brief spike on top of level and decays over a few frames.

  Frames are emitted at a fixed rate whether or not audio is arriving, so a
  stalled pipeline fades to black instead of freezing mid-colour.

  ## Tuning

  Every constant is runtime-adjustable with `configure/2`, which is the point —
  these are feel decisions, not correctness decisions, and they want a live
  loop rather than a recompile.
  """

  use GenServer

  alias S2l.Aubio

  @typedoc """
  One frame of color.

  * `:hue` — 0–360, ready for `hsl()`.
  * `:level` — 0.0–1.0 overall brightness, beat spike included.
  * `:beat` — whether this frame lands on a beat.
  * `:bpm` — the tempo tracker's current estimate. Passed through untouched,
    and meaningless until it has had a few seconds to settle.
  * `:bands` — per-band level, 0.0–1.0, low frequency first. For spatial
    effects across an LED strip.
  """
  @type frame :: %{
          hue: float(),
          level: float(),
          beat: boolean(),
          bpm: float(),
          bands: [float()]
        }

  @type option ::
          {:name, GenServer.name()}
          | {:fps, pos_integer()}
          | {:attack, float()}
          | {:decay, float()}
          | {:hue_smoothing, float()}
          | {:hue_range, {number(), number()}}
          | {:beat_boost, float()}
          | {:beat_decay, float()}
          | {:gain_decay, float()}
          | {:gate, float()}

  @defaults %{
    fps: 30,
    # Rise almost immediately, fall over roughly half a second. Asymmetry is
    # what makes a meter feel responsive instead of twitchy.
    attack: 0.6,
    decay: 0.12,
    hue_smoothing: 0.2,
    # Red through to blue. Stopping short of 360 avoids wrapping back to red at
    # the treble end, which would make the two extremes indistinguishable.
    hue_range: {0.0, 260.0},
    beat_boost: 0.45,
    beat_decay: 0.35,
    # Slow enough to hold a reference through a quiet passage, fast enough to
    # follow a change in the room over a few seconds.
    gain_decay: 0.999,
    gate: 1.0e-6
  }

  @doc """
  Starts a color mapper.

  Accepts any of the tuning options in `configure/2`, plus `:name`
  (defaults to `#{inspect(__MODULE__)}`).
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Feeds one analysis in. Called from the audio pipeline; never blocks.
  """
  @spec push(GenServer.server(), Aubio.analysis()) :: :ok
  def push(server \\ __MODULE__, analysis) do
    GenServer.cast(server, {:analysis, analysis})
  end

  @doc """
  Subscribes the calling process to `{:s2l_frame, frame}` messages.

  The subscription is monitored, so a subscriber that dies is dropped.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  @doc """
  Stops sending frames to the calling process.
  """
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server \\ __MODULE__) do
    GenServer.call(server, {:unsubscribe, self()})
  end

  @doc """
  Adjusts tuning constants on a running mapper.

      S2l.ColorMapper.configure(decay: 0.05, beat_boost: 0.8)

  ## Options

  * `:fps` — frames emitted per second (default `#{@defaults.fps}`).
  * `:attack` — how fast level rises, 0–1 per frame (default `#{@defaults.attack}`).
  * `:decay` — how fast level falls (default `#{@defaults.decay}`).
  * `:hue_smoothing` — how fast hue chases the spectrum (default `#{@defaults.hue_smoothing}`).
  * `:hue_range` — `{bass_hue, treble_hue}` (default `#{inspect(@defaults.hue_range)}`).
  * `:beat_boost` — brightness added on a beat (default `#{@defaults.beat_boost}`).
  * `:beat_decay` — how fast that spike fades (default `#{@defaults.beat_decay}`).
  * `:gain_decay` — how fast the automatic gain reference falls
    (default `#{@defaults.gain_decay}`). Lower adapts faster and pumps more.
  * `:gate` — energy below this counts as silence (default `#{@defaults.gate}`).
  """
  @spec configure(GenServer.server(), [option()]) :: :ok
  def configure(server \\ __MODULE__, opts) do
    GenServer.call(server, {:configure, Map.new(opts)})
  end

  @doc """
  Returns the most recent frame without subscribing.
  """
  @spec frame(GenServer.server()) :: frame()
  def frame(server \\ __MODULE__) do
    GenServer.call(server, :frame)
  end

  @impl GenServer
  def init(opts) do
    state = %{
      config: Map.merge(@defaults, Map.new(opts)),
      level: 0.0,
      hue: 0.0,
      spike: 0.0,
      bpm: 0.0,
      beat_pending: false,
      energy_peak: 0.0,
      band_peak: 0.0,
      bands: [],
      subscribers: %{}
    }

    {:ok, schedule_tick(state)}
  end

  @impl GenServer
  def handle_cast({:analysis, analysis}, state) do
    {:noreply, absorb(state, analysis)}
  end

  @impl GenServer
  def handle_call({:subscribe, pid}, _from, state) do
    ref = Process.monitor(pid)

    {:reply, :ok, put_in(state.subscribers[ref], pid)}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    subscribers =
      Enum.reject(state.subscribers, fn {ref, subscriber} ->
        subscriber == pid and Process.demonitor(ref, [:flush]) == true
      end)

    {:reply, :ok, %{state | subscribers: Map.new(subscribers)}}
  end

  def handle_call({:configure, opts}, _from, state) do
    {:reply, :ok, %{state | config: Map.merge(state.config, opts)}}
  end

  def handle_call(:frame, _from, state) do
    {:reply, build_frame(state), state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    state = advance(state)

    frame = build_frame(state)

    for {_ref, pid} <- state.subscribers do
      send(pid, {:s2l_frame, frame})
    end

    {:noreply, schedule_tick(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}
  end

  defp schedule_tick(state) do
    Process.send_after(self(), :tick, div(1000, state.config.fps))

    state
  end

  # Folds one analysis into the running state. Deliberately does not emit
  # anything: emission is on the clock, so a burst or a gap in analysis cannot
  # turn into a burst or a gap on screen.
  defp absorb(state, analysis) do
    config = state.config
    energy = Enum.sum(analysis.bands)

    # Automatic gain: track a decaying peak and measure everything against it,
    # so absolute loudness stops mattering.
    energy_peak = max(energy, state.energy_peak * config.gain_decay)

    band_peak =
      max(Enum.max(analysis.bands, &>=/2, fn -> 0.0 end), state.band_peak * config.gain_decay)

    target =
      if energy_peak > config.gate do
        clamp(energy / energy_peak, 0.0, 1.0)
      else
        0.0
      end

    rate = if target > state.level, do: config.attack, else: config.decay

    %{
      state
      | level: state.level + (target - state.level) * rate,
        hue: state.hue + (target_hue(analysis.bands, config) - state.hue) * config.hue_smoothing,
        bpm: analysis.bpm,
        energy_peak: energy_peak,
        band_peak: band_peak,
        bands: normalize_bands(analysis.bands, band_peak, config),
        beat_pending: state.beat_pending or analysis.beat
    }
  end

  # Runs once per output frame, on the clock.
  defp advance(state) do
    spike =
      if state.beat_pending do
        1.0
      else
        state.spike * state.config.beat_decay
      end

    %{state | spike: spike, beat_pending: false}
  end

  defp build_frame(state) do
    %{
      hue: state.hue,
      level: clamp(state.level + state.spike * state.config.beat_boost, 0.0, 1.0),
      beat: state.spike > 0.5,
      bpm: state.bpm,
      bands: state.bands
    }
  end

  # Spectral centre of mass, as a position between the lowest and highest band,
  # mapped onto the hue range. Mel spacing means this tracks what a listener
  # would call "brightness" rather than raw frequency.
  defp target_hue(bands, config) do
    {low, high} = config.hue_range
    total = Enum.sum(bands)

    if total > config.gate do
      weighted =
        bands
        |> Enum.with_index()
        |> Enum.reduce(0.0, fn {value, index}, acc -> acc + value * index end)

      centroid = weighted / total / max(length(bands) - 1, 1)

      low + (high - low) * clamp(centroid, 0.0, 1.0)
    else
      low
    end
  end

  defp normalize_bands(bands, band_peak, config) do
    if band_peak > config.gate do
      Enum.map(bands, &clamp(&1 / band_peak, 0.0, 1.0))
    else
      Enum.map(bands, fn _band -> 0.0 end)
    end
  end

  defp clamp(value, low, high), do: value |> max(low) |> min(high)
end
