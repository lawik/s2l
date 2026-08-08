defmodule S2l.StripTest do
  use ExUnit.Case, async: true

  alias S2l.Strip

  doctest S2l.Strip

  defp frame(opts \\ []) do
    %{
      level: Keyword.get(opts, :level, 1.0),
      hue: 0.0,
      beat: false,
      bpm: 0.0,
      centroid: Keyword.get(opts, :centroid, 0.5),
      pitch: Keyword.get(opts, :pitch, 0.5),
      peak_freq: 0.0,
      bands: Keyword.get(opts, :bands, [1.0, 0.5, 0.0]),
      peaks: Keyword.get(opts, :peaks, [1.0, 1.0, 1.0])
    }
  end

  describe "resample/3 growing" do
    test "keeps the ends anchored on the first and last band" do
      assert [first | _] = result = Strip.resample([0.2, 0.9], 7)

      assert first == 0.2
      assert List.last(result) == 0.9
      assert length(result) == 7
    end

    test "interpolates between bands by default" do
      assert Strip.resample([0.0, 1.0], 5) == [0.0, 0.25, 0.5, 0.75, 1.0]
    end

    test "repeats bands when asked for blocks instead" do
      result = Strip.resample([0.0, 1.0], 4, interpolation: :nearest)

      assert result == [0.0, 0.0, 1.0, 1.0]
    end

    test "a single band fills the whole strip" do
      assert Strip.resample([0.7], 4) == [0.7, 0.7, 0.7, 0.7]
    end

    test "handles a strip of one" do
      assert [value] = Strip.resample([0.1, 0.9], 1)
      assert is_float(value)
    end
  end

  describe "resample/3 shrinking" do
    test "keeps the loudest band in each bucket rather than skipping bands" do
      # The naive approach of indexing every other band would return [0.1, 0.1]
      # and lose both peaks entirely.
      assert Strip.resample([0.1, 0.9, 0.1, 0.8], 2) == [0.9, 0.8]
    end

    test "averages when asked to" do
      assert Strip.resample([0.0, 1.0, 0.0, 1.0], 2, reduce: :mean) == [0.5, 0.5]
    end

    test "covers every band even when the counts divide awkwardly" do
      # 7 bands into 3 buckets: no band may be dropped, so the lone spike has
      # to survive wherever it is put.
      for spike <- 0..6 do
        bands = List.duplicate(0.0, 7) |> List.replace_at(spike, 1.0)

        assert Enum.max(Strip.resample(bands, 3)) == 1.0,
               "a spike at band #{spike} was dropped"
      end
    end

    test "never returns fewer entries than asked for" do
      for count <- 1..16 do
        assert length(Strip.resample(Enum.map(1..16, &(&1 / 16)), count)) == count
      end
    end
  end

  describe "resample/3 edge cases" do
    test "an empty band list yields silence at the requested length" do
      assert Strip.resample([], 4) == [0.0, 0.0, 0.0, 0.0]
    end

    test "an exact match passes straight through" do
      assert Strip.resample([0.1, 0.2, 0.3], 3) == [0.1, 0.2, 0.3]
    end
  end

  describe "render/3" do
    test "produces one colour per LED" do
      colours = Strip.render(frame(), 24)

      assert length(colours) == 24
      assert Enum.all?(colours, fn {r, g, b} -> r in 0..255 and g in 0..255 and b in 0..255 end)
    end

    test "colours by position so the ends differ" do
      colours = Strip.render(frame(bands: [1.0, 1.0, 1.0]), 16, palette: :rainbow)

      assert hd(colours) != List.last(colours)
    end

    test "colours the whole strip alike when not colouring by position" do
      colours = Strip.render(frame(bands: [1.0, 1.0, 1.0]), 16, color_by: :pitch)

      assert length(Enum.uniq(colours)) == 1
    end

    # Colouring by pitch pins every LED to one palette position, so brightness
    # is the only thing left varying. At pitch 1.0 that position is white in
    # :mono, which makes the scaling readable straight off the tuple.
    @brightness_only [palette: :mono, color_by: :pitch]

    test "brightness follows each band's own level" do
      dark = Strip.render(frame(bands: [0.0], pitch: 1.0), 4, @brightness_only)
      bright = Strip.render(frame(bands: [1.0], pitch: 1.0), 4, @brightness_only)

      assert hd(dark) == {0, 0, 0}
      assert hd(bright) == {255, 255, 255}
    end

    test "reads the peak-hold caps when asked" do
      frame = frame(bands: [0.0], peaks: [1.0], pitch: 1.0)

      assert hd(Strip.render(frame, 4, [source: :peaks] ++ @brightness_only)) == {255, 255, 255}
      assert hd(Strip.render(frame, 4, @brightness_only)) == {0, 0, 0}
    end

    test "floor lifts unlit LEDs off black" do
      colours = Strip.render(frame(bands: [0.0], pitch: 1.0), 4, [floor: 0.5] ++ @brightness_only)

      assert hd(colours) == {128, 128, 128}
    end

    test "gain scales brightness and stays clamped" do
      colours =
        Strip.render(frame(bands: [0.1], pitch: 1.0), 4, [gain: 100.0] ++ @brightness_only)

      assert hd(colours) == {255, 255, 255}
    end

    test "resample options carry through" do
      blocks =
        Strip.render(
          frame(bands: [0.0, 1.0], pitch: 1.0),
          4,
          [interpolation: :nearest] ++ @brightness_only
        )

      assert blocks == [{0, 0, 0}, {0, 0, 0}, {255, 255, 255}, {255, 255, 255}]
    end
  end

  describe "wash/2" do
    test "brightness comes from the frame level" do
      assert Strip.wash(frame(level: 1.0, centroid: 1.0), palette: :mono) == {255, 255, 255}
      assert Strip.wash(frame(level: 0.0, centroid: 1.0), palette: :mono) == {0, 0, 0}
    end

    test "falls back to the centroid when asked to colour by position" do
      by_position = Strip.wash(frame(centroid: 0.9), color_by: :position)
      by_centroid = Strip.wash(frame(centroid: 0.9), color_by: :centroid)

      assert by_position == by_centroid
    end

    test "follows pitch when asked" do
      low = Strip.wash(frame(pitch: 0.0), color_by: :pitch, palette: :rainbow)
      high = Strip.wash(frame(pitch: 1.0), color_by: :pitch, palette: :rainbow)

      assert low != high
    end
  end

  describe "waterfall/3" do
    test "renders one row of colours per frame" do
      rows = Strip.waterfall([frame(), frame(), frame()], 8)

      assert length(rows) == 3
      assert Enum.all?(rows, &(length(&1) == 8))
    end

    test "an empty history draws nothing rather than failing" do
      assert Strip.waterfall([], 8) == []
    end

    test "uses the same options as the strip above it" do
      [row] = Strip.waterfall([frame(bands: [1.0])], 4, palette: :mono)

      # Mono is greyscale, so agreeing channels prove the palette carried in.
      assert Enum.all?(row, fn {r, g, b} -> r == g and g == b end)
      assert row == Strip.render(frame(bands: [1.0]), 4, palette: :mono)
    end
  end
end
