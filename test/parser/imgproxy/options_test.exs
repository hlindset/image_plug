defmodule ImagePlug.Parser.Imgproxy.OptionsTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Parser.Imgproxy.Options
  alias ImagePlug.Parser.Imgproxy.Presets
  alias ImagePlug.Plan.Color

  test "parses dense pipeline state into one pipeline request" do
    assert {:ok, request} =
             Options.parse(
               ~w(rs:fit:100:0 mw:300 mh:200 z:2:3 dpr:2 c:0.5:0.25:nowe:10:-5 ar:true rot:-90 fl:true:false exar:16:9),
               Presets.empty()
             )

    [pipeline] = request.pipelines
    assert pipeline.width == {:pixels, 100}
    assert pipeline.height == {:pixels, 0}
    assert pipeline.min_width == {:pixels, 300}
    assert pipeline.min_height == {:pixels, 200}
    assert pipeline.zoom_x == 2.0
    assert pipeline.zoom_y == 3.0
    assert pipeline.dpr == 2.0
    assert pipeline.crop.width == {:scale, 0.5}
    assert pipeline.crop.height == {:scale, 0.25}
    assert pipeline.crop.gravity == {:anchor, :left, :top}
    assert pipeline.orientation.auto_orient == true
    assert pipeline.orientation.rotate == 270
    assert pipeline.orientation.flip == :horizontal
    assert pipeline.extend_aspect_ratio == {16, 9}
  end

  test "applies padding and background accumulation against current pipeline state" do
    assert {:ok, request} =
             Options.parse(~w(pd:10:20:30:40 padding:0 bg:f00 bga:0.5), Presets.empty())

    [pipeline] = request.pipelines
    assert pipeline.padding_top == 0
    assert pipeline.padding_right == 0
    assert pipeline.padding_bottom == 0
    assert pipeline.padding_left == 0
    assert %Color{channels: {255, 0, 0}, alpha: {:ratio, 1, 2}} = pipeline.background_color
  end

  test "applies default presets and queued preset groups without changing URL option order semantics" do
    assert {:ok, presets} = Presets.validate_config(%{"default" => "w:100/-/h:200"})
    assert {:ok, request} = Options.parse([], presets)

    assert [first, second] = request.pipelines
    assert first.width == {:pixels, 100}
    assert second.height == {:pixels, 200}
  end

  test "empty segments with no presets produces a single default empty pipeline" do
    assert {:ok, request} = Options.parse([], Presets.empty())
    assert [pipeline] = request.pipelines
    assert pipeline.width == nil
    assert pipeline.height == nil
    assert pipeline.resizing_type == :fit
  end

  test "output-scoped options accumulate in the output field" do
    assert {:ok, request} =
             Options.parse(~w(f:webp q:80 fq:jpeg:70), Presets.empty())

    assert request.output.format == :webp
    assert request.output.quality == {:quality, 80}
    assert request.output.format_qualities == %{jpeg: {:quality, 70}}
  end

  test "cache-scoped options accumulate in the cache field" do
    assert {:ok, request} = Options.parse(~w(cb:abc123), Presets.empty())
    assert request.cache.cachebuster == "abc123"
  end

  test "policy-scoped options accumulate in the policy field" do
    assert {:ok, request} = Options.parse(~w(exp:9999), Presets.empty())
    assert request.policy.expires == 9999
  end

  test "response-scoped options accumulate in the response field" do
    assert {:ok, request} = Options.parse(~w(fn:report att:true), Presets.empty())
    assert request.response.filename == "report"
    assert request.response.disposition == :attachment
  end

  test "pipeline separator - creates a new pipeline from accumulated state" do
    assert {:ok, request} = Options.parse(~w(w:500 - h:200), Presets.empty())
    assert [first, second] = request.pipelines
    assert first.width == {:pixels, 500}
    assert second.height == {:pixels, 200}
  end

  test "unknown preset returns error" do
    assert Options.parse(~w(preset:missing), Presets.empty()) ==
             {:error, {:unknown_preset, "missing"}}
  end

  test "invalid option segment returns error" do
    assert {:error, {:invalid_option_segment, "w"}} =
             Options.parse(~w(w), Presets.empty())
  end

  test "unknown option returns error" do
    assert {:error, {:unknown_option, "sharpen"}} =
             Options.parse(~w(sharpen:0.5), Presets.empty())
  end

  test "named preset expands into the pipeline state" do
    assert {:ok, presets} = Presets.validate_config(%{"thumb" => "w:120/h:90"})
    assert {:ok, request} = Options.parse(~w(preset:thumb), presets)
    assert [pipeline] = request.pipelines
    assert pipeline.width == {:pixels, 120}
    assert pipeline.height == {:pixels, 90}
  end

  test "url options after preset overwrite preset fields" do
    assert {:ok, presets} = Presets.validate_config(%{"thumb" => "w:120/h:90"})
    assert {:ok, request} = Options.parse(~w(preset:thumb w:200), presets)
    assert [pipeline] = request.pipelines
    assert pipeline.width == {:pixels, 200}
    assert pipeline.height == {:pixels, 90}
  end

  test "recursive preset is skipped without error" do
    assert {:ok, presets} = Presets.validate_config(%{"loop" => "pr:loop/w:100"})
    assert {:ok, request} = Options.parse(~w(preset:loop), presets)
    assert [pipeline] = request.pipelines
    assert pipeline.width == {:pixels, 100}
  end

  test "returns only known keys in result map" do
    assert {:ok, request} = Options.parse([], Presets.empty())
    assert Map.keys(request) |> Enum.sort() == [:cache, :output, :pipelines, :policy, :response]
  end
end
