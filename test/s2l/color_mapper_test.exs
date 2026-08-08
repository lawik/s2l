defmodule S2l.ColorMapperTest do
  use ExUnit.Case, async: true

  alias S2l.ColorMapper

  # Fast ticks keep the suite quick; the behaviour under test is per-frame, not
  # per-second.
  @fps 200
  @tick_ms 5

  defp start_mapper(opts \\ []) do
    name = :"mapper_#{System.unique_integer([:positive])}"
    opts = Keyword.merge([name: name, fps: @fps], opts)

    {:ok, _pid} = start_supervised({ColorMapper, opts}, id: name)

    name
  end

  defp analysis(opts) do
    %{
      beat: Keyword.get(opts, :beat, false),
      bpm: Keyword.get(opts, :bpm, 0.0),
      confidence: Keyword.get(opts, :confidence, 0.0),
      onset: Keyword.get(opts, :onset, false),
      bands: Keyword.fetch!(opts, :bands)
    }
  end

  defp settle(mapper, analysis, count) do
    for _ <- 1..count, do: ColorMapper.push(mapper, analysis)

    # A call flushes the preceding casts, then one tick guarantees the frame
    # reflects them.
    _flush = ColorMapper.frame(mapper)
    Process.sleep(@tick_ms * 3)

    ColorMapper.frame(mapper)
  end

  describe "frames" do
    test "start black and silent" do
      mapper = start_mapper()
      frame = ColorMapper.frame(mapper)

      assert frame.level == 0.0
      assert frame.beat == false
      assert frame.bands == []
    end

    test "are delivered to subscribers on a clock, without any audio" do
      mapper = start_mapper()

      :ok = ColorMapper.subscribe(mapper)

      assert_receive {:s2l_frame, %{level: _level}}, 500
      assert_receive {:s2l_frame, %{level: _level}}, 500
    end

    test "stop when unsubscribed" do
      mapper = start_mapper()

      :ok = ColorMapper.subscribe(mapper)
      assert_receive {:s2l_frame, _frame}, 500
      :ok = ColorMapper.unsubscribe(mapper)

      # Drain whatever was already in flight before checking for silence.
      Process.sleep(@tick_ms * 4)
      _inflight = flush_frames()

      refute_receive {:s2l_frame, _frame}, 100
    end

    test "carry the tempo estimate through untouched" do
      mapper = start_mapper()

      frame = settle(mapper, analysis(bands: [1.0, 1.0], bpm: 128.5), 3)

      assert frame.bpm == 128.5
    end
  end

  describe "level" do
    test "rises towards loud audio and falls away from it" do
      mapper = start_mapper()

      loud = settle(mapper, analysis(bands: [1.0, 1.0, 1.0]), 40)
      assert loud.level > 0.5

      # Automatic gain keeps its reference through the quiet, so near-silence
      # reads as near-zero rather than being renormalised back up to full.
      quiet = settle(mapper, analysis(bands: [0.0001, 0.0001, 0.0001]), 60)
      assert quiet.level < loud.level
    end

    test "rises faster than it falls" do
      mapper = start_mapper(attack: 0.5, decay: 0.05)
      silence = analysis(bands: [0.0, 0.0, 0.0])
      loud = analysis(bands: [1.0, 1.0, 1.0])

      # Establish the gain reference, then drop to silence and back.
      _warm = settle(mapper, loud, 40)
      _quiet = settle(mapper, silence, 40)

      before = ColorMapper.frame(mapper).level
      ColorMapper.push(mapper, loud)
      Process.sleep(@tick_ms * 3)
      after_one_loud = ColorMapper.frame(mapper).level

      rise = after_one_loud - before

      ColorMapper.push(mapper, silence)
      Process.sleep(@tick_ms * 3)
      fall = after_one_loud - ColorMapper.frame(mapper).level

      assert rise > fall
    end

    test "is bounded to 0..1 even with a beat spike on top" do
      mapper = start_mapper(beat_boost: 0.9)

      frame = settle(mapper, analysis(bands: [1.0, 1.0], beat: true), 40)

      assert frame.level <= 1.0
      assert frame.level >= 0.0
    end
  end

  describe "hue" do
    test "sits at the bass end for bass-heavy audio" do
      mapper = start_mapper(hue_smoothing: 1.0, hue_range: {0.0, 260.0})

      frame = settle(mapper, analysis(bands: [1.0, 0.0, 0.0, 0.0]), 5)

      assert frame.hue < 40
    end

    test "moves to the treble end for treble-heavy audio" do
      mapper = start_mapper(hue_smoothing: 1.0, hue_range: {0.0, 260.0})

      frame = settle(mapper, analysis(bands: [0.0, 0.0, 0.0, 1.0]), 5)

      assert frame.hue > 220
    end

    test "stays within the configured range" do
      mapper = start_mapper(hue_smoothing: 1.0, hue_range: {200.0, 360.0})

      for bands <- [[1.0, 0.0], [0.0, 1.0], [0.5, 0.5], [1.0, 1.0]] do
        frame = settle(mapper, analysis(bands: bands), 5)

        assert frame.hue >= 200.0
        assert frame.hue <= 360.0
      end
    end
  end

  describe "beats" do
    test "raise the level and then fade" do
      mapper = start_mapper(beat_boost: 0.5, beat_decay: 0.1)

      # Set the gain reference against something loud, then drop to a quieter
      # passage. Sustained full-scale audio already sits at level 1.0, where a
      # spike has nowhere to go and would be invisible.
      _loud = settle(mapper, analysis(bands: [1.0, 1.0]), 30)
      _quiet = settle(mapper, analysis(bands: [0.3, 0.3]), 40)
      steady = ColorMapper.frame(mapper).level

      assert steady < 0.9, "no headroom left for a beat spike to show"

      # Watched through a subscription rather than polled: the flag marks an
      # instant, so it is true for a single frame and polling would race it.
      :ok = ColorMapper.subscribe(mapper)
      Process.sleep(@tick_ms * 2)
      flush_frames()

      ColorMapper.push(mapper, analysis(bands: [0.3, 0.3], beat: true))
      Process.sleep(@tick_ms * 15)

      frames = collect_frames([])
      spiked = Enum.find(frames, & &1.beat)

      assert spiked, "no frame carried the beat"
      assert spiked.level > steady

      faded = List.last(frames)

      assert faded.beat == false
      assert faded.level < spiked.level
    end
  end

  describe "bands" do
    test "are normalized to 0..1 regardless of input scale" do
      mapper = start_mapper()

      for scale <- [0.001, 1.0, 1000.0] do
        frame = settle(mapper, analysis(bands: [scale, scale / 2, 0.0]), 30)

        assert length(frame.bands) == 3
        assert Enum.all?(frame.bands, &(&1 >= 0.0 and &1 <= 1.0))
        assert Enum.max(frame.bands) > 0.5
      end
    end
  end

  describe "configure/2" do
    test "changes behaviour on a running mapper" do
      mapper = start_mapper(hue_range: {0.0, 100.0}, hue_smoothing: 1.0)

      assert settle(mapper, analysis(bands: [0.0, 1.0]), 5).hue <= 100.0

      :ok = ColorMapper.configure(mapper, hue_range: {300.0, 360.0})

      assert settle(mapper, analysis(bands: [0.0, 1.0]), 5).hue >= 300.0
    end
  end

  test "drops subscribers that die" do
    mapper = start_mapper()

    {pid, ref} = spawn_monitor(fn -> ColorMapper.subscribe(mapper) end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500

    # Frames keep flowing to everyone else rather than the mapper crashing on a
    # dead subscriber.
    :ok = ColorMapper.subscribe(mapper)
    assert_receive {:s2l_frame, _frame}, 500
  end

  defp flush_frames do
    receive do
      {:s2l_frame, _frame} -> flush_frames()
    after
      0 -> :ok
    end
  end

  defp collect_frames(acc) do
    receive do
      {:s2l_frame, frame} -> collect_frames([frame | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
