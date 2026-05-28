defmodule ImagePipe.Parser.Imgproxy.OptionGrammarTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Parser.Imgproxy.CropRequest
  alias ImagePipe.Parser.Imgproxy.OptionGrammar
  alias ImagePipe.Plan.Color

  property "zoom aliases parse equivalent zoom_x and zoom_y assignments" do
    check all x_int <- integer(1..2000),
              y_int <- integer(1..2000),
              max_runs: 200 do
      x = decimal_string(x_int)
      y = decimal_string(y_int)

      assert OptionGrammar.parse("zoom:#{x}:#{y}") == OptionGrammar.parse("z:#{x}:#{y}")
    end
  end

  test "resize full grammar preserves explicit extend_requested assignment" do
    assert OptionGrammar.parse("resize:fill:300:200:1:0") ==
             {:ok,
              {:pipeline,
               [
                 resizing_type: :fill,
                 width: {:pixels, 300},
                 height: {:pixels, 200},
                 enlarge: true,
                 extend: false,
                 extend_requested: true
               ]}}
  end

  test "gravity offsets parse pixels, zero pixels, and scale offsets" do
    assert OptionGrammar.parse("g:soea:12:-0.25") ==
             {:ok,
              {:pipeline,
               [
                 gravity: {:anchor, :right, :bottom},
                 gravity_x_offset: {:pixels, 12.0},
                 gravity_y_offset: {:scale, -0.25}
               ]}}

    assert OptionGrammar.parse("gravity:ce:0:0") ==
             {:ok,
              {:pipeline,
               [
                 gravity: {:anchor, :center, :center},
                 gravity_x_offset: {:pixels, 0.0},
                 gravity_y_offset: {:pixels, 0.0}
               ]}}
  end

  test "crop focal point and relative offsets parse into crop requests" do
    assert OptionGrammar.parse("c:100:100:fp:0.25:0.75") ==
             {:ok,
              {:pipeline,
               [
                 crop: %CropRequest{
                   width: {:pixels, 100},
                   height: {:pixels, 100},
                   gravity: {:fp, 0.25, 0.75}
                 }
               ]}}

    assert OptionGrammar.parse("crop:100:200:nowe:0.25:-0.5") ==
             {:ok,
              {:pipeline,
               [
                 crop: %CropRequest{
                   width: {:pixels, 100},
                   height: {:pixels, 200},
                   gravity: {:anchor, :left, :top},
                   x_offset: {:scale, 0.25},
                   y_offset: {:scale, -0.5}
                 }
               ]}}
  end

  test "malformed padding and background options keep current error shapes" do
    assert OptionGrammar.parse("padding:1:2:3:4:5") ==
             {:error, {:invalid_option_segment, "padding:1:2:3:4:5"}}

    assert OptionGrammar.parse("padding:-1") ==
             {:error, {:invalid_option_segment, "padding:-1"}}

    assert OptionGrammar.parse("padding:one") ==
             {:error, {:invalid_option_segment, "padding:one"}}

    assert OptionGrammar.parse("background:256:0:0") ==
             {:error, {:invalid_background, ["256", "0", "0"]}}

    assert OptionGrammar.parse("background:1:2") ==
             {:error, {:invalid_background, ["1", "2"]}}

    assert OptionGrammar.parse("background:1::2") ==
             {:error, {:invalid_background, ["1", "", "2"]}}

    assert OptionGrammar.parse("background:ffff") ==
             {:error, {:invalid_background, "ffff"}}

    assert OptionGrammar.parse("background_alpha:") ==
             {:error, {:invalid_background_alpha, [""]}}

    assert OptionGrammar.parse("bga:1.1") ==
             {:error, {:invalid_background_alpha, "1.1"}}
  end

  test "background alpha accepts fully transparent zero" do
    assert OptionGrammar.parse("bga:0") ==
             {:ok, {:pipeline, [background_alpha: {:ratio, 0, 1}]}}

    assert OptionGrammar.parse("bga:0.0") ==
             {:ok, {:pipeline, [background_alpha: {:ratio, 0, 10}]}}
  end

  test "basic effect options parse with imgproxy aliases" do
    assert OptionGrammar.parse("blur:2.5") == {:ok, {:pipeline, [blur: 2.5]}}
    assert OptionGrammar.parse("bl:3") == {:ok, {:pipeline, [blur: 3.0]}}
    assert OptionGrammar.parse("bl:0") == {:ok, {:pipeline, [blur: 0.0]}}

    assert OptionGrammar.parse("sharpen:0.7") == {:ok, {:pipeline, [sharpen: 0.7]}}
    assert OptionGrammar.parse("sh:1") == {:ok, {:pipeline, [sharpen: 1.0]}}
    assert OptionGrammar.parse("sh:0") == {:ok, {:pipeline, [sharpen: 0.0]}}

    assert OptionGrammar.parse("pixelate:8") == {:ok, {:pipeline, [pixelate: 8]}}
    assert OptionGrammar.parse("pix:12") == {:ok, {:pipeline, [pixelate: 12]}}
    assert OptionGrammar.parse("pix:0") == {:ok, {:pipeline, [pixelate: 0]}}
  end

  test "tone effect options parse with imgproxy aliases" do
    assert OptionGrammar.parse("monochrome:0.5") ==
             {:ok, {:pipeline, [monochrome: [intensity: {:ratio, 5, 10}]]}}

    assert OptionGrammar.parse("mc:1:ffcc00") ==
             {:ok,
              {:pipeline,
               [
                 monochrome: [
                   intensity: {:ratio, 1, 1},
                   color: color!(255, 204, 0)
                 ]
               ]}}

    assert OptionGrammar.parse("mc:1:") ==
             {:ok, {:pipeline, [monochrome: [intensity: {:ratio, 1, 1}]]}}

    assert OptionGrammar.parse("duotone:0.25") ==
             {:ok, {:pipeline, [duotone: [intensity: {:ratio, 25, 100}]]}}

    assert OptionGrammar.parse("dt:0.5:112233") ==
             {:ok,
              {:pipeline,
               [
                 duotone: [
                   intensity: {:ratio, 5, 10},
                   shadow: color!(17, 34, 51)
                 ]
               ]}}

    assert OptionGrammar.parse("dt:0.5::ffeecc") ==
             {:ok,
              {:pipeline,
               [
                 duotone: [
                   intensity: {:ratio, 5, 10},
                   highlight: color!(255, 238, 204)
                 ]
               ]}}

    assert OptionGrammar.parse("dt:1:112233:ffeecc") ==
             {:ok,
              {:pipeline,
               [
                 duotone: [
                   intensity: {:ratio, 1, 1},
                   shadow: color!(17, 34, 51),
                   highlight: color!(255, 238, 204)
                 ]
               ]}}
  end

  test "invalid tone effect options return parser errors" do
    assert OptionGrammar.parse("mc:") == {:error, {:invalid_option_segment, "mc:"}}
    assert OptionGrammar.parse("mc:1.1") == {:error, {:invalid_intensity, "1.1"}}
    assert OptionGrammar.parse("mc:0.5:zzzzzz") == {:error, {:invalid_monochrome, "zzzzzz"}}

    assert OptionGrammar.parse("mc:0.5:ffffff:000000") ==
             {:error, {:invalid_option_segment, "mc:0.5:ffffff:000000"}}

    assert OptionGrammar.parse("dt:0.5:fffxxx") == {:error, {:invalid_duotone, "fffxxx"}}

    assert OptionGrammar.parse("dt:0.5:ffffff:zzzzzz") ==
             {:error, {:invalid_duotone, ["ffffff", "zzzzzz"]}}
  end

  test "invalid arity pipeline options return invalid option segment errors" do
    for segment <- invalid_pipeline_arity_segments() do
      assert OptionGrammar.parse(segment) == {:error, {:invalid_option_segment, segment}}
    end
  end

  test "dropped options return unknown option errors" do
    for segment <- ~w(
          raw max_bytes mb max_src_resolution msr max_src_file_size msfs
          raw:false max_bytes:100 mb:100
        ) do
      [name | _args] = String.split(segment, ":")

      assert OptionGrammar.parse(segment) == {:error, {:unknown_option, name}}
    end
  end

  defp invalid_pipeline_arity_segments do
    ~w(
      zoom zoom: zoom:1:2:3 z z: z:1:2:3 dpr dpr: dpr:1:2
      min-width min-width:1:2 mw mw:1:2 min_width min_width:1:2
      min-height min-height:1:2 mh mh:1:2 min_height min_height:1:2
      enlarge enlarge:true:false el el:true:false
      extend extend: extend:true:ce:0 extend:true:ce:0:0:extra
      ex ex: ex:true:ce:0 ex:true:ce:0:0:extra
      gravity gravity:ce:0 gravity:ce:0:0:extra
      g g:ce:0 g:ce:0:0:extra
      auto_rotate: auto_rotate:true:false ar: ar:true:false
      rotate rotate: rotate:90:180 rot rot: rot:90:180
      flip:true:false:true fl:true:false:true
      blur blur: bl bl: blur:1:2 bl:1:2
      sharpen sharpen: sh sh: sharpen:1:2 sh:1:2
      pixelate pixelate: pix pix: pixelate:1:2 pix:1:2
      monochrome monochrome: mc mc: monochrome:1:2:3 mc:1:2:3
      duotone duotone: dt dt: dt:1:2:3:4
      extend_aspect_ratio extend_aspect_ratio:1:no:0:0:extra
      extend_ar extend_ar:1:no:0:0:extra
      exar exar:1:no:0:0:extra
      crop crop:100 crop:100:200:ce:0 crop:100:200:ce:0:0:extra
      c c:100 c:100:200:ce:0 c:100:200:ce:0:0:extra
    )
  end

  defp color!(red, green, blue) do
    assert {:ok, color} = Color.rgb(red, green, blue)
    color
  end

  defp decimal_string(value), do: :erlang.float_to_binary(value / 10, decimals: 1)
end
