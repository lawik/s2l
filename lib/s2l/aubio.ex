defmodule S2l.Aubio do
  @moduledoc """
  Beat, onset and spectral-band analysis of an audio stream, backed by
  [aubio](https://aubio.org).

  Audio is fed one hop at a time as `f32le` mono — aubio's native sample format,
  so the frame is handed to the analyzer without a copy or conversion.

      {:ok, analyzer} = S2l.Aubio.create(44_100)

      {:ok, analysis} = S2l.Aubio.process(analyzer, frame)
      #=> %{beat: false, bpm: 120.1, confidence: 1.4, onset: true, bands: [...]}

  ## Statefulness

  The beat and onset trackers are stateful: they build up evidence across
  frames. That means one analyzer per stream, and frames fed **in order** with
  none skipped. Feeding a second stream through the same analyzer will produce
  nonsense rather than an error. An analyzer is safe to share between processes
  — calls are serialized — but the ordering requirement usually makes a single
  owning process the sensible design anyway.

  The tempo tracker needs roughly four seconds of audio before `:bpm` settles.
  Onsets fire from the first transient.

  ## Sample rate

  `create/2` takes the real sample rate of the stream. Pass the rate you are
  actually receiving — read it from the stream format rather than assuming.
  Analyzing 48 kHz audio with an analyzer built for 44.1 kHz does not fail, it
  quietly reports a BPM about 9% off.
  """

  alias S2l.Aubio.Native

  defstruct [:ref, :sample_rate, :buf_size, :hop_size, :bands]

  @typedoc """
  A configured analyzer. Holds the aubio state; garbage collected like any
  other term, which frees the underlying resources.
  """
  @type t :: %__MODULE__{
          ref: reference(),
          sample_rate: pos_integer(),
          buf_size: pos_integer(),
          hop_size: pos_integer(),
          bands: pos_integer()
        }

  @typedoc """
  One hop's worth of analysis.

  * `:beat` — a beat falls on this frame, according to the tempo tracker.
  * `:bpm` — current tempo estimate. Meaningless until the tracker locks.
  * `:confidence` — how much the tracker trusts its own estimate. Higher is
    better; around 0 means it has not found a pulse.
  * `:onset` — a transient starts on this frame. Independent of `:beat`, and far
    more frequent.
  * `:bands` — energy per mel-spaced frequency band, low to high, all
    non-negative. This is the raw material for color.
  """
  @type analysis :: %{
          beat: boolean(),
          bpm: float(),
          confidence: float(),
          onset: boolean(),
          bands: [float()]
        }

  @typedoc """
  Onset detection function. `:hfc` (high frequency content) favours percussive
  material and is the default; `:energy` is blunter but cheap; `:complex` and
  `:specflux` cope better with softer note attacks.
  """
  @type method ::
          :default
          | :energy
          | :hfc
          | :complex
          | :phase
          | :wphase
          | :specdiff
          | :kl
          | :mkl
          | :specflux

  @methods ~w(default energy hfc complex phase wphase specdiff kl mkl specflux)a

  @default_buf_size 1024
  @default_hop_size 512
  @default_bands 16
  @default_onset_method :hfc
  @default_tempo_method :default

  @doc """
  Creates an analyzer for a stream running at `sample_rate` Hz.

  ## Options

  * `:buf_size` — analysis window, in samples (default `#{@default_buf_size}`).
    Must be at least `:hop_size`.
  * `:hop_size` — samples per call to `process/2` (default
    `#{@default_hop_size}`). Sets how often analysis updates: at 44.1 kHz, 512
    samples is about 86 times a second.
  * `:bands` — number of mel bands (default `#{@default_bands}`).
  * `:onset_method` — see `t:method/0` (default `#{inspect(@default_onset_method)}`).
  * `:tempo_method` — detection function behind beat tracking (default
    `#{inspect(@default_tempo_method)}`).

  Allocates FFT plans and filter coefficients, so call it during setup rather
  than per buffer.

  Returns `{:error, :badarg}` for out-of-range sizes and
  `{:error, :init_failed}` if aubio cannot build the objects.
  """
  @spec create(pos_integer(), keyword()) :: {:ok, t()} | {:error, atom()}
  def create(sample_rate, opts \\ []) do
    buf_size = Keyword.get(opts, :buf_size, @default_buf_size)
    hop_size = Keyword.get(opts, :hop_size, @default_hop_size)
    bands = Keyword.get(opts, :bands, @default_bands)
    onset_method = Keyword.get(opts, :onset_method, @default_onset_method)
    tempo_method = Keyword.get(opts, :tempo_method, @default_tempo_method)

    with {:ok, onset} <- method_name(onset_method),
         {:ok, tempo} <- method_name(tempo_method),
         {:ok, ref} <- Native.create(sample_rate, buf_size, hop_size, bands, onset, tempo) do
      {:ok,
       %__MODULE__{
         ref: ref,
         sample_rate: sample_rate,
         buf_size: buf_size,
         hop_size: hop_size,
         bands: bands
       }}
    end
  end

  @doc """
  Analyzes one hop of audio.

  `samples` must be exactly `hop_size` little-endian 32-bit floats — that is
  `frame_size/1` bytes — of mono audio. Anything else returns
  `{:error, :bad_frame_size}`; nothing here raises or takes down the VM.

  Cheap enough to call inline: a hop is microseconds of work.
  """
  @spec process(t(), binary()) :: {:ok, analysis()} | {:error, atom()}
  def process(%__MODULE__{ref: ref}, samples) when is_binary(samples) do
    Native.process(ref, samples)
  end

  @doc """
  Exact byte size of the frame `process/2` expects.

  Useful for slicing an incoming stream into hops.

      iex> {:ok, analyzer} = S2l.Aubio.create(44_100, hop_size: 512)
      iex> S2l.Aubio.frame_size(analyzer)
      2048
  """
  @spec frame_size(t()) :: pos_integer()
  def frame_size(%__MODULE__{hop_size: hop_size}), do: hop_size * 4

  defp method_name(method) when method in @methods, do: {:ok, Atom.to_string(method)}
  defp method_name(_method), do: {:error, :unknown_method}
end
