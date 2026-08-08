defmodule S2l.Palette do
  @moduledoc """
  Colour palettes: a position between 0 and 1 in, an RGB colour out.

      S2l.Palette.at(:fire, 0.5)
      #=> {255, 108, 0}

      S2l.Palette.gradient(:ocean, 8)
      #=> [{2, 8, 48}, {6, 32, 92}, ...]

  Mapping a signal onto a palette rather than straight onto a hue is what LED
  projects generally do, and it is worth the indirection: hue alone can only
  travel around a colour wheel, so it cannot express "dark at the bottom,
  white-hot at the top", and it passes through colours that look muddy on a
  real LED. A palette is an artistic choice made once, up front.

  Palettes are lists of `{position, {r, g, b}}` stops in ascending order, and
  colours between stops are interpolated. Anywhere a palette is accepted, a
  built-in name or a literal list of stops will do:

      S2l.Palette.at([{0.0, {0, 0, 0}}, {1.0, {0, 255, 128}}], 0.25)
      #=> {0, 64, 32}

  Interpolation is linear in RGB. It is not perceptually uniform, but it is
  what LED libraries do, so the result matches what the same stops produce on
  hardware.
  """

  @type rgb :: {0..255, 0..255, 0..255}
  @type stop :: {float(), rgb()}
  @type t :: atom() | [stop()]

  @palettes %{
    # A spectrum rather than a colour wheel: it stops at violet instead of
    # wrapping back to red, so the two ends stay distinguishable when the
    # palette is laid along a strip.
    rainbow: [
      {0.0, {255, 0, 0}},
      {0.17, {255, 128, 0}},
      {0.33, {255, 255, 0}},
      {0.5, {0, 255, 0}},
      {0.67, {0, 200, 255}},
      {0.83, {0, 0, 255}},
      {1.0, {180, 0, 255}}
    ],
    fire: [
      {0.0, {0, 0, 0}},
      {0.25, {128, 0, 0}},
      {0.5, {255, 60, 0}},
      {0.75, {255, 180, 0}},
      {1.0, {255, 255, 220}}
    ],
    ice: [
      {0.0, {0, 0, 0}},
      {0.3, {0, 24, 96}},
      {0.6, {0, 140, 220}},
      {0.85, {120, 230, 255}},
      {1.0, {255, 255, 255}}
    ],
    ocean: [
      {0.0, {2, 8, 48}},
      {0.35, {0, 60, 130}},
      {0.65, {0, 150, 160}},
      {0.85, {60, 210, 190}},
      {1.0, {200, 245, 235}}
    ],
    forest: [
      {0.0, {0, 12, 4}},
      {0.35, {12, 80, 24}},
      {0.65, {70, 160, 40}},
      {0.85, {170, 210, 60}},
      {1.0, {235, 245, 180}}
    ],
    # Deliberately no green, which is what gives the FastLED palette of this
    # name its look.
    party: [
      {0.0, {40, 0, 160}},
      {0.25, {160, 0, 160}},
      {0.5, {230, 0, 60}},
      {0.75, {255, 110, 0}},
      {1.0, {255, 220, 0}}
    ],
    magma: [
      {0.0, {0, 0, 4}},
      {0.25, {80, 18, 100}},
      {0.5, {180, 54, 90}},
      {0.75, {240, 130, 60}},
      {1.0, {252, 253, 191}}
    ],
    mono: [
      {0.0, {0, 0, 0}},
      {1.0, {255, 255, 255}}
    ]
  }

  @names @palettes |> Map.keys() |> Enum.sort()

  @doc """
  Names of the built-in palettes.
  """
  @spec names() :: [atom()]
  def names(), do: @names

  @doc """
  Stops making up a built-in palette.

  Raises for an unknown name; use `names/0` for the valid set.
  """
  @spec stops(atom()) :: [stop()]
  def stops(name) when is_map_key(@palettes, name), do: Map.fetch!(@palettes, name)

  def stops(name) do
    raise ArgumentError,
          "unknown palette #{inspect(name)}, expected one of #{inspect(@names)}"
  end

  @doc """
  Colour at `position` in `palette`.

  `position` is clamped to 0..1, so callers do not have to.

  ## Options

  * `:brightness` — scales the result, 0.0–1.0 (default `1.0`). Applied after
    interpolation, so a palette's own dark end stays dark.

  ## Examples

      iex> S2l.Palette.at(:mono, 0.5)
      {128, 128, 128}

      iex> S2l.Palette.at(:mono, 1.0, brightness: 0.5)
      {128, 128, 128}
  """
  @spec at(t(), number(), keyword()) :: rgb()
  def at(palette, position, opts \\ [])

  def at(name, position, opts) when is_atom(name) do
    at(stops(name), position, opts)
  end

  def at(stops, position, opts) when is_list(stops) do
    brightness = opts |> Keyword.get(:brightness, 1.0) |> clamp()
    {r, g, b} = interpolate(stops, clamp(position))

    {scale(r, brightness), scale(g, brightness), scale(b, brightness)}
  end

  @doc """
  Evenly spaced colours across the whole palette.

  The shape a strip wants: `count` colours from one end to the other.

      iex> S2l.Palette.gradient(:mono, 3)
      [{0, 0, 0}, {128, 128, 128}, {255, 255, 255}]
  """
  @spec gradient(t(), pos_integer(), keyword()) :: [rgb()]
  def gradient(palette, count, opts \\ []) when count > 0 do
    divisor = max(count - 1, 1)

    Enum.map(0..(count - 1), &at(palette, &1 / divisor, opts))
  end

  @doc """
  An RGB tuple as a CSS hex colour.

      iex> S2l.Palette.hex({255, 0, 128})
      "#ff0080"
  """
  @spec hex(rgb()) :: binary()
  def hex({r, g, b}) do
    "#" <> Base.encode16(<<r, g, b>>, case: :lower)
  end

  defp interpolate([{_position, colour}], _target), do: colour

  defp interpolate([{low, low_colour}, {high, high_colour} | rest], target) do
    cond do
      target <= low -> low_colour
      target > high and rest != [] -> interpolate([{high, high_colour} | rest], target)
      target > high -> high_colour
      high <= low -> high_colour
      true -> blend(low_colour, high_colour, (target - low) / (high - low))
    end
  end

  defp blend({r1, g1, b1}, {r2, g2, b2}, ratio) do
    {mix(r1, r2, ratio), mix(g1, g2, ratio), mix(b1, b2, ratio)}
  end

  defp mix(from, to, ratio), do: round(from + (to - from) * ratio)

  defp scale(value, brightness), do: value |> Kernel.*(brightness) |> round()

  defp clamp(value), do: value |> max(0.0) |> min(1.0)
end
