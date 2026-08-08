defmodule S2l.Membrane.Analyzer do
  @moduledoc """
  Membrane sink that runs `S2l.Aubio` over an audio stream and hands each
  result to a function.

      child(:mic, %Membrane.PortAudio.Source{sample_format: :f32le, channels: 1})
      |> child(:analyzer, %S2l.Membrane.Analyzer{handler: &S2l.ColorMapper.push/1})

  The sample rate is taken from the incoming stream format rather than
  configured here, which is what keeps a 48 kHz device from being analyzed as
  though it were 44.1 kHz.

  ## Hop alignment

  A source hands over whatever buffer sizes it feels like, and aubio needs
  exactly one hop per call. This element buffers the remainder between buffers
  and emits analysis only for complete hops, so no separate chunking element is
  needed and the hop size cannot drift out of sync with the analyzer.

  ## The handler

  `:handler` runs inside the element's process, once per hop — about 86 times a
  second at 44.1 kHz with the default hop. Keep it to a cast or a send; anything
  slower belongs in the receiving process.
  """

  use Membrane.Sink

  alias Membrane.RawAudio
  alias S2l.Aubio

  require Membrane.Logger

  def_input_pad(:input,
    accepted_format: %RawAudio{sample_format: :f32le, channels: 1},
    flow_control: :auto
  )

  def_options(
    handler: [
      spec: (Aubio.analysis() -> any()),
      description: "Called with each hop's analysis, in the element's process."
    ],
    buf_size: [spec: pos_integer(), default: 1024, description: "Analysis window, in samples."],
    hop_size: [spec: pos_integer(), default: 512, description: "Samples per analysis step."],
    bands: [spec: pos_integer(), default: 16, description: "Number of mel bands."],
    onset_method: [
      spec: Aubio.method(),
      default: :hfc,
      description: "Onset detection function; see `t:S2l.Aubio.method/0`."
    ],
    tempo_method: [
      spec: Aubio.method(),
      default: :default,
      description: "Detection function behind beat tracking."
    ]
  )

  @impl true
  def handle_init(_ctx, options) do
    {[], %{options: options, analyzer: nil, leftover: <<>>}}
  end

  @impl true
  def handle_stream_format(:input, %RawAudio{sample_rate: sample_rate}, _ctx, state) do
    options = state.options

    case Aubio.create(sample_rate,
           buf_size: options.buf_size,
           hop_size: options.hop_size,
           bands: options.bands,
           onset_method: options.onset_method,
           tempo_method: options.tempo_method
         ) do
      {:ok, analyzer} ->
        Membrane.Logger.debug("analyzing at #{sample_rate} Hz, hop #{options.hop_size}")
        # A format change restarts analysis: the tempo tracker's state belongs
        # to the rate it was built for.
        {[], %{state | analyzer: analyzer, leftover: <<>>}}

      {:error, reason} ->
        raise "could not create the aubio analyzer at #{sample_rate} Hz: #{inspect(reason)}"
    end
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, %{analyzer: analyzer} = state)
      when not is_nil(analyzer) do
    leftover = consume(state.leftover <> buffer.payload, state)

    {[], %{state | leftover: leftover}}
  end

  defp consume(data, %{analyzer: analyzer, options: options} = state) do
    frame_size = Aubio.frame_size(analyzer)

    case data do
      <<frame::binary-size(^frame_size), rest::binary>> ->
        case Aubio.process(analyzer, frame) do
          {:ok, analysis} ->
            options.handler.(analysis)

          {:error, reason} ->
            Membrane.Logger.warning("dropped a frame: #{inspect(reason)}")
        end

        consume(rest, state)

      rest ->
        rest
    end
  end
end
