defmodule S2l.PaletteTest do
  use ExUnit.Case, async: true

  alias S2l.Palette

  doctest S2l.Palette

  describe "built-ins" do
    test "every named palette resolves across its whole span" do
      for name <- Palette.names() do
        for position <- [0.0, 0.25, 0.5, 0.75, 1.0] do
          assert {r, g, b} = Palette.at(name, position)

          assert r in 0..255 and g in 0..255 and b in 0..255,
                 "#{name} at #{position} produced #{inspect({r, g, b})}"
        end
      end
    end

    test "start and end are distinguishable, so a strip does not fold back on itself" do
      for name <- Palette.names() do
        assert Palette.at(name, 0.0) != Palette.at(name, 1.0), "#{name} begins where it ends"
      end
    end

    test "stops are in ascending order, which interpolation relies on" do
      for name <- Palette.names() do
        positions = Enum.map(Palette.stops(name), &elem(&1, 0))

        assert positions == Enum.sort(positions), "#{name} has out-of-order stops"
        assert hd(positions) == 0.0
        assert List.last(positions) == 1.0
      end
    end

    test "unknown names say what is available" do
      assert_raise ArgumentError, ~r/unknown palette :nope/, fn -> Palette.stops(:nope) end
    end
  end

  describe "at/3" do
    test "interpolates between stops" do
      palette = [{0.0, {0, 0, 0}}, {1.0, {100, 200, 40}}]

      assert Palette.at(palette, 0.0) == {0, 0, 0}
      assert Palette.at(palette, 0.5) == {50, 100, 20}
      assert Palette.at(palette, 1.0) == {100, 200, 40}
    end

    test "honours intermediate stops rather than blending end to end" do
      palette = [{0.0, {0, 0, 0}}, {0.25, {255, 0, 0}}, {1.0, {255, 255, 255}}]

      assert Palette.at(palette, 0.25) == {255, 0, 0}
      # Halfway between the second and third stop, not halfway overall.
      assert Palette.at(palette, 0.625) == {255, 128, 128}
    end

    test "clamps positions outside 0..1 instead of failing" do
      assert Palette.at(:rainbow, -3.0) == Palette.at(:rainbow, 0.0)
      assert Palette.at(:rainbow, 7.5) == Palette.at(:rainbow, 1.0)
    end

    test "brightness scales the interpolated colour" do
      assert Palette.at(:mono, 1.0, brightness: 0.0) == {0, 0, 0}
      assert Palette.at(:mono, 1.0, brightness: 1.0) == {255, 255, 255}
      assert Palette.at(:mono, 1.0, brightness: 0.25) == {64, 64, 64}
    end

    test "brightness is clamped too" do
      assert Palette.at(:mono, 1.0, brightness: 5.0) == {255, 255, 255}
      assert Palette.at(:mono, 1.0, brightness: -2.0) == {0, 0, 0}
    end

    test "a single-stop palette is a constant colour" do
      assert Palette.at([{0.0, {7, 8, 9}}], 0.9) == {7, 8, 9}
    end
  end

  describe "gradient/3" do
    test "spans the palette end to end" do
      colours = Palette.gradient(:rainbow, 16)

      assert length(colours) == 16
      assert hd(colours) == Palette.at(:rainbow, 0.0)
      assert List.last(colours) == Palette.at(:rainbow, 1.0)
    end

    test "a single step does not divide by zero" do
      assert Palette.gradient(:fire, 1) == [Palette.at(:fire, 0.0)]
    end
  end

  describe "hex/1" do
    test "pads each channel to two digits" do
      assert Palette.hex({0, 0, 0}) == "#000000"
      assert Palette.hex({255, 255, 255}) == "#ffffff"
      assert Palette.hex({1, 2, 3}) == "#010203"
    end
  end
end
