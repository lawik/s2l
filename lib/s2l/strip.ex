defmodule S2l.Strip do
  @moduledoc """
  Fits a colour frame onto a strip of any length.

  The number of analysis bands and the number of LEDs are unrelated: bands are
  chosen for how the audio divides up, LEDs for whatever hardware is on the
  bench. Something has to reconcile them, and it is fiddly enough — and needed
  by every consumer — to belong here rather than in each display.

      S2l.Strip.render(frame, 60, palette: :fire)
      #=> [{12, 0, 0}, {41, 2, 0}, ...]   60 colours, ready for a strip

  The result is a plain list of `{r, g, b}` tuples, which is what both
  `Fledex.Leds.leds/3` and a CSS `background-color` want.

  ## Why not just index into the bands

  Picking `bands[i * n / count]` per LED works when there are more LEDs than
  bands, but reverses badly when there are fewer: it *skips* bands, so a peak
  that lands in a skipped one disappears entirely. Going down, `resample/3`
  aggregates instead, defaulting to the maximum of each bucket so a transient
  survives being squeezed onto a short strip.
  """

  alias S2l.ColorMapper
  alias S2l.Palette

  @typedoc """
  What decides each LED's position in the palette.

  * `:position` — position along the strip is frequency. The graphic-equalizer
    mapping, and the only one of these that gives the top end a colour of its
    own.
  * `:pitch` — the whole strip takes the colour of the dominant frequency, so
    colour follows the melody rather than the spectrum.
  * `:centroid` — the whole strip follows the spectral centre of mass.
  * `:level` — the whole strip follows loudness, ignoring frequency.
  """
  @type color_by :: :position | :pitch | :centroid | :level

  @doc """
  Resizes a list of levels to exactly `count` entries.

  Interpolates when growing and aggregates when shrinking, so no band is
  silently dropped in either direction. An empty list yields `count` zeros,
  which is what an analyzer that has not produced anything yet gives you.

  ## Options

  * `:interpolation` — how to grow: `:linear` (default) blends between bands
    for a smooth strip, `:nearest` repeats them for visible blocks.
  * `:reduce` — how to shrink: `:max` (default) keeps the loudest band in each
    bucket, `:mean` averages. `:max` is usually right for a display, because a
    transient matters more than an average.

  ## Examples

      iex> S2l.Strip.resample([0.0, 1.0], 3)
      [0.0, 0.5, 1.0]

      iex> S2l.Strip.resample([0.0, 0.9, 0.1, 0.2], 2)
      [0.9, 0.2]

      iex> S2l.Strip.resample([], 3)
      [0.0, 0.0, 0.0]
  """
  @spec resample([float()], pos_integer(), keyword()) :: [float()]
  def resample(values, count, opts \\ [])

  def resample([], count, _opts) when count > 0, do: List.duplicate(0.0, count)

  def resample(values, count, opts) when count > 0 do
    source = length(values)

    cond do
      count == source -> values
      count > source -> grow(values, source, count, Keyword.get(opts, :interpolation, :linear))
      true -> shrink(values, source, count, Keyword.get(opts, :reduce, :max))
    end
  end

  @doc """
  Turns a frame into one colour per LED.

  ## Options

  * `:palette` — see `S2l.Palette` (default `:rainbow`).
  * `:color_by` — see `t:color_by/0` (default `:position`).
  * `:source` — `:bands` (default) for live levels, or `:peaks` for the
    peak-hold caps.
  * `:gain` — multiplies brightness before clamping (default `1.0`).
  * `:floor` — brightness for an LED with no energy (default `0.0`). Lift it
    if a strip going completely dark between beats looks broken rather than
    dramatic.

  Also accepts every option of `resample/3`.

  Brightness comes from each LED's own level, so a frame's `:level` is *not*
  applied automatically — multiply it into `:gain` if you want the whole strip
  to breathe with overall loudness.
  """
  @spec render(ColorMapper.frame(), pos_integer(), keyword()) :: [Palette.rgb()]
  def render(frame, count, opts \\ []) when count > 0 do
    palette = Keyword.get(opts, :palette, :rainbow)
    color_by = Keyword.get(opts, :color_by, :position)
    gain = Keyword.get(opts, :gain, 1.0)
    floor = Keyword.get(opts, :floor, 0.0)
    source = if Keyword.get(opts, :source, :bands) == :peaks, do: frame.peaks, else: frame.bands

    source
    |> resample(count, opts)
    |> Enum.with_index()
    |> Enum.map(fn {level, index} ->
      brightness = floor + (1.0 - floor) * clamp(level * gain)

      Palette.at(palette, position(frame, color_by, index, count), brightness: brightness)
    end)
  end

  @doc """
  A single colour for the whole frame.

  The backdrop behind a strip, or the whole output when there is only one light
  to drive. Takes the same options as `render/3`, except that `:color_by`
  cannot be `:position` — one colour has no position — and falls back to
  `:centroid` if asked for it.

  Brightness comes from the frame's `:level` here, since there is no per-band
  level to use instead.

      iex> frame = %{centroid: 1.0, pitch: 0.0, level: 1.0}
      iex> S2l.Strip.wash(frame, palette: :mono)
      {255, 255, 255}
  """
  @spec wash(ColorMapper.frame(), keyword()) :: Palette.rgb()
  def wash(frame, opts \\ []) do
    palette = Keyword.get(opts, :palette, :rainbow)
    gain = Keyword.get(opts, :gain, 1.0)
    floor = Keyword.get(opts, :floor, 0.0)

    color_by =
      case Keyword.get(opts, :color_by, :centroid) do
        :position -> :centroid
        other -> other
      end

    brightness = floor + (1.0 - floor) * clamp(frame.level * gain)

    Palette.at(palette, position(frame, color_by, 0, 1), brightness: brightness)
  end

  @doc """
  Renders a run of frames, newest first, as rows of colours.

  Feed it `S2l.ColorMapper.history/1` to get a waterfall or scrolling
  spectrogram: each row is one moment in time, each column one frequency.
  Takes the same options as `render/3`, so a waterfall matches the strip above
  it without being configured twice.
  """
  @spec waterfall([ColorMapper.frame()], pos_integer(), keyword()) :: [[Palette.rgb()]]
  def waterfall(frames, count, opts \\ []) when count > 0 do
    Enum.map(frames, &render(&1, count, opts))
  end

  @doc """
  Where a given LED sits in the palette, between 0 and 1.

  Exposed because a display that builds its own colours still wants the mapping
  to agree with `render/3`.

  ## Examples

      iex> frame = %{pitch: 0.75, centroid: 0.25, level: 0.5}
      iex> S2l.Strip.position(frame, :position, 3, 5)
      0.75
      iex> S2l.Strip.position(frame, :pitch, 3, 5)
      0.75
  """
  @spec position(map(), color_by(), non_neg_integer(), pos_integer()) :: float()
  def position(frame, color_by, index, count)
  def position(_frame, :position, index, count), do: index / max(count - 1, 1)
  def position(frame, :pitch, _index, _count), do: frame.pitch
  def position(frame, :centroid, _index, _count), do: frame.centroid
  def position(frame, :level, _index, _count), do: frame.level

  defp grow(values, source, count, :nearest) do
    tuple = List.to_tuple(values)

    Enum.map(0..(count - 1), fn index ->
      elem(tuple, min(div(index * source, count), source - 1))
    end)
  end

  defp grow(values, source, count, :linear) do
    tuple = List.to_tuple(values)
    # Anchored so the first and last LED land exactly on the first and last
    # band rather than half a step inside them.
    span = source - 1
    divisor = max(count - 1, 1)

    Enum.map(0..(count - 1), fn index ->
      exact = index / divisor * span
      low = min(trunc(exact), span)
      high = min(low + 1, span)

      elem(tuple, low) + (elem(tuple, high) - elem(tuple, low)) * (exact - low)
    end)
  end

  defp shrink(values, source, count, reduce) do
    tuple = List.to_tuple(values)

    Enum.map(0..(count - 1), fn index ->
      from = div(index * source, count)
      # Every bucket takes at least one band, so nothing is skipped even when
      # the counts divide awkwardly.
      to = max(div((index + 1) * source, count), from + 1)
      bucket = Enum.map(from..(to - 1), &elem(tuple, &1))

      case reduce do
        :max -> Enum.max(bucket)
        :mean -> Enum.sum(bucket) / length(bucket)
      end
    end)
  end

  defp clamp(value), do: value |> max(0.0) |> min(1.0)
end
