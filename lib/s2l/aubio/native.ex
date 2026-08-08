defmodule S2l.Aubio.Native do
  @moduledoc false
  # Raw NIF bindings. Everything user-facing lives in `S2l.Aubio`; this module
  # exists only to own the loaded library and its stub functions.

  @on_load :load_nif

  @spec load_nif() :: :ok | {:error, term()}
  def load_nif() do
    # priv_dir/1 answers {:error, :bad_name} when the application is not
    # visible, which an escript or a stripped release can produce. Matching it
    # here fails the module load with a reason that names the problem, rather
    # than a FunctionClauseError raised from inside :filename.join.
    case :code.priv_dir(:s2l) do
      {:error, reason} ->
        {:error, {:priv_dir_unavailable, reason}}

      dir ->
        dir
        |> :filename.join(~c"s2l_aubio_nif")
        |> :erlang.load_nif(0)
    end
  end

  @spec create(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          float(),
          float(),
          binary(),
          binary()
        ) :: {:ok, reference()} | {:error, atom()}
  def create(
        _sample_rate,
        _buf_size,
        _hop_size,
        _n_bands,
        _fmin,
        _fmax,
        _onset_method,
        _tempo_method
      ) do
    :erlang.nif_error(:nif_not_loaded)
  end

  @spec process(reference(), binary()) :: {:ok, map()} | {:error, atom()}
  def process(_analyzer, _samples) do
    :erlang.nif_error(:nif_not_loaded)
  end
end
