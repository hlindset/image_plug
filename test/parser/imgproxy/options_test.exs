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
end
