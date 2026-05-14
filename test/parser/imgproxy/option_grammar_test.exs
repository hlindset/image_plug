defmodule ImagePlug.Parser.Imgproxy.OptionGrammarTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePlug.Parser.Imgproxy.CropRequest
  alias ImagePlug.Parser.Imgproxy.OptionGrammar

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

    assert OptionGrammar.parse("bga:0") ==
             {:error, {:invalid_background_alpha, "0"}}

    assert OptionGrammar.parse("bga:1.1") ==
             {:error, {:invalid_background_alpha, "1.1"}}
  end

  test "invalid arity pipeline options return invalid option segment errors" do
    for segment <- invalid_pipeline_arity_segments() do
      assert OptionGrammar.parse(segment) == {:error, {:invalid_option_segment, segment}}
    end
  end

  test "dropped options return unknown option errors" do
    for segment <- ~w(
          raw max_bytes mb max_src_resolution msr max_src_file_size msfs crop_aspect_ratio
          crop_ar car raw:false max_bytes:100 mb:100 crop_ar:1:1
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
      extend_aspect_ratio extend_aspect_ratio:16 extend_aspect_ratio:16:9:1
      extend_ar extend_ar:16 extend_ar:16:9:1
      exar exar:16 exar:16:9:1
      crop crop:100 crop:100:200:ce:0 crop:100:200:ce:0:0:extra
      c c:100 c:100:200:ce:0 c:100:200:ce:0:0:extra
    )
  end

  defp decimal_string(value), do: :erlang.float_to_binary(value / 10, decimals: 1)

  describe "basic pipeline-scoped options" do
    test "width and height aliases parse pixel dimensions" do
      assert OptionGrammar.parse("w:300") == {:ok, {:pipeline, [width: {:pixels, 300}]}}
      assert OptionGrammar.parse("width:300") == {:ok, {:pipeline, [width: {:pixels, 300}]}}
      assert OptionGrammar.parse("h:200") == {:ok, {:pipeline, [height: {:pixels, 200}]}}
      assert OptionGrammar.parse("height:200") == {:ok, {:pipeline, [height: {:pixels, 200}]}}
    end

    test "width and height accept zero as a valid pixel dimension" do
      assert OptionGrammar.parse("w:0") == {:ok, {:pipeline, [width: {:pixels, 0}]}}
      assert OptionGrammar.parse("h:0") == {:ok, {:pipeline, [height: {:pixels, 0}]}}
    end

    test "resizing_type and rt aliases parse supported types" do
      for {value, expected} <- [
            {"fit", :fit},
            {"fill", :fill},
            {"fill-down", :fill_down},
            {"force", :force},
            {"auto", :auto}
          ] do
        assert OptionGrammar.parse("rt:#{value}") ==
                 {:ok, {:pipeline, [resizing_type: expected]}}

        assert OptionGrammar.parse("resizing_type:#{value}") ==
                 {:ok, {:pipeline, [resizing_type: expected]}}
      end
    end

    test "min-width, min_width, and mw aliases parse pixel dimensions" do
      assert OptionGrammar.parse("min-width:100") ==
               {:ok, {:pipeline, [min_width: {:pixels, 100}]}}

      assert OptionGrammar.parse("min_width:100") ==
               {:ok, {:pipeline, [min_width: {:pixels, 100}]}}

      assert OptionGrammar.parse("mw:100") == {:ok, {:pipeline, [min_width: {:pixels, 100}]}}
    end

    test "min-height, min_height, and mh aliases parse pixel dimensions" do
      assert OptionGrammar.parse("min-height:80") ==
               {:ok, {:pipeline, [min_height: {:pixels, 80}]}}

      assert OptionGrammar.parse("min_height:80") ==
               {:ok, {:pipeline, [min_height: {:pixels, 80}]}}

      assert OptionGrammar.parse("mh:80") == {:ok, {:pipeline, [min_height: {:pixels, 80}]}}
    end

    test "enlarge and el aliases parse boolean values" do
      assert OptionGrammar.parse("enlarge:1") == {:ok, {:pipeline, [enlarge: true]}}
      assert OptionGrammar.parse("el:false") == {:ok, {:pipeline, [enlarge: false]}}
      assert OptionGrammar.parse("enlarge:t") == {:ok, {:pipeline, [enlarge: true]}}
    end

    test "dpr parses positive float values" do
      assert OptionGrammar.parse("dpr:2") == {:ok, {:pipeline, [dpr: 2.0]}}
      assert OptionGrammar.parse("dpr:1.5") == {:ok, {:pipeline, [dpr: 1.5]}}
    end

    test "zoom parses uniform and independent zoom factors" do
      assert OptionGrammar.parse("zoom:2") == {:ok, {:pipeline, [zoom_x: 2.0, zoom_y: 2.0]}}
      assert OptionGrammar.parse("z:1.5") == {:ok, {:pipeline, [zoom_x: 1.5, zoom_y: 1.5]}}
      assert OptionGrammar.parse("zoom:2:3") == {:ok, {:pipeline, [zoom_x: 2.0, zoom_y: 3.0]}}
    end
  end

  describe "output-scoped options" do
    test "format, f, and ext aliases parse supported formats" do
      assert OptionGrammar.parse("format:webp") == {:ok, {:output, [format: :webp]}}
      assert OptionGrammar.parse("f:avif") == {:ok, {:output, [format: :avif]}}
      assert OptionGrammar.parse("ext:jpeg") == {:ok, {:output, [format: :jpeg]}}
      assert OptionGrammar.parse("f:jpg") == {:ok, {:output, [format: :jpeg]}}
      assert OptionGrammar.parse("f:png") == {:ok, {:output, [format: :png]}}
      assert OptionGrammar.parse("f:best") == {:ok, {:output, [format: :best]}}
    end

    test "quality and q aliases parse quality levels 1-100 and zero as default" do
      assert OptionGrammar.parse("quality:80") == {:ok, {:output, [quality: {:quality, 80}]}}
      assert OptionGrammar.parse("q:1") == {:ok, {:output, [quality: {:quality, 1}]}}
      assert OptionGrammar.parse("q:100") == {:ok, {:output, [quality: {:quality, 100}]}}
      assert OptionGrammar.parse("q:0") == {:ok, {:output, [quality: :default]}}
    end

    test "format_quality and fq aliases produce per-format quality maps" do
      assert OptionGrammar.parse("fq:webp:80") ==
               {:ok, {:output, [format_qualities: %{webp: {:quality, 80}}]}}

      assert OptionGrammar.parse("format_quality:jpeg:50") ==
               {:ok, {:output, [format_qualities: %{jpeg: {:quality, 50}}]}}

      assert OptionGrammar.parse("fq:jpg:60") ==
               {:ok, {:output, [format_qualities: %{jpeg: {:quality, 60}}]}}

      assert OptionGrammar.parse("fq:webp:0") ==
               {:ok, {:output, [format_qualities: %{webp: :default}]}}
    end

    test "invalid format returns error with list of allowed formats" do
      assert OptionGrammar.parse("f:gif") ==
               {:error, {:invalid_format, "gif", ["webp", "avif", "jpeg", "jpg", "png", "best"]}}
    end

    test "invalid quality values return quality option errors" do
      assert OptionGrammar.parse("q:101") == {:error, {:invalid_option, :quality, "101"}}
      assert OptionGrammar.parse("q:-1") == {:error, {:invalid_option, :quality, "-1"}}
    end
  end

  describe "cache-scoped options" do
    test "cachebuster and cb aliases parse string values" do
      assert OptionGrammar.parse("cachebuster:abc123") ==
               {:ok, {:cache, [cachebuster: "abc123"]}}

      assert OptionGrammar.parse("cb:v1.0") == {:ok, {:cache, [cachebuster: "v1.0"]}}
    end
  end

  describe "policy-scoped options" do
    test "expires and exp aliases parse non-negative integer timestamps" do
      assert OptionGrammar.parse("expires:1000") == {:ok, {:policy, [expires: 1000]}}
      assert OptionGrammar.parse("exp:0") == {:ok, {:policy, [expires: 0]}}
    end

    test "expires rejects negative values" do
      assert OptionGrammar.parse("exp:-1") == {:error, {:invalid_expires, "-1"}}
    end

    test "expires rejects non-integer values" do
      assert OptionGrammar.parse("exp:1.5") == {:error, {:invalid_expires, "1.5"}}
      assert OptionGrammar.parse("exp:not-int") == {:error, {:invalid_expires, "not-int"}}
    end
  end

  describe "response-scoped options" do
    test "filename and fn aliases parse plain filenames" do
      assert OptionGrammar.parse("filename:report") == {:ok, {:response, [filename: "report"]}}
      assert OptionGrammar.parse("fn:cat.jpg") == {:ok, {:response, [filename: "cat.jpg"]}}
    end

    test "filename with base64 encoded flag decodes URL-safe base64 names" do
      encoded = Base.url_encode64("katt", padding: false)

      assert OptionGrammar.parse("fn:#{encoded}:true") ==
               {:ok, {:response, [filename: "katt"]}}
    end

    test "return_attachment and att aliases produce disposition assignments" do
      assert OptionGrammar.parse("return_attachment:true") ==
               {:ok, {:response, [disposition: :attachment]}}

      assert OptionGrammar.parse("att:false") ==
               {:ok, {:response, [disposition: :inline]}}

      assert OptionGrammar.parse("att:1") ==
               {:ok, {:response, [disposition: :attachment]}}
    end
  end

  describe "preset parsing" do
    test "preset and pr aliases parse named preset references" do
      assert OptionGrammar.parse("preset:thumb") == {:ok, {:preset, ["thumb"]}}
      assert OptionGrammar.parse("pr:thumb") == {:ok, {:preset, ["thumb"]}}
    end

    test "preset parses multiple names in order" do
      assert OptionGrammar.parse("preset:thumb:wide:jpeg") ==
               {:ok, {:preset, ["thumb", "wide", "jpeg"]}}

      assert OptionGrammar.parse("pr:a:b") == {:ok, {:preset, ["a", "b"]}}
    end

    test "empty preset names produce invalid segment errors" do
      assert OptionGrammar.parse("preset:") ==
               {:error, {:invalid_option_segment, "preset:"}}

      assert OptionGrammar.parse("pr::name") ==
               {:error, {:invalid_option_segment, "pr::name"}}
    end

    test "bare preset without names produces invalid segment error" do
      assert OptionGrammar.parse("preset") ==
               {:error, {:invalid_option_segment, "preset"}}

      assert OptionGrammar.parse("pr") ==
               {:error, {:invalid_option_segment, "pr"}}
    end
  end

  describe "gravity options" do
    test "gravity anchors parse all nine named positions" do
      for {value, expected} <- [
            {"no", {:anchor, :center, :top}},
            {"so", {:anchor, :center, :bottom}},
            {"ea", {:anchor, :right, :center}},
            {"we", {:anchor, :left, :center}},
            {"noea", {:anchor, :right, :top}},
            {"nowe", {:anchor, :left, :top}},
            {"soea", {:anchor, :right, :bottom}},
            {"sowe", {:anchor, :left, :bottom}},
            {"ce", {:anchor, :center, :center}}
          ] do
        assert {:ok, {:pipeline, [gravity: ^expected | _]}} =
                 OptionGrammar.parse("g:#{value}")
      end
    end

    test "gravity sm parses as smart anchor" do
      assert OptionGrammar.parse("g:sm") == {:ok, {:pipeline, [gravity: :sm]}}
    end

    test "gravity focal point parses coordinates 0.0 to 1.0" do
      assert OptionGrammar.parse("g:fp:0.5:0.75") ==
               {:ok,
                {:pipeline,
                 [
                   gravity: {:fp, 0.5, 0.75},
                   gravity_x_offset: {:pixels, 0.0},
                   gravity_y_offset: {:pixels, 0.0}
                 ]}}
    end

    test "invalid gravity anchor returns error" do
      assert OptionGrammar.parse("g:invalid") ==
               {:error, {:invalid_gravity, "invalid"}}
    end

    test "out-of-range focal coordinates return coordinate errors" do
      assert OptionGrammar.parse("g:fp:1.1:0.5") ==
               {:error, {:invalid_gravity_coordinate, "1.1"}}

      assert OptionGrammar.parse("g:fp:-0.1:0.5") ==
               {:error, {:invalid_gravity_coordinate, "-0.1"}}
    end
  end

  describe "extend options" do
    test "extend and ex aliases parse boolean enable" do
      assert OptionGrammar.parse("extend:true") ==
               {:ok, {:pipeline, [extend: true, extend_requested: true]}}

      assert OptionGrammar.parse("ex:false") ==
               {:ok, {:pipeline, [extend: false, extend_requested: true]}}
    end

    test "extend parses optional gravity tail" do
      assert OptionGrammar.parse("extend:true:ce") ==
               {:ok,
                {:pipeline,
                 [
                   extend: true,
                   extend_requested: true,
                   extend_gravity: {:anchor, :center, :center}
                 ]}}
    end

    test "extend parses optional gravity with x and y offsets" do
      assert OptionGrammar.parse("ex:true:no:5.0:3.0") ==
               {:ok,
                {:pipeline,
                 [
                   extend: true,
                   extend_requested: true,
                   extend_gravity: {:anchor, :center, :top},
                   extend_x_offset: {:pixels, 5.0},
                   extend_y_offset: {:pixels, 3.0}
                 ]}}
    end

    test "extend_aspect_ratio, extend_ar, and exar parse width:height ratios" do
      assert OptionGrammar.parse("extend_aspect_ratio:16:9") ==
               {:ok, {:pipeline, [extend_aspect_ratio: {16, 9}]}}

      assert OptionGrammar.parse("extend_ar:4:3") ==
               {:ok, {:pipeline, [extend_aspect_ratio: {4, 3}]}}

      assert OptionGrammar.parse("exar:1:1") ==
               {:ok, {:pipeline, [extend_aspect_ratio: {1, 1}]}}
    end
  end

  describe "auto_rotate and rotate" do
    test "auto_rotate and ar with no args default to true" do
      assert OptionGrammar.parse("auto_rotate") ==
               {:ok, {:pipeline, [orientation: [auto_orient: true]]}}

      assert OptionGrammar.parse("ar") ==
               {:ok, {:pipeline, [orientation: [auto_orient: true]]}}
    end

    test "auto_rotate and ar parse explicit boolean values" do
      assert OptionGrammar.parse("ar:true") ==
               {:ok, {:pipeline, [orientation: [auto_orient: true]]}}

      assert OptionGrammar.parse("ar:false") ==
               {:ok, {:pipeline, [orientation: [auto_orient: false]]}}
    end

    test "rotate and rot parse multiples of 90 degrees" do
      for {value, expected} <- [
            {"90", 90},
            {"180", 180},
            {"270", 270},
            {"360", 0},
            {"-90", 270},
            {"-270", 90},
            {"0", 0},
            {"450", 90}
          ] do
        assert OptionGrammar.parse("rotate:#{value}") ==
                 {:ok, {:pipeline, [orientation: [rotate: expected]]}}

        assert OptionGrammar.parse("rot:#{value}") ==
                 {:ok, {:pipeline, [orientation: [rotate: expected]]}}
      end
    end

    test "rotate rejects non-multiples of 90" do
      assert OptionGrammar.parse("rotate:45") == {:error, {:invalid_rotate, "45"}}
      assert OptionGrammar.parse("rot:91") == {:error, {:invalid_rotate, "91"}}
    end
  end

  describe "flip options" do
    test "flip with no args produces both" do
      assert OptionGrammar.parse("flip") == {:ok, {:pipeline, [orientation: [flip: :both]]}}
      assert OptionGrammar.parse("fl") == {:ok, {:pipeline, [orientation: [flip: :both]]}}
    end

    test "flip true:false produces horizontal" do
      assert OptionGrammar.parse("flip:true:false") ==
               {:ok, {:pipeline, [orientation: [flip: :horizontal]]}}

      assert OptionGrammar.parse("fl:true:false") ==
               {:ok, {:pipeline, [orientation: [flip: :horizontal]]}}
    end

    test "flip false:true produces vertical" do
      assert OptionGrammar.parse("flip:false:true") ==
               {:ok, {:pipeline, [orientation: [flip: :vertical]]}}
    end

    test "flip false:false produces nil flip" do
      assert OptionGrammar.parse("flip:false:false") ==
               {:ok, {:pipeline, [orientation: [flip: nil]]}}
    end

    test "flip with single arg parses as horizontal flag" do
      assert OptionGrammar.parse("fl:true") ==
               {:ok, {:pipeline, [orientation: [flip: :horizontal]]}}

      assert OptionGrammar.parse("fl:false") ==
               {:ok, {:pipeline, [orientation: [flip: nil]]}}
    end
  end

  describe "crop options" do
    test "crop with width and height only produces a minimal crop request" do
      assert OptionGrammar.parse("c:200:100") ==
               {:ok,
                {:pipeline,
                 [
                   crop: %CropRequest{width: {:pixels, 200}, height: {:pixels, 100}}
                 ]}}
    end

    test "crop accepts auto (zero) dimensions" do
      assert OptionGrammar.parse("crop:0:0") ==
               {:ok,
                {:pipeline,
                 [
                   crop: %CropRequest{width: :auto, height: :auto}
                 ]}}
    end

    test "crop accepts scale dimensions between 0 and 1" do
      assert OptionGrammar.parse("c:0.5:0.25") ==
               {:ok,
                {:pipeline,
                 [
                   crop: %CropRequest{width: {:scale, 0.5}, height: {:scale, 0.25}}
                 ]}}
    end

    test "crop with gravity sm produces smart gravity" do
      assert OptionGrammar.parse("crop:100:100:sm") ==
               {:ok,
                {:pipeline,
                 [
                   crop: %CropRequest{width: {:pixels, 100}, height: {:pixels, 100}, gravity: :sm}
                 ]}}
    end
  end

  describe "padding options" do
    test "padding with one arg applies to all sides" do
      assert OptionGrammar.parse("padding:10") ==
               {:ok, {:pipeline, [padding: [10]]}}
    end

    test "padding with two args applies top-bottom and left-right" do
      assert OptionGrammar.parse("pd:10:20") ==
               {:ok, {:pipeline, [padding: [10, 20]]}}
    end

    test "padding with four args applies each side independently" do
      assert OptionGrammar.parse("padding:10:20:30:40") ==
               {:ok, {:pipeline, [padding: [10, 20, 30, 40]]}}
    end

    test "padding with empty args parses as unset" do
      assert OptionGrammar.parse("pd:") == {:ok, {:pipeline, [padding: [:unset]]}}
    end
  end

  describe "background and background_alpha options" do
    test "background with hex color parses correctly" do
      assert {:ok, {:pipeline, [background_color: color]}} =
               OptionGrammar.parse("bg:ff0000")

      assert %ImagePlug.Plan.Color{channels: {255, 0, 0}} = color
    end

    test "background with short hex color parses correctly" do
      assert {:ok, {:pipeline, [background_color: color]}} =
               OptionGrammar.parse("bg:f00")

      assert %ImagePlug.Plan.Color{channels: {255, 0, 0}} = color
    end

    test "background with RGB integers parses correctly" do
      assert {:ok, {:pipeline, [background_color: color]}} =
               OptionGrammar.parse("background:255:0:0")

      assert %ImagePlug.Plan.Color{channels: {255, 0, 0}} = color
    end

    test "background with empty string clears color" do
      assert OptionGrammar.parse("bg:") == {:ok, {:pipeline, [background_color: nil]}}
    end

    test "background_alpha parses valid ratio values" do
      assert OptionGrammar.parse("bga:0.5") ==
               {:ok, {:pipeline, [background_alpha: {:ratio, 5, 10}]}}

      assert OptionGrammar.parse("bga:1") ==
               {:ok, {:pipeline, [background_alpha: {:ratio, 1, 1}]}}

      assert OptionGrammar.parse("background_alpha:0.25") ==
               {:ok, {:pipeline, [background_alpha: {:ratio, 25, 100}]}}
    end
  end

  describe "size option" do
    test "size and s aliases parse width and height" do
      assert OptionGrammar.parse("size:300:200") ==
               {:ok, {:pipeline, [width: {:pixels, 300}, height: {:pixels, 200}]}}

      assert OptionGrammar.parse("s:100:50") ==
               {:ok, {:pipeline, [width: {:pixels, 100}, height: {:pixels, 50}]}}
    end

    test "size with extend flag sets extend_requested" do
      assert OptionGrammar.parse("s:100:50:0:1") ==
               {:ok,
                {:pipeline,
                 [
                   width: {:pixels, 100},
                   height: {:pixels, 50},
                   enlarge: false,
                   extend: true,
                   extend_requested: true
                 ]}}
    end

    test "size with omitted fields skips those fields" do
      assert OptionGrammar.parse("size:300") ==
               {:ok, {:pipeline, [width: {:pixels, 300}]}}

      assert OptionGrammar.parse("s::200") ==
               {:ok, {:pipeline, [height: {:pixels, 200}]}}
    end
  end
end
