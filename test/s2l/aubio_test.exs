defmodule S2l.AubioTest do
  use ExUnit.Case, async: true

  alias S2l.Aubio
  alias S2l.Test.ClickTrack

  doctest S2l.Aubio

  @bpm 120
  @clicks 20
  # The tempo tracker needs a few seconds of evidence before its estimate means
  # anything, so beats are only counted after it has had them.
  @lock_seconds 4

  describe "create/2" do
    test "builds an analyzer carrying its own configuration" do
      assert {:ok, analyzer} = Aubio.create(44_100, hop_size: 256, buf_size: 1024, bands: 8)

      assert %Aubio{sample_rate: 44_100, hop_size: 256, buf_size: 1024, bands: 8} = analyzer
      assert is_reference(analyzer.ref)
      assert Aubio.frame_size(analyzer) == 1024
    end

    test "rejects sizes aubio cannot work with" do
      assert {:error, :badarg} = Aubio.create(0)
      assert {:error, :badarg} = Aubio.create(44_100, hop_size: 0)
      assert {:error, :badarg} = Aubio.create(44_100, bands: 0)
      # A window shorter than the hop leaves the phase vocoder nothing to slide.
      assert {:error, :badarg} = Aubio.create(44_100, buf_size: 256, hop_size: 512)
    end

    test "rejects unknown detection methods without reaching aubio" do
      assert {:error, :unknown_method} = Aubio.create(44_100, onset_method: :nonsense)
      assert {:error, :unknown_method} = Aubio.create(44_100, tempo_method: :nonsense)
    end

    test "accepts every documented onset method" do
      for method <- [:default, :energy, :hfc, :complex, :phase, :specdiff, :kl, :mkl, :specflux] do
        assert {:ok, _analyzer} = Aubio.create(44_100, onset_method: method),
               "onset method #{method} failed to initialize"
      end
    end
  end

  describe "analysis of a 120 BPM click track" do
    setup do
      {:ok, analyzer} = Aubio.create(44_100)
      frames = analyze(analyzer, ClickTrack.synth(bpm: @bpm, clicks: @clicks))

      %{analyzer: analyzer, frames: frames}
    end

    test "locks onto the tempo", %{frames: frames} do
      bpm = List.last(frames).bpm

      assert_in_delta bpm, @bpm, 3
    end

    test "reports confidence in the tempo it found", %{frames: frames} do
      assert List.last(frames).confidence > 0
    end

    test "fires an onset for nearly every click", %{frames: frames} do
      onsets = Enum.count(frames, & &1.onset)

      assert onsets >= 15, "only #{onsets} onsets detected across #{@clicks} clicks"
    end

    test "emits beats once the tempo tracker has locked", %{analyzer: analyzer, frames: frames} do
      lock_frame = round(@lock_seconds * analyzer.sample_rate / analyzer.hop_size)

      beats =
        frames
        |> Enum.drop(lock_frame)
        |> Enum.count(& &1.beat)

      assert beats >= 5, "only #{beats} beats after #{@lock_seconds}s of lock-in time"
    end

    test "produces one non-negative value per band", %{analyzer: analyzer, frames: frames} do
      for frame <- frames do
        assert length(frame.bands) == analyzer.bands
        assert Enum.all?(frame.bands, &(&1 >= 0.0))
      end
    end

    test "band energy tracks the clicks rather than the silence", %{frames: frames} do
      {loud, quiet} = Enum.split_with(frames, & &1.onset)

      assert mean_energy(loud) > 5 * mean_energy(quiet)
    end
  end

  describe "sample rate handling" do
    # A 48 kHz stream analyzed as if it were 44.1 kHz reports a BPM about 9%
    # off and nothing else goes wrong, which is exactly why it is worth a test.
    test "reads tempo correctly at 48 kHz" do
      {:ok, analyzer} = Aubio.create(48_000)
      pcm = ClickTrack.synth(sample_rate: 48_000, bpm: @bpm, clicks: @clicks)

      frames = analyze(analyzer, pcm)

      assert_in_delta List.last(frames).bpm, @bpm, 3
      assert Enum.count(frames, & &1.onset) >= 15
    end

    test "the same audio analyzed at the wrong rate skews the tempo" do
      {:ok, analyzer} = Aubio.create(44_100)
      pcm = ClickTrack.synth(sample_rate: 48_000, bpm: @bpm, clicks: @clicks)

      bpm = analyze(analyzer, pcm) |> List.last() |> Map.fetch!(:bpm)

      assert_in_delta bpm, @bpm * 44_100 / 48_000, 4
    end
  end

  describe "dominant peak" do
    test "reports the frequency of a pure tone" do
      for freq <- [110, 440, 1000, 2500, 6000] do
        {:ok, analyzer} = Aubio.create(48_000)
        frames = analyze(analyzer, tone(freq, 48_000, 24_000))

        # Bins are ~47 Hz apart at this window, so anything close to this
        # implies the sub-bin interpolation is working rather than the raw bin
        # index being reported.
        assert_in_delta List.last(frames).peak_freq,
                        freq,
                        5,
                        "a #{freq} Hz tone was located badly"
      end
    end

    test "prefers the louder of two tones" do
      {:ok, analyzer} = Aubio.create(48_000)
      quiet = tone(400, 48_000, 48_000, 0.1)
      loud = tone(3000, 48_000, 48_000, 0.8)
      mixed = mix(quiet, loud)

      assert_in_delta List.last(analyze(analyzer, mixed)).peak_freq, 3000, 20
    end

    test "reports nothing rather than a spurious bin on silence" do
      {:ok, analyzer} = Aubio.create(48_000)

      frames = analyze(analyzer, :binary.copy(<<0.0::float-32-little>>, 48_000))

      assert List.last(frames).peak_freq == 0.0
      assert List.last(frames).peak_magnitude == 0.0
    end

    test "stays within the representable range for noise" do
      {:ok, analyzer} = Aubio.create(48_000)

      for frame <- analyze(analyzer, :crypto.strong_rand_bytes(48_000 * 4)) do
        assert frame.peak_freq >= 0.0
        assert frame.peak_freq <= 24_000.0
        assert frame.peak_magnitude >= 0.0
      end
    end
  end

  describe "band frequency range" do
    test "confines the bands to the requested range" do
      # A 15 kHz tone is inside the default 40 Hz - 12 kHz window's stopband,
      # so it should barely register, while 6 kHz sits inside it.
      {:ok, narrow} = Aubio.create(48_000)
      inside = analyze(narrow, tone(6000, 48_000, 24_000)) |> List.last()

      {:ok, narrow2} = Aubio.create(48_000)
      outside = analyze(narrow2, tone(15_000, 48_000, 24_000)) |> List.last()

      assert Enum.sum(inside.bands) > 10 * Enum.sum(outside.bands)
    end

    test "widening the range lets high content back in" do
      {:ok, wide} = Aubio.create(48_000, fmax: 20_000)

      frame = analyze(wide, tone(15_000, 48_000, 24_000)) |> List.last()

      assert Enum.sum(frame.bands) > 0.0
      # Content above the mel range's midpoint must land in the upper bands.
      {low, high} = Enum.split(frame.bands, 8)
      assert Enum.sum(high) > Enum.sum(low)
    end

    test "rejects a range that cannot be built" do
      assert {:error, :badarg} = Aubio.create(48_000, fmin: 1000, fmax: 500)
      assert {:error, :badarg} = Aubio.create(48_000, fmin: 100, fmax: 100)
      assert {:error, :badarg} = Aubio.create(48_000, fmin: -5)
    end

    test "clamps the default ceiling to Nyquist on a low-rate stream" do
      # The 12 kHz default is above Nyquist here; it must be pulled down rather
      # than rejected.
      assert {:ok, analyzer} = Aubio.create(16_000)
      assert analyzer.fmax == 8_000.0
    end
  end

  describe "robustness" do
    setup do
      {:ok, analyzer} = Aubio.create(44_100, hop_size: 512)

      %{analyzer: analyzer}
    end

    test "rejects frames that are not exactly one hop", %{analyzer: analyzer} do
      frame_size = Aubio.frame_size(analyzer)

      for size <- [0, 1, frame_size - 4, frame_size - 1, frame_size + 1, frame_size * 2] do
        frame = :binary.copy(<<0>>, size)

        assert {:error, :bad_frame_size} = Aubio.process(analyzer, frame),
               "a #{size} byte frame was accepted"
      end
    end

    test "survives random binaries of random lengths", %{analyzer: analyzer} do
      for _ <- 1..500 do
        frame = :crypto.strong_rand_bytes(Enum.random(0..4096))

        case Aubio.process(analyzer, frame) do
          {:ok, analysis} -> assert_well_formed(analysis, analyzer.bands)
          {:error, :bad_frame_size} -> :ok
        end
      end
    end

    test "survives correctly sized frames of arbitrary bits", %{analyzer: analyzer} do
      # Random bits reinterpreted as floats include NaN and infinities. These
      # must come back as a well-formed result, not a badarg from building the
      # return term and not a crashed VM.
      for _ <- 1..200 do
        frame = :crypto.strong_rand_bytes(Aubio.frame_size(analyzer))

        assert {:ok, analysis} = Aubio.process(analyzer, frame)
        assert_well_formed(analysis, analyzer.bands)
      end
    end

    test "accepts frames that are unaligned sub-binaries", %{analyzer: analyzer} do
      frame_size = Aubio.frame_size(analyzer)
      # Offsetting by one byte inside a larger binary yields a frame whose data
      # pointer is not float-aligned, which the NIF has to copy rather than
      # alias.
      padded = :binary.copy(<<0.25::float-32-little>>, 600)
      unaligned = binary_part(padded, 1, frame_size)

      assert {:ok, analysis} = Aubio.process(analyzer, unaligned)
      assert_well_formed(analysis, analyzer.bands)
    end

    test "reclaims analyzers that go out of scope" do
      for _ <- 1..200 do
        {:ok, analyzer} = Aubio.create(44_100, buf_size: 128, hop_size: 64, bands: 8)
        frame = :binary.copy(<<0.0::float-32-little>>, 64)

        assert {:ok, _analysis} = Aubio.process(analyzer, frame)
      end

      :erlang.garbage_collect()

      # Still usable afterwards: the destructor freed the dropped analyzers and
      # nothing else.
      assert {:ok, analyzer} = Aubio.create(44_100)
      assert {:ok, _analysis} = Aubio.process(analyzer, silent_frame(analyzer))
    end

    test "keeps working when frames are fed from several processes" do
      {:ok, analyzer} = Aubio.create(44_100)
      frame = silent_frame(analyzer)

      results =
        1..8
        |> Task.async_stream(fn _ ->
          Enum.map(1..50, fn _ -> Aubio.process(analyzer, frame) end)
        end)
        |> Enum.flat_map(fn {:ok, results} -> results end)

      assert Enum.all?(results, &match?({:ok, _analysis}, &1))
    end
  end

  defp analyze(analyzer, pcm) do
    frame_size = Aubio.frame_size(analyzer)

    for <<frame::binary-size(^frame_size) <- pcm>> do
      {:ok, analysis} = Aubio.process(analyzer, frame)
      analysis
    end
  end

  defp tone(freq, sample_rate, samples, amplitude \\ 0.5) do
    for i <- 0..(samples - 1), into: <<>> do
      <<amplitude * :math.sin(2 * :math.pi() * freq * i / sample_rate)::float-32-little>>
    end
  end

  defp mix(left, right) do
    samples = fn pcm -> for <<sample::float-32-little <- pcm>>, do: sample end

    left
    |> samples.()
    |> Enum.zip_with(samples.(right), &+/2)
    |> Enum.map(&<<&1::float-32-little>>)
    |> IO.iodata_to_binary()
  end

  defp assert_well_formed(analysis, bands) do
    assert is_boolean(analysis.beat)
    assert is_boolean(analysis.onset)
    assert is_float(analysis.bpm)
    assert is_float(analysis.confidence)
    assert length(analysis.bands) == bands
    assert Enum.all?(analysis.bands, &is_float/1)
  end

  defp silent_frame(analyzer) do
    :binary.copy(<<0.0::float-32-little>>, analyzer.hop_size)
  end

  defp mean_energy([]), do: 0.0

  defp mean_energy(frames) do
    Enum.sum(Enum.map(frames, &Enum.sum(&1.bands))) / length(frames)
  end
end
