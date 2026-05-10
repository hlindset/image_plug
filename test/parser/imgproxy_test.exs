defmodule ImagePlug.Parser.ImgproxyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Plug.Test

  alias ImagePlug.Parser.Imgproxy
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Response
  alias ImagePlug.Plan.Response.Filename
  alias ImagePlug.Plan.Source.Plain

  test "parses a plain source with no processing options" do
    assert {:ok,
            %Plan{
              source: %Plain{path: ["images", "cat.jpg"]},
              pipelines: [%Pipeline{operations: []}],
              output: %Output{mode: :automatic}
            }} = Imgproxy.parse(conn(:get, "/_/plain/images/cat.jpg"), [])
  end

  test "parse/2 accepts parser options and keeps no-option parse/1 as a delegating helper" do
    conn = conn(:get, "/_/plain/images/cat.jpg")

    assert Imgproxy.parse(conn, []) == Imgproxy.parse(conn)
  end

  test "supports unsafe as the disabled-signing signature segment" do
    assert {:ok, %Plan{source: %Plain{path: ["images", "cat.jpg"]}}} =
             Imgproxy.parse(conn(:get, "/unsafe/plain/images/cat.jpg"), [])
  end

  test "rejects unsupported signature segments while signing is disabled" do
    assert Imgproxy.parse(conn(:get, "/signed-value/plain/images/cat.jpg"), []) ==
             {:error, {:unsupported_signature, "signed-value"}}
  end

  test "rejects missing signature" do
    assert Imgproxy.parse(conn(:get, "/"), []) == {:error, :missing_signature}
  end

  test "rejects missing source kind" do
    assert Imgproxy.parse(conn(:get, "/_/w:300"), []) == {:error, :missing_source_kind}
  end

  test "rejects missing plain source identifier" do
    assert Imgproxy.parse(conn(:get, "/_/plain"), []) ==
             {:error, {:missing_source_identifier, "plain"}}
  end

  test "treats option-like segments after plain as source path" do
    assert {:ok, %Plan{source: %Plain{path: ["images", "w:300", "cat.jpg"]}}} =
             Imgproxy.parse(conn(:get, "/_/plain/images/w:300/cat.jpg"), [])
  end

  test "parses resize and rs full grammar" do
    assert [%Operation.ResizeCover{} = fill_params] =
             operations_for("/_/resize:fill:300:200:1/plain/images/cat.jpg")

    assert fill_params.size.width == pixels(300)
    assert fill_params.size.height == pixels(200)
    assert fill_params.enlargement == :allow

    assert [%Operation.ResizeStretch{} = force_params] =
             operations_for("/_/rs:force:300:200/plain/images/cat.jpg")

    assert force_params.size.width == pixels(300)
    assert force_params.size.height == pixels(200)

    assert {:ok, parsed} =
             Imgproxy.parse_request(
               conn(:get, "/_/resize:fill:300:200:1:0/plain/images/cat.jpg"),
               []
             )

    [pipeline] = parsed.pipelines
    assert pipeline.resizing_type == :fill
    assert pipeline.width == {:pixels, 300}
    assert pipeline.height == {:pixels, 200}
    assert pipeline.enlarge == true
    assert pipeline.extend == false
    assert pipeline.extend_requested == true
  end

  test "parses omitted resize arguments with imgproxy defaults" do
    assert [%Operation.ResizeFit{} = width_params] =
             operations_for("/_/rs:fit:300/plain/images/cat.jpg")

    assert width_params.size.width == pixels(300)
    assert width_params.size.height == auto()

    assert [%Operation.ResizeFit{} = dimensions_params] =
             operations_for("/_/rs::300:200/plain/images/cat.jpg")

    assert dimensions_params.size.width == pixels(300)
    assert dimensions_params.size.height == pixels(200)
  end

  test "rejects empty resize and size option segments" do
    for segment <- ["rs", "rs:", "rs::", "resize", "resize:", "s", "s:", "s::", "size"] do
      assert Imgproxy.parse(conn(:get, "/_/#{segment}/plain/images/cat.jpg"), []) ==
               {:error, {:invalid_option_segment, segment}}
    end
  end

  test "omitted meta-option arguments do not overwrite previous field assignments" do
    assert [%Operation.ResizeCover{} = params] =
             operations_for("/_/w:500/rs:fill::200/plain/images/cat.jpg")

    assert params.size.width == pixels(500)
    assert params.size.height == pixels(200)
  end

  test "omitted extend argument still parses provided extend gravity tail" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             Imgproxy.parse(conn(:get, "/_/rs::::::ce::/plain/images/cat.jpg"), [])

    assert [%Operation.Canvas{placement: placement}] = operations
    assert anchor(placement) == {:center, :center}

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             Imgproxy.parse(conn(:get, "/_/s:::::ce::/plain/images/cat.jpg"), [])

    assert [%Operation.Canvas{placement: placement}] = operations
    assert anchor(placement) == {:center, :center}
  end

  test "extend gravity invalid arity reports the original option segment" do
    segment = "rs:::::1:ce:1"

    assert Imgproxy.parse(conn(:get, "/_/#{segment}/plain/images/cat.jpg"), []) ==
             {:error, {:invalid_option_segment, segment}}
  end

  test "plans parsed extend semantics as neutral canvas operations" do
    for path <- [
          "/_/resize:fill:300:200:1:0/plain/images/cat.jpg",
          "/_/rs:fit:300:200:0:0/plain/images/cat.jpg",
          "/_/size:300:200:0:0/plain/images/cat.jpg",
          "/_/s:300:200:0:0/plain/images/cat.jpg"
        ] do
      assert {:ok, %Plan{pipelines: [%Pipeline{}]}} =
               Imgproxy.parse(conn(:get, path), [])
    end

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             Imgproxy.parse(
               conn(:get, "/_/rs:fit:300:200:0:1:ce:0:0/plain/images/cat.jpg"),
               []
             )

    assert Enum.any?(operations, &match?(%Operation.Canvas{}, &1))
  end

  test "parses size without changing resizing_type" do
    assert [%Operation.ResizeStretch{} = params] =
             operations_for("/_/rt:force/s:300:200/plain/images/cat.jpg")

    assert params.size.width == pixels(300)
    assert params.size.height == pixels(200)
  end

  test "size overwrites dimensions without resetting resizing_type" do
    assert [%Operation.ResizeCover{} = params] =
             operations_for("/_/rs:fill:300:200/s:100:100/plain/images/cat.jpg")

    assert params.size.width == pixels(100)
    assert params.size.height == pixels(100)
  end

  test "parses min size, zoom, dpr, crop, orientation, and extend-aspect-ratio" do
    assert {:ok, parsed} =
             Imgproxy.parse_request(
               conn(
                 :get,
                 "/_/rs:fit:100:0/mw:300/mh:200/z:2:3/dpr:2/c:0.5:0.25:nowe:10:-5/ar:true/rot:-90/fl:true:false/exar:16:9/plain/images/cat.jpg"
               ),
               []
             )

    [pipeline] = parsed.pipelines
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

  test "public parse plans supported geometry pipeline semantics" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.ResizeFit{} = resize]}]}} =
             Imgproxy.parse(conn(:get, "/_/z:2/plain/images/cat.jpg"), [])

    assert resize.zoom_x == 2.0
    assert resize.zoom_y == 2.0

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.CropGuided{} = crop]}]}} =
             Imgproxy.parse(conn(:get, "/_/crop:10:20/plain/images/cat.jpg"), [])

    assert crop.size.width == pixels(10)
    assert crop.size.height == pixels(20)

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.AutoOrient{}]}]}} =
             Imgproxy.parse(conn(:get, "/_/ar/plain/images/cat.jpg"), [])

    for segment <- ~w(ar:false rot:0 rot:360 fl:false:false) do
      assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
               Imgproxy.parse(conn(:get, "/_/#{segment}/plain/images/cat.jpg"), [])
    end

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             Imgproxy.parse(conn(:get, "/_/crop:10:20/ar/plain/images/cat.jpg"), [])

    assert operation_names(operations) == [:auto_orient, :crop_guided]

    for segment <- ~w(extend:false ex:false) do
      assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
               Imgproxy.parse(conn(:get, "/_/#{segment}/plain/images/cat.jpg"), [])
    end

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             Imgproxy.parse(conn(:get, "/_/rs:fit:300:200:0:0:ce/plain/images/cat.jpg"), [])

    refute Enum.any?(operations, &match?(%Operation.Canvas{}, &1))
  end

  test "parses supported resizing type aliases into plans and rejects unsupported values" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
             Imgproxy.parse(conn(:get, "/_/rt:fit/plain/images/cat.jpg"), [])

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
             Imgproxy.parse(conn(:get, "/_/rt:force/plain/images/cat.jpg"), [])

    assert Imgproxy.parse(conn(:get, "/_/rt:fill/plain/images/cat.jpg"), []) ==
             {:error, {:missing_dimensions, :fill}}

    assert Imgproxy.parse(conn(:get, "/_/rt:fill-down/plain/images/cat.jpg"), []) ==
             {:error, {:missing_dimensions, :fill_down}}

    assert Imgproxy.parse(conn(:get, "/_/rt:auto/plain/images/cat.jpg"), []) ==
             {:error, {:missing_dimensions, :auto}}

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{
                  operations: [
                    %Operation.ResizeCover{} = resize
                  ]
                }
              ]
            }} =
             Imgproxy.parse(conn(:get, "/_/rt:fill-down/w:100/h:100/plain/images/cat.jpg"), [])

    assert resize.enlargement == :deny

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{
                  operations: [%Operation.ResizeAuto{}]
                }
              ]
            }} =
             Imgproxy.parse(conn(:get, "/_/rt:auto/w:100/h:100/plain/images/cat.jpg"), [])
  end

  test "invalid resizing type reports supported values" do
    assert Imgproxy.parse(conn(:get, "/_/rt:crop/plain/images/cat.jpg"), []) ==
             {:error,
              {:invalid_resizing_type, "crop", ["fit", "fill", "fill-down", "force", "auto"]}}
  end

  test "parses width and height aliases including zero" do
    assert [%Operation.ResizeFit{} = params] =
             operations_for("/_/w:0/h:200/plain/images/cat.jpg")

    assert params.size.width == auto()
    assert params.size.height == pixels(200)

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.ResizeFit{} = resize]}]}} =
             Imgproxy.parse(conn(:get, "/_/w:0/h:0/mw:300/plain/images/cat.jpg"), [])

    assert resize.size.width == auto()
    assert resize.size.height == auto()
    assert resize.min_width == pixels(300)
  end

  test "parses documented Imgproxy processing examples" do
    for path <- [
          "/_/rt:force/w:0/h:200/plain/images/cat.jpg",
          "/_/g:fp:0.25:0.75/rs:fill:300:200/plain/images/cat.jpg",
          "/_/c:100:100:fp:0.25:0.75/plain/images/cat.jpg",
          "/_/ar/c:100:100/plain/images/cat.jpg",
          "/_/g:soea:12:-0.25/rs:fill:300:200/plain/images/cat.jpg"
        ] do
      assert {:ok, _plan} = Imgproxy.parse(conn(:get, path), [])
    end
  end

  test "plans gravity-bearing fill and auto result crops" do
    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{
                  operations: [%Operation.ResizeCover{} = crop]
                }
              ]
            }} =
             Imgproxy.parse(conn(:get, "/_/g:nowe/rs:fill:300:200/plain/images/cat.jpg"), [])

    assert anchor(crop.guide) == {:left, :top}

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{
                  operations: [%Operation.ResizeCover{} = crop]
                }
              ]
            }} =
             Imgproxy.parse(
               conn(:get, "/_/gravity:fp:0.5:0.25/rs:fill:300:200/plain/images/cat.jpg"),
               []
             )

    assert focal_point(crop.guide) == {1, 2, 1, 4}

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{
                  operations: [%Operation.ResizeCover{} = crop]
                }
              ]
            } = plan} =
             Imgproxy.parse(conn(:get, "/_/g:fp:1:0/rs:fill:300:200/plain/images/cat.jpg"), [])

    assert focal_point(crop.guide) == {1, 1, 0, 1}
    assert {:ok, _pipelines} = ImagePlug.Transform.validate_prefetch_safe_plan(plan)

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{
                  operations: [
                    %Operation.ResizeAuto{} = crop
                  ]
                }
              ]
            }} =
             Imgproxy.parse(conn(:get, "/_/g:soea/rt:auto/w:300/h:200/plain/images/cat.jpg"), [])

    assert anchor(crop.guide) == {:right, :bottom}
  end

  test "parses and plans imgproxy top-level gravity offsets" do
    assert {:ok, parsed} =
             Imgproxy.parse_request(conn(:get, "/_/g:soea:12:-0.25/plain/images/cat.jpg"), [])

    [pipeline] = parsed.pipelines
    assert pipeline.gravity == {:anchor, :right, :bottom}
    assert pipeline.gravity_x_offset == {:pixels, 12.0}
    assert pipeline.gravity_y_offset == {:scale, -0.25}

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{
                  operations: [%Operation.ResizeCover{} = crop]
                }
              ]
            }} =
             Imgproxy.parse(
               conn(:get, "/_/g:soea:12:-0.25/rs:fill:300:200/plain/images/cat.jpg"),
               []
             )

    assert anchor(crop.guide) == {:right, :bottom}
    assert crop.x_offset == {:pixels, -12.0}
    assert crop.y_offset == {:scale, 0.25}
  end

  test "parses crop focal-point gravity and relative offsets" do
    assert {:ok, parsed} =
             Imgproxy.parse_request(
               conn(:get, "/_/c:100:100:fp:0.25:0.75/plain/images/cat.jpg"),
               []
             )

    [pipeline] = parsed.pipelines
    assert pipeline.crop.gravity == {:fp, 0.25, 0.75}

    assert {:ok, parsed} =
             Imgproxy.parse_request(
               conn(:get, "/_/c:100:100:nowe:0.25:-0.5/plain/images/cat.jpg"),
               []
             )

    [pipeline] = parsed.pipelines
    assert pipeline.crop.x_offset == {:scale, 0.25}
    assert pipeline.crop.y_offset == {:scale, -0.5}
  end

  test "rejects out-of-range focal point coordinates as gravity coordinate errors" do
    assert Imgproxy.parse(conn(:get, "/_/g:fp:1.2:0.5/plain/images/cat.jpg"), []) ==
             {:error, {:invalid_gravity_coordinate, "1.2"}}

    assert Imgproxy.parse(conn(:get, "/_/g:fp:nope:0.5/plain/images/cat.jpg"), []) ==
             {:error, {:invalid_gravity_coordinate, "nope"}}
  end

  test "rejects smart gravity as an unsupported planner semantic" do
    assert Imgproxy.parse(conn(:get, "/_/g:sm/plain/images/cat.jpg"), []) ==
             {:error, {:unsupported_gravity, :sm}}

    assert Imgproxy.parse(conn(:get, "/_/c:100:100:sm/plain/images/cat.jpg"), []) ==
             {:error, {:unsupported_gravity, :sm}}
  end

  test "parses format aliases and jpg normalization" do
    assert_output_mode("/_/f:webp/plain/images/cat.jpg", {:explicit, :webp})
    assert_output_mode("/_/f:avif/plain/images/cat.jpg", {:explicit, :avif})
    assert_output_mode("/_/ext:jpg/plain/images/cat.jpg", {:explicit, :jpeg})
  end

  test "plain source extension overrides explicit format after options" do
    assert_output_mode("/_/f:webp/plain/images/cat.jpg@png", {:explicit, :png})
  end

  test "global options may appear before and after pipeline separators" do
    assert_output_mode("/_/f:webp/-/w:100/plain/images/cat.jpg", {:explicit, :webp})
    assert_output_mode("/_/w:100/-/f:webp/plain/images/cat.jpg", {:explicit, :webp})

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             Imgproxy.parse(conn(:get, "/_/f:webp/-/plain/images/cat.jpg"), [])

    assert operations == []
  end

  test "later global assignments win across groups" do
    assert_output_mode("/_/f:webp/-/f:jpeg/plain/images/cat.jpg", {:explicit, :jpeg})
  end

  property "global option permutations resolve equivalently across pipeline groups" do
    options = ["f:webp", "q:80", "fq:webp:70"]

    check all ordered_options <- member_of(permutations(options)),
              split_at <- integer(1..(length(options) - 1)),
              max_runs: 50 do
      {before_separator, after_separator} = Enum.split(ordered_options, split_at)
      processing = before_separator ++ ["-"] ++ after_separator
      path = "/_/" <> Enum.join(processing, "/") <> "/plain/images/cat.jpg"

      assert {:ok,
              %Plan{
                output: %Output{
                  mode: {:explicit, :webp},
                  quality: {:quality, 80},
                  format_qualities: %{webp: {:quality, 70}}
                }
              }} = Imgproxy.parse(conn(:get, path), [])
    end
  end

  test "parses output quality and format quality as output request fields" do
    assert {:ok,
            %Plan{
              output: %ImagePlug.Plan.Output{
                quality: {:quality, 80},
                format_qualities: %{webp: {:quality, 70}}
              }
            }} = Imgproxy.parse(conn(:get, "/_/q:80/fq:webp:70/plain/images/cat.jpg"), [])
  end

  test "quality zero and format-quality zero normalize to default" do
    assert {:ok,
            %Plan{
              output: %ImagePlug.Plan.Output{
                quality: :default,
                format_qualities: %{webp: :default}
              }
            }} = Imgproxy.parse(conn(:get, "/_/q:0/fq:webp:0/plain/images/cat.jpg"), [])
  end

  test "repeated format quality assignments replace by normalized format" do
    assert {:ok,
            %Plan{
              output: %ImagePlug.Plan.Output{
                format_qualities: %{webp: {:quality, 60}}
              }
            }} =
             Imgproxy.parse(conn(:get, "/_/fq:webp:70/-/fq:webp:60/plain/images/cat.jpg"), [])
  end

  test "quality later assignment wins across groups" do
    assert {:ok, %Plan{output: %ImagePlug.Plan.Output{quality: {:quality, 70}}}} =
             Imgproxy.parse(conn(:get, "/_/q:80/-/q:70/plain/images/cat.jpg"), [])
  end

  test "parses cachebuster aliases as cache-only facets" do
    assert {:ok, %Plan{cache: %ImagePlug.Plan.Cache{cachebuster: "abc"}}} =
             Imgproxy.parse(conn(:get, "/_/cb:abc/plain/images/cat.jpg"), [])

    assert {:ok, %Plan{cache: %ImagePlug.Plan.Cache{cachebuster: "def"}}} =
             Imgproxy.parse(conn(:get, "/_/cachebuster:def/plain/images/cat.jpg"), [])
  end

  test "cachebuster later assignment wins across groups" do
    assert {:ok, %Plan{cache: %ImagePlug.Plan.Cache{cachebuster: "b"}}} =
             Imgproxy.parse(conn(:get, "/_/cb:a/-/cachebuster:b/plain/images/cat.jpg"), [])
  end

  test "expires rejects expired requests with injectable now" do
    assert Imgproxy.parse(conn(:get, "/_/expires:100/plain/images/cat.jpg"), now: 101) ==
             {:error, {:expired_request, 100}}

    assert {:ok, %Plan{policy: %ImagePlug.Plan.Policy{expires: 100}}} =
             Imgproxy.parse(conn(:get, "/_/exp:100/plain/images/cat.jpg"), now: 100)

    assert {:ok, %Plan{policy: %ImagePlug.Plan.Policy{expires: 0}}} =
             Imgproxy.parse(conn(:get, "/_/expires:0/plain/images/cat.jpg"), now: 999)
  end

  test "expires later assignment wins across groups" do
    assert {:ok, %Plan{policy: %ImagePlug.Plan.Policy{expires: 200}}} =
             Imgproxy.parse(conn(:get, "/_/exp:100/-/expires:200/plain/images/cat.jpg"), now: 100)
  end

  test "now function is called once and normalized once per parse attempt" do
    test_pid = self()

    now = fn ->
      send(test_pid, :now_called)
      100
    end

    assert {:ok, %Plan{policy: %ImagePlug.Plan.Policy{expires: 100}}} =
             Imgproxy.parse(conn(:get, "/_/exp:100/plain/images/cat.jpg"), now: now)

    assert_received :now_called
    refute_received :now_called
  end

  test "expires rejects malformed values and invalid now values" do
    assert Imgproxy.parse(conn(:get, "/_/exp:not-int/plain/images/cat.jpg"), now: 100) ==
             {:error, {:invalid_expires, "not-int"}}

    assert Imgproxy.parse(conn(:get, "/_/exp:-1/plain/images/cat.jpg"), now: 100) ==
             {:error, {:invalid_expires, "-1"}}

    assert Imgproxy.parse(conn(:get, "/_/exp:100/plain/images/cat.jpg"), now: :bad) ==
             {:error, {:invalid_now, :bad}}

    assert Imgproxy.parse(conn(:get, "/_/exp:100/plain/images/cat.jpg"), now: fn -> :bad end) ==
             {:error, {:invalid_now, :bad}}
  end

  test "rejects invalid expires arity" do
    for segment <- ["exp", "exp:", "exp:100:200", "expires", "expires:", "expires:100:200"] do
      assert Imgproxy.parse(conn(:get, "/_/#{segment}/plain/images/cat.jpg"), now: 100) ==
               {:error, {:invalid_option_segment, segment}}
    end
  end

  test "rejects invalid cachebuster arity" do
    for segment <- [
          "cb",
          "cb:",
          "cb:a:b",
          "cachebuster",
          "cachebuster:",
          "cachebuster:a:b"
        ] do
      assert Imgproxy.parse(conn(:get, "/_/#{segment}/plain/images/cat.jpg"), []) ==
               {:error, {:invalid_option_segment, segment}}
    end
  end

  test "parses filename and attachment aliases into response facet" do
    assert {:ok,
            %Plan{
              response: %Response{
                disposition: :attachment,
                filename: %Filename{stem: "report"}
              }
            }} = Imgproxy.parse(conn(:get, "/_/fn:report/att:true/plain/images/cat.jpg"), [])

    assert {:ok, %Plan{response: %Response{disposition: :inline}}} =
             Imgproxy.parse(conn(:get, "/_/return_attachment:false/plain/images/cat.jpg"), [])
  end

  test "decodes base64url filenames when encoded flag is truthy" do
    encoded = Base.url_encode64("katt-æøå", padding: false)

    assert {:ok,
            %Plan{
              response: %Response{
                filename: %Filename{stem: "katt-æøå"}
              }
            }} = Imgproxy.parse(conn(:get, "/_/fn:#{encoded}:true/plain/images/cat.jpg"), [])
  end

  test "rejects invalid filename values before planning succeeds" do
    for path <- [
          "/_/fn:/plain/images/cat.jpg",
          "/_/fn:a%2Fb/plain/images/cat.jpg",
          "/_/fn:a%5Cb/plain/images/cat.jpg",
          "/_/fn:a%0Ab/plain/images/cat.jpg",
          "/_/fn:not-base64:true/plain/images/cat.jpg",
          "/_/fn:#{Base.url_encode64(<<255>>, padding: false)}:true/plain/images/cat.jpg",
          "/_/fn:abcd:true:extra/plain/images/cat.jpg"
        ] do
      assert {:error, _reason} = Imgproxy.parse(conn(:get, path), [])
    end
  end

  test "rejects malformed percent-encoded filename values without raising" do
    assert Imgproxy.parse(conn(:get, "/_/fn:a%ZZ/plain/images/cat.jpg"), []) ==
             {:error, {:invalid_percent_encoding, "a%ZZ"}}
  end

  test "explicit filename extensions are kept but source-derived extensions are stripped" do
    assert {:ok,
            %Plan{
              response: %Response{
                filename: %Filename{stem: "cat.jpg"}
              }
            }} = Imgproxy.parse(conn(:get, "/_/fn:cat.jpg/plain/images/source.jpg@webp"), [])

    assert {:ok,
            %Plan{
              response: %Response{
                filename: %Filename{stem: "source"}
              }
            }} = Imgproxy.parse(conn(:get, "/_/plain/images/source.jpg@webp"), [])
  end

  test "filename and attachment later assignments win across groups" do
    assert {:ok,
            %Plan{
              response: %Response{
                disposition: :inline,
                filename: %Filename{stem: "two"}
              }
            }} =
             Imgproxy.parse(
               conn(
                 :get,
                 "/_/fn:one/att:true/-/filename:two/return_attachment:false/plain/images/source.jpg"
               ),
               []
             )
  end

  test "rejects invalid filename and attachment arity" do
    for segment <- [
          "fn",
          "fn:a:true:extra",
          "filename",
          "filename:a:false:extra",
          "att",
          "att:",
          "att:true:false",
          "return_attachment",
          "return_attachment:",
          "return_attachment:true:false"
        ] do
      assert Imgproxy.parse(conn(:get, "/_/#{segment}/plain/images/cat.jpg"), []) ==
               {:error, {:invalid_option_segment, segment}}
    end
  end

  test "format quality normalizes jpg to jpeg" do
    assert {:ok,
            %Plan{
              output: %ImagePlug.Plan.Output{
                format_qualities: %{jpeg: {:quality, 70}}
              }
            }} = Imgproxy.parse(conn(:get, "/_/fq:jpg:70/plain/images/cat.jpg"), [])
  end

  test "rejects invalid output quality values" do
    assert Imgproxy.parse(conn(:get, "/_/q:101/plain/images/cat.jpg"), []) ==
             {:error, {:invalid_option, :quality, "101"}}

    assert Imgproxy.parse(conn(:get, "/_/quality:-1/plain/images/cat.jpg"), []) ==
             {:error, {:invalid_option, :quality, "-1"}}
  end

  test "rejects invalid format quality values" do
    assert Imgproxy.parse(conn(:get, "/_/fq:webp:101/plain/images/cat.jpg"), []) ==
             {:error, {:invalid_option, :quality, "101"}}

    assert Imgproxy.parse(conn(:get, "/_/format_quality:webp:-1/plain/images/cat.jpg"), []) ==
             {:error, {:invalid_option, :quality, "-1"}}
  end

  test "rejects invalid quality arity" do
    for segment <- ["q", "q:", "q:80:70", "quality", "quality:", "quality:80:70"] do
      assert Imgproxy.parse(conn(:get, "/_/#{segment}/plain/images/cat.jpg"), []) ==
               {:error, {:invalid_option_segment, segment}}
    end
  end

  test "rejects invalid format quality arity" do
    for segment <- [
          "fq",
          "fq:webp",
          "fq:webp:",
          "fq:webp:70:60",
          "format_quality",
          "format_quality:webp",
          "format_quality:webp:",
          "format_quality:webp:70:60"
        ] do
      assert Imgproxy.parse(conn(:get, "/_/#{segment}/plain/images/cat.jpg"), []) ==
               {:error, {:invalid_option_segment, segment}}
    end
  end

  test "global-only and empty groups do not become executable pipelines" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
             Imgproxy.parse(conn(:get, "/_/f:webp/-/plain/images/cat.jpg"), [])

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             Imgproxy.parse(conn(:get, "/_/-/w:100/plain/images/cat.jpg"), [])

    assert length(operations) == 1
    assert [%{__struct__: _} = operation] = operations
    assert inspect(operation) =~ "100"
  end

  test "dangling raw @ does not overwrite an explicit format" do
    assert {:ok,
            %Plan{
              source: %Plain{path: ["images", "cat.jpg"]},
              output: %Output{mode: {:explicit, :webp}}
            }} = Imgproxy.parse(conn(:get, "/_/f:webp/plain/images/cat.jpg@"), [])
  end

  test "rejects format auto because it is not imgproxy grammar" do
    assert Imgproxy.parse(conn(:get, "/_/format:auto/plain/images/cat.jpg"), []) ==
             {:error, {:invalid_format, "auto", ["webp", "avif", "jpeg", "jpg", "png", "best"]}}
  end

  test "parses processing options before validating source extension" do
    assert Imgproxy.parse(conn(:get, "/_/unknown/plain/images/cat.jpg@unknown"), []) ==
             {:error, {:unknown_option, "unknown"}}
  end

  test "later field assignments overwrite earlier assignments" do
    assert [%Operation.ResizeFit{} = contain_params] =
             operations_for("/_/w:100/width:200/plain/images/cat.jpg")

    assert contain_params.size.width == pixels(200)

    assert [%Operation.ResizeCover{} = resized_params] =
             operations_for("/_/resize:fill:300:200/w:500/plain/images/cat.jpg")

    assert resized_params.size.width == pixels(500)
    assert resized_params.size.height == pixels(200)

    assert [%Operation.ResizeCover{} = overwritten_params] =
             operations_for("/_/w:500/resize:fill:300:200/plain/images/cat.jpg")

    assert overwritten_params.size.width == pixels(300)
    assert overwritten_params.size.height == pixels(200)

    assert [%Operation.ResizeStretch{} = scale_params] =
             operations_for("/_/size:300:200/rt:force/plain/images/cat.jpg")

    assert scale_params.size.width == pixels(300)
    assert scale_params.size.height == pixels(200)
  end

  test "parses chained imgproxy pipeline separators into multiple pipelines" do
    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: first_operations},
                %Pipeline{operations: second_operations}
              ]
            }} = Imgproxy.parse(conn(:get, "/_/w:500/-/h:200/plain/images/cat.jpg"), [])

    assert [%Operation.ResizeFit{} = first_params] = first_operations
    assert first_params.size.width == pixels(500)
    assert first_params.size.height == auto()

    assert [%Operation.ResizeFit{} = second_params] = second_operations
    assert second_params.size.width == auto()
    assert second_params.size.height == pixels(200)
  end

  test "ignores empty groups around chained imgproxy pipeline separators" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: leading_operations}]}} =
             Imgproxy.parse(conn(:get, "/_/-/w:500/plain/images/cat.jpg"), [])

    assert [%Operation.ResizeFit{} = leading_params] = leading_operations
    assert leading_params.size.width == pixels(500)

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: trailing_operations}]}} =
             Imgproxy.parse(conn(:get, "/_/w:500/-/plain/images/cat.jpg"), [])

    assert [%Operation.ResizeFit{} = trailing_params] = trailing_operations
    assert trailing_params.size.width == pixels(500)

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: first_operations},
                %Pipeline{operations: second_operations}
              ]
            }} = Imgproxy.parse(conn(:get, "/_/w:500/-/-/h:200/plain/images/cat.jpg"), [])

    assert [%Operation.ResizeFit{} = first_params] = first_operations
    assert first_params.size.width == pixels(500)

    assert [%Operation.ResizeFit{} = second_params] = second_operations
    assert second_params.size.height == pixels(200)
  end

  test "preserves no-op single-pipeline behavior" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
             Imgproxy.parse(conn(:get, "/_/plain/images/cat.jpg"), [])
  end

  test "later field assignments are scoped to each imgproxy pipeline" do
    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: first_operations},
                %Pipeline{operations: second_operations}
              ]
            }} =
             Imgproxy.parse(conn(:get, "/_/w:500/w:600/-/h:200/h:300/plain/images/cat.jpg"), [])

    assert [%Operation.ResizeFit{} = first_params] = first_operations
    assert first_params.size.width == pixels(600)

    assert [%Operation.ResizeFit{} = second_params] = second_operations
    assert second_params.size.height == pixels(300)
  end

  test "detects raw source extension before percent decoding" do
    assert {:ok,
            %Plan{
              source: %Plain{path: ["images", "cat@v1.jpg"]},
              output: %Output{mode: {:explicit, :webp}}
            }} = Imgproxy.parse(conn(:get, "/_/plain/images/cat%40v1.jpg@webp"), [])
  end

  test "rejects malformed percent-encoded source path segments without raising" do
    assert Imgproxy.parse(conn(:get, "/_/plain/images/cat%ZZ.jpg"), []) ==
             {:error, {:invalid_percent_encoding, "cat%ZZ.jpg"}}
  end

  test "parses supported source extensions" do
    cases = [
      {"webp", :webp},
      {"avif", :avif},
      {"jpeg", :jpeg},
      {"jpg", :jpeg},
      {"png", :png}
    ]

    for {extension, format} <- cases do
      assert_output_mode("/_/plain/images/cat.jpg@#{extension}", {:explicit, format})
    end
  end

  test "dangling raw @ leaves output automatic when no explicit format exists" do
    assert {:ok,
            %Plan{
              source: %Plain{path: ["images", "cat.jpg"]},
              output: %Output{mode: :automatic}
            }} = Imgproxy.parse(conn(:get, "/_/plain/images/cat.jpg@"), [])
  end

  test "rejects empty plain source before extension" do
    assert Imgproxy.parse(conn(:get, "/_/plain/@webp"), []) ==
             {:error, {:missing_source_identifier, "plain"}}
  end

  test "rejects multiple raw @ source extension separators" do
    assert Imgproxy.parse(conn(:get, "/_/plain/images/cat.jpg@webp@png"), []) ==
             {:error, {:multiple_source_format_separators, "images/cat.jpg@webp@png"}}
  end

  test "rejects unknown source extensions as parser errors" do
    assert Imgproxy.parse(conn(:get, "/_/plain/images/cat.jpg@unknown"), []) ==
             {:error,
              {:invalid_format, "unknown", ["webp", "avif", "jpeg", "jpg", "png", "best"]}}
  end

  test "rejects best source extension as an unsupported output semantic" do
    assert Imgproxy.parse(conn(:get, "/_/plain/images/cat.jpg@best"), []) ==
             {:error, {:unsupported_output_format, :best}}
  end

  defp operations_for(path) do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             Imgproxy.parse(conn(:get, path), [])

    operations
  end

  defp assert_output_mode(path, mode) do
    assert {:ok, %Plan{output: %Output{mode: ^mode}}} =
             Imgproxy.parse(conn(:get, path), [])
  end

  defp pixels(value), do: %Dimension{unit: :logical_px, value: value}
  defp auto, do: %Dimension{unit: :auto}

  defp anchor(%ImagePlug.Plan.Guide.Gravity{type: :anchor, x: x, y: y}), do: {x, y}

  defp focal_point(%ImagePlug.Plan.Guide.Gravity{
         type: :focal_point,
         x: %Dimension{unit: :ratio, numerator: x_numerator, denominator: x_denominator},
         y: %Dimension{unit: :ratio, numerator: y_numerator, denominator: y_denominator}
       }) do
    {x_numerator, x_denominator, y_numerator, y_denominator}
  end

  defp operation_names(operations), do: Enum.map(operations, &operation_name/1)

  defp operation_name(%Operation.AutoOrient{}), do: :auto_orient
  defp operation_name(%Operation.CropGuided{}), do: :crop_guided

  defp permutations([]), do: [[]]

  defp permutations(list) do
    for item <- list,
        rest <- permutations(list -- [item]) do
      [item | rest]
    end
  end
end
