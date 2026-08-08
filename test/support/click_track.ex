defmodule S2l.Test.ClickTrack do
  @moduledoc false
  # Synthesizes a click track in pure Elixir, so the anchor test depends on no
  # audio fixture and no external tool.
  #
  # The generator mirrors c_src/verify.c sample for sample — same LCG, same
  # envelope, same mix. Both harnesses therefore analyze an identical signal,
  # which is what makes "the C spike passes but the NIF does not" a conclusive
  # statement about the glue.

  @seed 12_345
  @click_len 2048

  @doc """
  Builds a click track as `f32le` mono.

  ## Options

  * `:sample_rate` — default `44_100`
  * `:bpm` — default `120`
  * `:clicks` — number of clicks, default `20`
  """
  @spec synth(keyword()) :: binary()
  def synth(opts \\ []) do
    sample_rate = Keyword.get(opts, :sample_rate, 44_100)
    bpm = Keyword.get(opts, :bpm, 120)
    clicks = Keyword.get(opts, :clicks, 20)

    period = round(sample_rate * 60 / bpm)
    gap = :binary.copy(<<0.0::float-32-little>>, period - @click_len)

    {iodata, _state} =
      Enum.map_reduce(1..clicks, @seed, fn _click, state ->
        {samples, state} = click(sample_rate, state)
        {[samples, gap], state}
      end)

    IO.iodata_to_binary(iodata)
  end

  @doc """
  Number of clicks per second in a track of the given `bpm`.
  """
  @spec period_seconds(number()) :: float()
  def period_seconds(bpm), do: 60 / bpm

  # A noise transient over a 60 Hz thump, decaying in about 20 ms: broadband
  # enough for the onset detector, low-heavy enough to read as a kick.
  defp click(sample_rate, state) do
    Enum.map_reduce(0..(@click_len - 1), state, fn i, state ->
      t = i / sample_rate
      env = :math.exp(-t * 50.0)
      body = :math.sin(2 * :math.pi() * 60.0 * t)
      {noise, state} = next_noise(state)

      {<<0.9 * env * (0.5 * body + 0.5 * noise)::float-32-little>>, state}
    end)
  end

  # The same linear congruential generator verify.c uses, so the noise is both
  # deterministic and identical across the two harnesses.
  defp next_noise(state) do
    state = Bitwise.band(state * 1_103_515_245 + 12_345, 0x7FFFFFFF)
    {state / 1_073_741_824.0 - 1.0, state}
  end
end
