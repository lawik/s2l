defmodule S2l.Membrane.AnalyzerTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias Membrane.RawAudio
  alias Membrane.Testing
  alias S2l.Test.ClickTrack

  @bpm 120
  @clicks 20

  # Feeding the click track through a real pipeline rather than a live
  # microphone is what makes this runnable in CI, and it means a regression in
  # the element is distinguishable from a bad input device.
  defp run(pcm, opts) do
    owner = self()
    sample_rate = Keyword.get(opts, :sample_rate, 44_100)
    buffer_size = Keyword.get(opts, :buffer_size, 4096)

    spec =
      child(:source, %Testing.Source{
        output: chunks(pcm, buffer_size),
        stream_format: %RawAudio{sample_format: :f32le, channels: 1, sample_rate: sample_rate}
      })
      |> child(:analyzer, %S2l.Membrane.Analyzer{
        handler: fn analysis -> send(owner, {:analysis, analysis}) end,
        hop_size: Keyword.get(opts, :hop_size, 512)
      })

    pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_end_of_stream(pipeline, :analyzer, :input, 10_000)
    Testing.Pipeline.terminate(pipeline)

    collect([])
  end

  # Deliberately not a multiple of the hop size: a real source has no reason to
  # align its buffers to whatever the analyzer happens to want. The trailing
  # short buffer is kept for the same reason.
  defp chunks(<<>>, _size), do: []
  defp chunks(pcm, size) when byte_size(pcm) <= size, do: [pcm]

  defp chunks(pcm, size) do
    <<chunk::binary-size(size), rest::binary>> = pcm

    [chunk | chunks(rest, size)]
  end

  defp collect(acc) do
    receive do
      {:analysis, analysis} -> collect([analysis | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "analyzing a click track through a pipeline" do
    setup do
      %{frames: run(ClickTrack.synth(bpm: @bpm, clicks: @clicks), [])}
    end

    test "reaches the same conclusions as calling the analyzer directly", %{frames: frames} do
      assert Enum.count(frames, & &1.onset) >= 15
      assert_in_delta List.last(frames).bpm, @bpm, 3
    end

    test "emits one analysis per whole hop, regardless of buffer sizes", %{frames: frames} do
      # 4096-byte buffers carve unevenly into 2048-byte hops, so this only holds
      # if the element is carrying the remainder across buffers.
      pcm_bytes = byte_size(ClickTrack.synth(bpm: @bpm, clicks: @clicks))

      assert length(frames) == div(pcm_bytes, 512 * 4)
    end
  end

  test "picks up the sample rate from the stream format" do
    pcm = ClickTrack.synth(sample_rate: 48_000, bpm: @bpm, clicks: @clicks)

    frames = run(pcm, sample_rate: 48_000)

    # Analyzed at 44.1 kHz this would land near 110. Getting 120 proves the rate
    # travelled from the stream format into the analyzer.
    assert_in_delta List.last(frames).bpm, @bpm, 3
  end

  test "handles buffer sizes that are smaller than one hop" do
    pcm = ClickTrack.synth(bpm: @bpm, clicks: 8)

    frames = run(pcm, buffer_size: 100)

    assert length(frames) == div(byte_size(pcm), 512 * 4)
    assert Enum.count(frames, & &1.onset) >= 6
  end
end
