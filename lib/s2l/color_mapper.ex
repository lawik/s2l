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

  * **Hue** follows the spectral centre of mass, stretched across the range that
    centre actually occupies for the material playing. The raw centroid is an
    energy-weighted mean, so for anything broadband it sits stubbornly near the
    middle and mapping it directly paints everything a single colour. Adapting
    to the observed range is what makes it move.
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
  * `:centroid` — raw spectral centre of mass, 0.0–1.0, before any adaptation.
    Use this to build your own colour mapping; `:hue` is one opinionated
    reading of it.
  * `:bands` — per-band level, 0.0–1.0, low frequency first. For spatial
    effects across an LED strip, and the better basis for colour if you want
    the top end to have a colour of its own.
  * `:peaks` — per-band peak hold, 0.0–1.0, falling steadily from each band's
    recent maximum. The falling caps on a graphic equalizer.
  * `:pitch` — position of the dominant frequency between `:pitch_range`, 0.0–1.0
    on a log scale so octaves are evenly spaced. Holds its last value rather
    than dropping out when there is no usable peak.
  * `:peak_freq` — that dominant frequency in Hz, without any smoothing.
  """
  @type frame :: %{
          hue: float(),
          level: float(),
          beat: boolean(),
          bpm: float(),
          centroid: float(),
          pitch: float(),
          peak_freq: float(),
          bands: [float()],
          peaks: [float()]
        }

  @type option ::
          {:name, GenServer.name()}
          | {:fps, pos_integer()}
          | {:attack, float()}
          | {:decay, float()}
          | {:hue_smoothing, float()}
          | {:hue_range, {number(), number()}}
          | {:hue_adapt, float()}
          | {:hue_min_span, float()}
          | {:pitch_range, {number(), number()}}
          | {:pitch_smoothing, float()}
          | {:peak_decay, float()}
          | {:history, non_neg_integer()}
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
    # How fast the observed centroid range closes back in, per analysis. At
    # roughly 86 analyses a second this is a window of a few seconds.
    hue_adapt: 0.004,
    hue_min_span: 0.1,
    # The dominant peak hops between partials constantly, so it needs heavier
    # smoothing than anything derived from the bands.
    pitch_range: {40.0, 12_000.0},
    pitch_smoothing: 0.15,
    # Per frame, so a cap falls to the floor in about a second at 30 fps.
    peak_decay: 0.03,
    history: 90,
    beat_boost: 0.45,
    beat_decay: 0.35,
    # Slow enough to hold a reference through a quiet passage, fast enough to
    # follow a change in the room over a few seconds.
    gain_decay: 0.999,
    gate: 1.0e-6
  }

  # `configure/2` is advertised as the live tuning loop, so bad values get typed
  # at a running server rather than caught in review. Several are load-bearing:
  # `fps: 0` divides by zero on the next tick and takes the server down with the
  # subscriptions and all the adaptation state; `fps: 2000` makes the tick
  # interval 0 and pegs a scheduler; `history: -1` makes `Enum.take/2` keep the
  # *oldest* frame instead of none.
  @bounds %{
    fps: {:integer, 1, 240},
    attack: {:number, 0.0, 1.0},
    decay: {:number, 0.0, 1.0},
    hue_smoothing: {:number, 0.0, 1.0},
    hue_adapt: {:number, 0.0, 1.0},
    hue_min_span: {:number, 0.001, 1.0},
    pitch_smoothing: {:number, 0.0, 1.0},
    beat_boost: {:number, 0.0, 1.0},
    beat_decay: {:number, 0.0, 1.0},
    gain_decay: {:number, 0.0, 1.0},
    peak_decay: {:number, 0.0, 1.0},
    gate: {:number, 0.0, 1.0},
    history: {:integer, 0, 100_000},
    hue_range: :range,
    pitch_range: :range
  }

  # Keeps the two tables from drifting apart as options are added.
  @untyped Map.keys(@defaults) -- Map.keys(@bounds)
  if @untyped != [] do
    raise "S2l.ColorMapper options without validation bounds: #{inspect(@untyped)}"
  end

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

  Options are validated rather than clamped, so a value outside its range comes
  back as `{:error, {:invalid_option, key, value}}` and an unrecognised key as
  `{:error, {:unknown_option, key}}`, both leaving the running configuration
  untouched. Being told is more useful than a silently adjusted number when the
  point of the call is to hear the difference.

  ## Options

  * `:fps` — frames emitted per second (default `#{@defaults.fps}`).
  * `:attack` — how fast level rises, 0–1 per frame (default `#{@defaults.attack}`).
  * `:decay` — how fast level falls (default `#{@defaults.decay}`).
  * `:hue_smoothing` — how fast hue chases the spectrum (default `#{@defaults.hue_smoothing}`).
  * `:hue_range` — `{bass_hue, treble_hue}` (default `#{inspect(@defaults.hue_range)}`).
  * `:hue_adapt` — how fast the observed centroid range closes back in, per
    analysis (default `#{@defaults.hue_adapt}`). Higher reacts sooner to a
    change of material but makes steady music drift back to the middle.
  * `:hue_min_span` — narrowest centroid range that will be stretched over the
    full hue range (default `#{@defaults.hue_min_span}`). Raising it makes
    colour calmer; lowering it amplifies small spectral movements.
  * `:beat_boost` — brightness added on a beat (default `#{@defaults.beat_boost}`).
  * `:beat_decay` — how fast that spike fades (default `#{@defaults.beat_decay}`).
  * `:gain_decay` — how fast the automatic gain reference falls
    (default `#{@defaults.gain_decay}`). Lower adapts faster and pumps more.
  * `:gate` — energy below this counts as silence (default `#{@defaults.gate}`).
  * `:pitch_range` — `{low_hz, high_hz}` spanned by `:pitch`
    (default `#{inspect(@defaults.pitch_range)}`).
  * `:pitch_smoothing` — how fast `:pitch` chases the dominant frequency
    (default `#{@defaults.pitch_smoothing}`).
  * `:peak_decay` — how far a peak-hold cap falls per frame
    (default `#{@defaults.peak_decay}`).
  * `:history` — frames retained for `history/1` (default `#{@defaults.history}`,
    three seconds at the default rate). `0` disables it.
  """
  @spec configure(GenServer.server(), [option()]) :: :ok | {:error, term()}
  def configure(server \\ __MODULE__, opts) do
    GenServer.call(server, {:configure, opts})
  end

  @doc """
  Returns the most recent frame without subscribing.
  """
  @spec frame(GenServer.server()) :: frame()
  def frame(server \\ __MODULE__) do
    GenServer.call(server, :frame)
  end

  @doc """
  The most recent frames, newest first.

  Retains up to the `:history` option's worth. This is what a waterfall or
  scrolling spectrogram is built from: each entry is one row, and `:bands` is
  that row's column heights.

  Kept here rather than left to each consumer so that something attaching
  mid-song — a browser tab opening, an animation restarting — gets a full
  display immediately instead of an empty one that fills in over the next few
  seconds.
  """
  @spec history(GenServer.server()) :: [frame()]
  def history(server \\ __MODULE__) do
    GenServer.call(server, :history)
  end

  @impl GenServer
  def init(opts) do
    case validate(opts) do
      {:ok, config} -> {:ok, start_state(Map.merge(@defaults, config))}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp start_state(config) do
    state = %{
      config: config,
      level: 0.0,
      hue: 0.0,
      spike: 0.0,
      bpm: 0.0,
      centroid: 0.5,
      centroid_min: nil,
      centroid_max: nil,
      pitch: 0.0,
      peak_freq: 0.0,
      beat_pending: false,
      energy_peak: 0.0,
      band_peak: 0.0,
      bands: [],
      peaks: [],
      history: [],
      subscribers: %{}
    }

    schedule_tick(state)
  end

  @impl GenServer
  def handle_cast({:analysis, analysis}, state) do
    {:noreply, absorb(state, analysis)}
  end

  @impl GenServer
  def handle_call({:subscribe, pid}, _from, state) do
    # Subscribing twice from one process would otherwise deliver every frame
    # twice, and a LiveView remounting on reconnect makes that easy to hit.
    if Enum.any?(state.subscribers, fn {_ref, subscriber} -> subscriber == pid end) do
      {:reply, :ok, state}
    else
      {:reply, :ok, put_in(state.subscribers[Process.monitor(pid)], pid)}
    end
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    subscribers =
      Enum.reject(state.subscribers, fn {ref, subscriber} ->
        subscriber == pid and Process.demonitor(ref, [:flush]) == true
      end)

    {:reply, :ok, %{state | subscribers: Map.new(subscribers)}}
  end

  def handle_call({:configure, opts}, _from, state) do
    case validate(opts) do
      {:ok, changes} -> {:reply, :ok, %{state | config: Map.merge(state.config, changes)}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:frame, _from, state) do
    {:reply, build_frame(state), state}
  end

  def handle_call(:history, _from, state) do
    {:reply, state.history, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    state = advance(state)

    frame = build_frame(state)

    for {_ref, pid} <- state.subscribers do
      send(pid, {:s2l_frame, frame})
    end

    state = %{state | history: Enum.take([frame | state.history], state.config.history)}

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

    state = %{
      state
      | level: state.level + (target - state.level) * rate,
        bpm: analysis.bpm,
        energy_peak: energy_peak,
        band_peak: band_peak,
        bands: normalize_bands(analysis.bands, band_peak, config),
        beat_pending: state.beat_pending or analysis.beat
    }

    state = absorb_pitch(state, analysis, config)

    case spectral_centroid(analysis.bands, config) do
      nil ->
        state

      centroid ->
        state = adapt_range(state, centroid, config)
        target_hue = hue_for(centroid, state, config)

        %{
          state
          | centroid: centroid,
            hue: state.hue + (target_hue - state.hue) * config.hue_smoothing
        }
    end
  end

  # A frame with no usable peak holds the last pitch rather than snapping to
  # the bottom of the range, which would read as a hard colour change every
  # time the music left a gap.
  defp absorb_pitch(state, analysis, config) do
    case pitch_position(analysis.peak_freq, config) do
      nil ->
        state

      position ->
        %{
          state
          | pitch: state.pitch + (position - state.pitch) * config.pitch_smoothing,
            peak_freq: analysis.peak_freq
        }
    end
  end

  # Log scaled, so an octave covers the same distance wherever it falls. On a
  # linear scale everything below a few kHz would be squeezed into the bottom
  # of the range, which is where most music actually lives.
  defp pitch_position(freq, config) do
    {low, high} = config.pitch_range

    if freq > low and high > low do
      clamp(:math.log(freq / low) / :math.log(high / low), 0.0, 1.0)
    end
  end

  # Runs once per output frame, on the clock.
  defp advance(state) do
    spike =
      if state.beat_pending do
        1.0
      else
        state.spike * state.config.beat_decay
      end

    %{state | spike: spike, beat_pending: false, peaks: hold_peaks(state)}
  end

  # Each cap sits at its band's recent maximum and falls a fixed amount per
  # frame. Decaying here rather than on each analysis keeps the fall rate tied
  # to what is displayed, not to the audio hop rate.
  defp hold_peaks(state) do
    peaks =
      if length(state.peaks) == length(state.bands) do
        state.peaks
      else
        List.duplicate(0.0, length(state.bands))
      end

    Enum.zip_with(state.bands, peaks, fn band, peak ->
      max(band, peak - state.config.peak_decay)
    end)
  end

  defp build_frame(state) do
    %{
      hue: state.hue,
      level: clamp(state.level + state.spike * state.config.beat_boost, 0.0, 1.0),
      beat: state.spike > 0.5,
      bpm: state.bpm,
      centroid: state.centroid,
      pitch: state.pitch,
      peak_freq: state.peak_freq,
      bands: state.bands,
      peaks: state.peaks
    }
  end

  # Spectral centre of mass, as a position between the lowest and highest band.
  # Mel spacing means this tracks what a listener would call brightness rather
  # than raw frequency. Silence gets no opinion rather than a centroid of zero,
  # which would otherwise drag the adaptive range below towards the bass end
  # every time the music stopped.
  defp spectral_centroid(bands, config) do
    total = Enum.sum(bands)

    if total > config.gate do
      weighted =
        bands
        |> Enum.with_index()
        |> Enum.reduce(0.0, fn {value, index}, acc -> acc + value * index end)

      clamp(weighted / total / max(length(bands) - 1, 1), 0.0, 1.0)
    end
  end

  # The centroid is an energy-weighted mean, so anything broadband — which is
  # to say all music — pins it near the middle of the range. Mapping it
  # straight onto hue therefore paints everything one colour, in practice a
  # green. What carries information is where the centroid sits *relative to
  # this material*, so the range it actually occupies is tracked and stretched
  # across the hue range instead.
  defp adapt_range(state, centroid, config) do
    low = min(centroid, state.centroid_min || centroid)
    high = max(centroid, state.centroid_max || centroid)

    # New extremes are taken immediately; the window closes back in slowly, so
    # one cymbal crash does not widen it for the rest of the session.
    %{
      state
      | centroid_min: low + (centroid - low) * config.hue_adapt,
        centroid_max: high + (centroid - high) * config.hue_adapt
    }
  end

  # Always called on state that has just been through adapt_range/3, so the
  # observed window is populated.
  defp hue_for(centroid, %{centroid_min: observed_min, centroid_max: observed_max}, config) do
    {low, high} = config.hue_range

    # Widened around the middle of the observed window rather than from its
    # bottom, so material with no spectral variation lands mid-range instead of
    # being pinned to one end of the palette on no evidence. The floor also
    # stops a nearly constant centroid being amplified into a full rainbow of
    # meaningless movement.
    centre = (observed_min + observed_max) / 2
    half = max(observed_max - observed_min, config.hue_min_span) / 2
    position = clamp((centroid - (centre - half)) / (2 * half), 0.0, 1.0)

    low + (high - low) * position
  end

  defp normalize_bands(bands, band_peak, config) do
    if band_peak > config.gate do
      Enum.map(bands, &clamp(&1 / band_peak, 0.0, 1.0))
    else
      Enum.map(bands, fn _band -> 0.0 end)
    end
  end

  defp clamp(value, low, high), do: value |> max(low) |> min(high)

  # Rejects rather than clamps: a value outside its range is a mistake, and
  # silently moving it makes the tuning loop lie about what is running.
  defp validate(opts) do
    Enum.reduce_while(opts, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case validate_option(key, value) do
        {:ok, checked} -> {:cont, {:ok, Map.put(acc, key, checked)}}
        :invalid -> {:halt, {:error, {:invalid_option, key, value}}}
        :unknown -> {:halt, {:error, {:unknown_option, key}}}
      end
    end)
  end

  defp validate_option(key, value) do
    case Map.fetch(@bounds, key) do
      :error -> :unknown
      {:ok, bound} -> check(bound, value)
    end
  end

  defp check(:range, {low, high}) when is_number(low) and is_number(high) and high > low do
    {:ok, {low * 1.0, high * 1.0}}
  end

  defp check({:integer, low, high}, value)
       when is_integer(value) and value >= low and value <= high do
    {:ok, value}
  end

  # Integers are accepted wherever a float is wanted, so `beat_boost: 1` works.
  defp check({:number, low, high}, value)
       when is_number(value) and value >= low and value <= high do
    {:ok, value * 1.0}
  end

  defp check(_bound, _value), do: :invalid
end
