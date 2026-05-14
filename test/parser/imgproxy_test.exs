defmodule ImagePlug.Parser.ImgproxyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Plug.Test

  alias ImagePlug.Parser.Imgproxy
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Response
  alias ImagePlug.Transform.Operation.AutoOrient

  @allowed_parsed_transform_operations [
    ImagePlug.Transform.Operation.AutoOrient,
    ImagePlug.Transform.Operation.Rotate,
    ImagePlug.Transform.Operation.Flip
  ]

  test "parses a plain source with no processing options" do
    assert {:ok,
            %Plan{
              source: {:plain, ["images", "cat.jpg"]},
              pipelines: [%Pipeline{operations: []}],
              output: %Output{mode: :automatic}
            }} = Imgproxy.parse(conn(:get, "/_/plain/images/cat.jpg"), [])
  end

  test "parse/2 accepts parser options and keeps no-option parse/1 as a delegating helper" do
    conn = conn(:get, "/_/plain/images/cat.jpg")

    assert Imgproxy.parse(conn, []) == Imgproxy.parse(conn)
  end

  test "supports unsafe as the disabled-signing signature segment" do
    assert {:ok, %Plan{source: {:plain, ["images", "cat.jpg"]}}} =
             Imgproxy.parse(conn(:get, "/unsafe/plain/images/cat.jpg"), [])
  end

  test "rejects unsupported signature segments while signing is disabled" do
    assert Imgproxy.parse(conn(:get, "/signed-value/plain/images/cat.jpg"), []) ==
             {:error, {:unsupported_signature, "signed-value"}}
  end

  test "accepts valid signed imgproxy URLs when signing is enabled" do
    assert {:ok, %Plan{source: {:plain, ["images", "cat.jpg"]}}} =
             Imgproxy.parse(
               conn(
                 :get,
                 "/NSbxuO5fQqTgDkui_3o6ho1UCFFcmzsugB2Uksho49o/w:300/plain/images/cat.jpg"
               ),
               signed_parser_opts()
             )
  end

  test "signature verification excludes query strings" do
    assert {:ok, %Plan{source: {:plain, ["images", "cat.jpg"]}}} =
             Imgproxy.parse(
               conn(
                 :get,
                 "/NSbxuO5fQqTgDkui_3o6ho1UCFFcmzsugB2Uksho49o/w:300/plain/images/cat.jpg?ignored=true"
               ),
               signed_parser_opts()
             )
  end

  test "signature-only paths fail before verification" do
    assert Imgproxy.parse(conn(:get, "/invalid"), signed_parser_opts()) ==
             {:error, :missing_signed_path}

    empty_signature_conn =
      conn(:get, "/")
      |> Map.put(:request_path, "//w:300/plain/images/cat.jpg")
      |> Map.put(:path_info, ["", "w:300", "plain", "images", "cat.jpg"])

    assert Imgproxy.parse(empty_signature_conn, signed_parser_opts()) ==
             {:error, :missing_signature}
  end

  test "fixPath decodes option separators before verification and parsing" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.Resize{} = resize]}]}} =
             Imgproxy.parse(
               conn(
                 :get,
                 "/NSbxuO5fQqTgDkui_3o6ho1UCFFcmzsugB2Uksho49o/w%3A300/plain/images/cat.jpg"
               ),
               signed_parser_opts()
             )

    assert resize.width == pixels(300)

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.Resize{} = resize]}]}} =
             Imgproxy.parse(
               conn(
                 :get,
                 "/NSbxuO5fQqTgDkui_3o6ho1UCFFcmzsugB2Uksho49o/w%3a300/plain/images/cat.jpg"
               ),
               signed_parser_opts()
             )

    assert resize.width == pixels(300)
  end

  test "fixPath repairs normalized plain URL schemes before verification and parsing" do
    assert {:ok, %Plan{source: {:plain, ["http:", "", "example.com", "image.jpg"]}}} =
             Imgproxy.parse(
               conn(
                 :get,
                 "/rvUfkOxjt_gv1jphcFemDz8PPpIntOx93-72pYGwqV0/plain/http:/example.com/image.jpg"
               ),
               signed_parser_opts()
             )

    assert {:ok, %Plan{source: {:plain, ["local:", "", "", "test1.png"]}}} =
             Imgproxy.parse(
               conn(
                 :get,
                 "/My9d3xq_PYpVHsPrCyww0Kh1w5KZeZhIlWhsa4az1TI/rs:fill:4:4/plain/local:/test1.png"
               ),
               signed_parser_opts()
             )
  end

  test "rejects disabled-signing placeholders when signing is enabled" do
    assert Imgproxy.parse(conn(:get, "/_/plain/images/cat.jpg"), signed_parser_opts()) ==
             {:error, {:invalid_signature_encoding, "_"}}

    assert Imgproxy.parse(conn(:get, "/unsafe/plain/images/cat.jpg"), signed_parser_opts()) ==
             {:error, :invalid_signature}
  end

  test "accepts exact trusted signatures before HMAC decoding" do
    opts = signed_parser_opts(signature: [trusted_signatures: ["local-dev!"]])

    assert {:ok, %Plan{source: {:plain, ["images", "cat.jpg"]}}} =
             Imgproxy.parse(conn(:get, "/local-dev!/w:300/plain/images/cat.jpg"), opts)
  end

  test "rejects invalid signature encodings before parsing options" do
    assert Imgproxy.parse(
             conn(:get, "/local-dev!/raw/plain/images/cat.jpg"),
             signed_parser_opts()
           ) ==
             {:error, {:invalid_signature_encoding, "local-dev!"}}
  end

  test "raw signed path accepts signatures computed over duplicate slashes" do
    assert {:ok, %Plan{source: {:plain, ["", "images", "cat.jpg"]}}} =
             Imgproxy.parse(
               conn(
                 :get,
                 "/LybQypsQbz5rUNXKD0FkRZHzpY7OnbJ8DQcWndArBCw/w:300/plain//images/cat.jpg"
               ),
               signed_parser_opts()
             )
  end

  test "raw signed path accepts signatures computed over trailing slashes" do
    assert {:ok, %Plan{source: {:plain, ["images", "cat.jpg", ""]}}} =
             Imgproxy.parse(
               conn(
                 :get,
                 "/gIg1_oHgCof_KbsU6mYJKyL-SN6TJjbHGQAd9uvh8GU/w:300/plain/images/cat.jpg/"
               ),
               signed_parser_opts()
             )
  end

  test "raw signed path strips only mounted script_name before verification" do
    conn =
      conn(:get, "/proxy/NSbxuO5fQqTgDkui_3o6ho1UCFFcmzsugB2Uksho49o/w:300/plain/images/cat.jpg")
      |> Map.put(:script_name, ["proxy"])
      |> Map.put(:path_info, [
        "NSbxuO5fQqTgDkui_3o6ho1UCFFcmzsugB2Uksho49o",
        "w:300",
        "plain",
        "images",
        "cat.jpg"
      ])

    assert {:ok, %Plan{source: {:plain, ["images", "cat.jpg"]}}} =
             Imgproxy.parse(conn, signed_parser_opts())
  end

  test "signature authorization errors render HTTP 403" do
    assert_error_status(:invalid_signature, 403)

    invalid_encoding_conn =
      assert_error_status({:invalid_signature_encoding, "very-secret-signature"}, 403)

    assert invalid_encoding_conn.resp_body =~ "invalid_signature_encoding"
    refute invalid_encoding_conn.resp_body =~ "very-secret-signature"

    unsupported_conn = assert_error_status({:unsupported_signature, "signed-value"}, 403)
    assert unsupported_conn.resp_body =~ "unsupported_signature"
    refute unsupported_conn.resp_body =~ "signed-value"

    assert_error_status(:missing_signature, 400)
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
    assert {:ok, %Plan{source: {:plain, ["images", "w:300", "cat.jpg"]}}} =
             Imgproxy.parse(conn(:get, "/_/plain/images/w:300/cat.jpg"), [])
  end

  test "parses resize and rs full grammar" do
    assert [%Operation.Resize{mode: :cover} = fill_params] =
             operations_for("/_/resize:fill:300:200:1/plain/images/cat.jpg")

    assert fill_params.width == pixels(300)
    assert fill_params.height == pixels(200)
    assert fill_params.enlargement == :allow

    assert [%Operation.Resize{mode: :stretch} = force_params] =
             operations_for("/_/rs:force:300:200/plain/images/cat.jpg")

    assert force_params.width == pixels(300)
    assert force_params.height == pixels(200)

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
    assert [%Operation.Resize{mode: :fit} = width_params] =
             operations_for("/_/rs:fit:300/plain/images/cat.jpg")

    assert width_params.width == pixels(300)
    assert width_params.height == auto()

    assert [%Operation.Resize{mode: :fit} = dimensions_params] =
             operations_for("/_/rs::300:200/plain/images/cat.jpg")

    assert dimensions_params.width == pixels(300)
    assert dimensions_params.height == pixels(200)
  end

  test "rejects empty resize and size option segments" do
    for segment <- ["rs", "rs:", "rs::", "resize", "resize:", "s", "s:", "s::", "size"] do
      assert Imgproxy.parse(conn(:get, "/_/#{segment}/plain/images/cat.jpg"), []) ==
               {:error, {:invalid_option_segment, segment}}
    end
  end

  test "omitted meta-option arguments do not overwrite previous field assignments" do
    assert [%Operation.Resize{mode: :cover} = params] =
             operations_for("/_/w:500/rs:fill::200/plain/images/cat.jpg")

    assert params.width == pixels(500)
    assert params.height == pixels(200)
  end

  test "omitted extend argument still parses provided extend gravity tail" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             Imgproxy.parse(conn(:get, "/_/rs::::::ce::/plain/images/cat.jpg"), [])

    assert [%Operation.Canvas{placement: placement}] = operations
    assert placement == :center

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             Imgproxy.parse(conn(:get, "/_/s:::::ce::/plain/images/cat.jpg"), [])

    assert [%Operation.Canvas{placement: placement}] = operations
    assert placement == :center
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
    assert [%Operation.Resize{mode: :stretch} = params] =
             operations_for("/_/rt:force/s:300:200/plain/images/cat.jpg")

    assert params.width == pixels(300)
    assert params.height == pixels(200)
  end

  test "size overwrites dimensions without resetting resizing_type" do
    assert [%Operation.Resize{mode: :cover} = params] =
             operations_for("/_/rs:fill:300:200/s:100:100/plain/images/cat.jpg")

    assert params.width == pixels(100)
    assert params.height == pixels(100)
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

  describe "padding parsing" do
    test "parses imgproxy padding shorthand into accumulated fields" do
      assert %{padding_top: 10, padding_right: 10, padding_bottom: 10, padding_left: 10} =
               parsed_pipeline!("/_/padding:10/plain/images/cat.jpg")

      assert %{padding_top: 10, padding_right: 20, padding_bottom: 10, padding_left: 20} =
               parsed_pipeline!("/_/padding:10:20/plain/images/cat.jpg")

      assert %{padding_top: 10, padding_right: 20, padding_bottom: 30, padding_left: 20} =
               parsed_pipeline!("/_/padding:10:20:30/plain/images/cat.jpg")

      assert %{padding_top: 10, padding_right: 20, padding_bottom: 30, padding_left: 40} =
               parsed_pipeline!("/_/padding:10:20:30:40/plain/images/cat.jpg")
    end

    test "parses sparse padding with imgproxy accumulated field semantics" do
      assert %{padding_top: 10, padding_right: 10, padding_bottom: 10, padding_left: 10} =
               parsed_pipeline!("/_/padding:10:/plain/images/cat.jpg")

      assert %{padding_top: nil, padding_right: 20, padding_bottom: nil, padding_left: 20} =
               parsed_pipeline!("/_/padding::20/plain/images/cat.jpg")

      assert %{padding_top: 10, padding_right: 10, padding_bottom: 30, padding_left: 10} =
               parsed_pipeline!("/_/padding:10::30/plain/images/cat.jpg")

      assert %{padding_top: 10, padding_right: 5, padding_bottom: 10, padding_left: 5} =
               parsed_pipeline!("/_/pd:10:20:30:40/padding::5/plain/images/cat.jpg")
    end

    test "padding empty and zero forms are accepted by source-compatible parser behavior" do
      assert %{padding_top: nil, padding_right: nil, padding_bottom: nil, padding_left: nil} =
               parsed_pipeline!("/_/padding:/plain/images/cat.jpg")

      assert %{padding_top: 0, padding_right: 0, padding_bottom: 0, padding_left: 0} =
               parsed_pipeline!("/_/pd:10:20:30:40/padding:0/plain/images/cat.jpg")
    end

    test "rejects malformed padding syntax" do
      for path <- [
            "/_/padding:1:2:3:4:5/plain/images/cat.jpg",
            "/_/padding:-1/plain/images/cat.jpg",
            "/_/padding:one/plain/images/cat.jpg"
          ] do
        assert {:error, _reason} = Imgproxy.parse_request(conn(:get, path), [])
      end
    end
  end

  describe "background parsing" do
    test "parses decimal and hex background colors into Plan color" do
      assert {:ok, red} = ImagePlug.Plan.Color.rgb(255, 0, 0)

      assert %{background_color: ^red} =
               parsed_pipeline!("/_/background:255:0:0/plain/images/cat.jpg")

      assert %{background_color: ^red} = parsed_pipeline!("/_/bg:f00/plain/images/cat.jpg")
      assert %{background_color: ^red} = parsed_pipeline!("/_/bg:FF0000/plain/images/cat.jpg")
    end

    test "empty background clears an accumulated background" do
      assert %{background_color: nil} =
               parsed_pipeline!("/_/bg:f00/background:/plain/images/cat.jpg")
    end

    test "rejects malformed and unsupported background options" do
      for path <- [
            "/_/background:256:0:0/plain/images/cat.jpg",
            "/_/background:1:2/plain/images/cat.jpg",
            "/_/background:1::2/plain/images/cat.jpg",
            "/_/background:ffff/plain/images/cat.jpg",
            "/_/background_alpha:0.5/plain/images/cat.jpg",
            "/_/bga:0.5/plain/images/cat.jpg"
          ] do
        assert {:error, _reason} = Imgproxy.parse_request(conn(:get, path), [])
      end
    end
  end

  test "public parse plans supported geometry pipeline semantics" do
    assert {:ok,
            %Plan{pipelines: [%Pipeline{operations: [%Operation.Resize{mode: :fit} = resize]}]}} =
             Imgproxy.parse(conn(:get, "/_/z:2/plain/images/cat.jpg"), [])

    assert resize.zoom_x == 2.0
    assert resize.zoom_y == 2.0

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.CropGuided{} = crop]}]}} =
             Imgproxy.parse(conn(:get, "/_/crop:10:20/plain/images/cat.jpg"), [])

    assert crop.width == {:px, 10}
    assert crop.height == {:px, 20}
    assert crop.guide == :center

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%AutoOrient{}]}]}} =
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
                    %Operation.Resize{mode: :cover} = resize
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
                  operations: [%Operation.Resize{mode: :auto}]
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
    assert [%Operation.Resize{mode: :fit} = params] =
             operations_for("/_/w:0/h:200/plain/images/cat.jpg")

    assert params.width == auto()
    assert params.height == pixels(200)

    assert {:ok,
            %Plan{pipelines: [%Pipeline{operations: [%Operation.Resize{mode: :fit} = resize]}]}} =
             Imgproxy.parse(conn(:get, "/_/w:0/h:0/mw:300/plain/images/cat.jpg"), [])

    assert resize.width == auto()
    assert resize.height == auto()
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

  test "parsed plans contain no executable transform operations except orientation primitives" do
    for path <- [
          "/_/rt:force/w:0/h:200/plain/images/cat.jpg",
          "/_/g:fp:0.25:0.75/rs:fill:300:200/plain/images/cat.jpg",
          "/_/c:100:100:fp:0.25:0.75/plain/images/cat.jpg",
          "/_/rs:fit:300:200:0:1:ce:0:0/plain/images/cat.jpg",
          "/_/ar/rot:-90/fl:true:false/plain/images/cat.jpg"
        ] do
      assert {:ok, %Plan{} = plan} = Imgproxy.parse(conn(:get, path), [])

      assert forbidden_parsed_transform_operations(plan) == []
    end
  end

  test "plans gravity-bearing fill and auto result crops" do
    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{
                  operations: [%Operation.Resize{mode: :cover} = crop]
                }
              ]
            }} =
             Imgproxy.parse(conn(:get, "/_/g:nowe/rs:fill:300:200/plain/images/cat.jpg"), [])

    assert anchor(crop.guide) == {:left, :top}

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{
                  operations: [%Operation.Resize{mode: :cover} = crop]
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
                  operations: [%Operation.Resize{mode: :cover} = crop]
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
                    %Operation.Resize{mode: :auto} = crop
                  ]
                }
              ]
            }} =
             Imgproxy.parse(conn(:get, "/_/g:soea/rt:auto/w:300/h:200/plain/images/cat.jpg"), [])

    assert anchor(crop.guide) == {:right, :bottom}

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{
                  operations: [
                    %Operation.Resize{mode: :auto} = crop
                  ]
                }
              ]
            }} =
             Imgproxy.parse(
               conn(:get, "/_/g:soea:8:-0.5/rt:auto/w:300/h:200/plain/images/cat.jpg"),
               []
             )

    assert anchor(crop.guide) == {:right, :bottom}
    assert crop.x_offset == {:pixels, -8.0}
    assert crop.y_offset == {:scale, 0.5}
  end

  test "parses top-level gravity offsets and plans result crop resize fields" do
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
                  operations: [%Operation.Resize{mode: :cover} = crop]
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
    assert {:ok, %Plan{cachebuster: "abc"}} =
             Imgproxy.parse(conn(:get, "/_/cb:abc/plain/images/cat.jpg"), [])

    assert {:ok, %Plan{cachebuster: "def"}} =
             Imgproxy.parse(conn(:get, "/_/cachebuster:def/plain/images/cat.jpg"), [])
  end

  test "cachebuster later assignment wins across groups" do
    assert {:ok, %Plan{cachebuster: "b"}} =
             Imgproxy.parse(conn(:get, "/_/cb:a/-/cachebuster:b/plain/images/cat.jpg"), [])
  end

  test "expires rejects expired requests with injectable clock" do
    clock = clock_at(101)

    assert Imgproxy.parse(conn(:get, "/_/expires:100/plain/images/cat.jpg"), clock: clock) ==
             {:error, {:expired_request, 100}}

    assert {:ok, %Plan{expires: 100}} =
             Imgproxy.parse(conn(:get, "/_/exp:100/plain/images/cat.jpg"), clock: clock_at(100))

    assert {:ok, %Plan{expires: 0}} =
             Imgproxy.parse(conn(:get, "/_/expires:0/plain/images/cat.jpg"), clock: clock_at(999))
  end

  test "expires later assignment wins across groups" do
    assert {:ok, %Plan{expires: 200}} =
             Imgproxy.parse(
               conn(:get, "/_/exp:100/-/expires:200/plain/images/cat.jpg"),
               clock: clock_at(100)
             )
  end

  test "clock function is called once per parse attempt" do
    test_pid = self()

    clock = fn ->
      send(test_pid, :clock_called)
      DateTime.from_unix!(100)
    end

    assert {:ok, %Plan{expires: 100}} =
             Imgproxy.parse(conn(:get, "/_/exp:100/plain/images/cat.jpg"), clock: clock)

    assert_received :clock_called
    refute_received :clock_called
  end

  test "expires rejects malformed values" do
    assert Imgproxy.parse(conn(:get, "/_/exp:not-int/plain/images/cat.jpg"), clock: clock_at(100)) ==
             {:error, {:invalid_expires, "not-int"}}

    assert Imgproxy.parse(conn(:get, "/_/exp:-1/plain/images/cat.jpg"), clock: clock_at(100)) ==
             {:error, {:invalid_expires, "-1"}}
  end

  test "rejects invalid expires arity" do
    for segment <- ["exp", "exp:", "exp:100:200", "expires", "expires:", "expires:100:200"] do
      assert Imgproxy.parse(conn(:get, "/_/#{segment}/plain/images/cat.jpg"),
               clock: clock_at(100)
             ) ==
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
                filename: "report"
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
                filename: "katt-æøå"
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
                filename: "cat.jpg"
              }
            }} = Imgproxy.parse(conn(:get, "/_/fn:cat.jpg/plain/images/source.jpg@webp"), [])

    assert {:ok,
            %Plan{
              response: %Response{
                filename: "source"
              }
            }} = Imgproxy.parse(conn(:get, "/_/plain/images/source.jpg@webp"), [])
  end

  test "filename and attachment later assignments win across groups" do
    assert {:ok,
            %Plan{
              response: %Response{
                disposition: :inline,
                filename: "two"
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
              source: {:plain, ["images", "cat.jpg"]},
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
    assert [%Operation.Resize{mode: :fit} = contain_params] =
             operations_for("/_/w:100/width:200/plain/images/cat.jpg")

    assert contain_params.width == pixels(200)

    assert [%Operation.Resize{mode: :cover} = resized_params] =
             operations_for("/_/resize:fill:300:200/w:500/plain/images/cat.jpg")

    assert resized_params.width == pixels(500)
    assert resized_params.height == pixels(200)

    assert [%Operation.Resize{mode: :cover} = overwritten_params] =
             operations_for("/_/w:500/resize:fill:300:200/plain/images/cat.jpg")

    assert overwritten_params.width == pixels(300)
    assert overwritten_params.height == pixels(200)

    assert [%Operation.Resize{mode: :stretch} = scale_params] =
             operations_for("/_/size:300:200/rt:force/plain/images/cat.jpg")

    assert scale_params.width == pixels(300)
    assert scale_params.height == pixels(200)
  end

  test "expands named imgproxy presets into normal processing plans" do
    opts = preset_opts(%{"thumb" => "rt:fill/w:120/h:90"})

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%Operation.Resize{} = resize]}]}} =
             Imgproxy.parse(conn(:get, "/_/preset:thumb/plain/images/cat.jpg"), opts)

    assert resize.mode == :cover
    assert resize.width == pixels(120)
    assert resize.height == pixels(90)
  end

  test "expands pr alias and multiple preset names in order" do
    opts =
      preset_opts(%{
        "thumb" => "w:120/h:90",
        "wide" => "w:320",
        "jpeg" => "f:jpg/q:82"
      })

    assert {:ok,
            %Plan{
              pipelines: [%Pipeline{operations: [%Operation.Resize{} = resize]}],
              output: %Output{mode: {:explicit, :jpeg}, quality: {:quality, 82}}
            }} = Imgproxy.parse(conn(:get, "/_/pr:thumb:wide:jpeg/plain/images/cat.jpg"), opts)

    assert resize.width == pixels(320)
    assert resize.height == pixels(90)
  end

  test "applies default preset before URL options so URL fields can override it" do
    opts = preset_opts(%{"default" => "rt:fill/w:300/h:200/q:70"})

    assert {:ok,
            %Plan{
              pipelines: [%Pipeline{operations: [%Operation.Resize{} = resize]}],
              output: %Output{quality: {:quality, 70}}
            }} = Imgproxy.parse(conn(:get, "/_/w:150/plain/images/cat.jpg"), opts)

    assert resize.mode == :cover
    assert resize.width == pixels(150)
    assert resize.height == pixels(200)
  end

  test "expands presets that reference other presets" do
    opts =
      preset_opts(%{
        "thumb" => "w:120/h:90",
        "sharp-thumb" => "pr:thumb/q:82"
      })

    assert {:ok,
            %Plan{
              pipelines: [%Pipeline{operations: [%Operation.Resize{} = resize]}],
              output: %Output{quality: {:quality, 82}}
            }} = Imgproxy.parse(conn(:get, "/_/pr:sharp-thumb/plain/images/cat.jpg"), opts)

    assert resize.width == pixels(120)
    assert resize.height == pixels(90)
  end

  test "skips direct recursive preset re-entry and continues expansion" do
    opts = preset_opts(%{"loop" => "pr:loop/w:100/h:80/q:72"})

    assert {:ok,
            %Plan{
              pipelines: [%Pipeline{operations: [%Operation.Resize{} = resize]}],
              output: %Output{quality: {:quality, 72}}
            }} = Imgproxy.parse(conn(:get, "/_/pr:loop/plain/images/cat.jpg"), opts)

    assert resize.width == pixels(100)
    assert resize.height == pixels(80)
  end

  test "skips indirect recursive preset re-entry and keeps reachable options" do
    opts =
      preset_opts(%{
        "a" => "w:100/pr:b/q:70",
        "b" => "h:80/pr:a/f:webp"
      })

    assert {:ok,
            %Plan{
              pipelines: [%Pipeline{operations: [%Operation.Resize{} = resize]}],
              output: %Output{mode: {:explicit, :webp}, quality: {:quality, 70}}
            }} = Imgproxy.parse(conn(:get, "/_/pr:a/plain/images/cat.jpg"), opts)

    assert resize.width == pixels(100)
    assert resize.height == pixels(80)
  end

  test "returns parser errors for missing empty and unknown preset references" do
    opts = preset_opts(%{"thumb" => "w:100"})

    assert Imgproxy.parse(conn(:get, "/_/preset/plain/images/cat.jpg"), opts) ==
             {:error, {:invalid_option_segment, "preset"}}

    assert Imgproxy.parse(conn(:get, "/_/pr/plain/images/cat.jpg"), opts) ==
             {:error, {:invalid_option_segment, "pr"}}

    assert Imgproxy.parse(conn(:get, "/_/preset:/plain/images/cat.jpg"), opts) ==
             {:error, {:invalid_option_segment, "preset:"}}

    assert Imgproxy.parse(conn(:get, "/_/pr::/plain/images/cat.jpg"), opts) ==
             {:error, {:invalid_option_segment, "pr::"}}

    assert Imgproxy.parse(conn(:get, "/_/pr:missing/plain/images/cat.jpg"), opts) ==
             {:error, {:unknown_preset, "missing"}}
  end

  test "rejects unsupported options inside a used preset like direct URL options" do
    opts = preset_opts(%{"future" => "sharpen:0.7"})

    assert Imgproxy.parse(conn(:get, "/_/pr:future/plain/images/cat.jpg"), opts) ==
             {:error, {:unknown_option, "sharpen"}}
  end

  test "rejects planner-unsupported output values inside a used preset like direct URL options" do
    opts = preset_opts(%{"best" => "f:best"})

    assert Imgproxy.parse(conn(:get, "/_/pr:best/plain/images/cat.jpg"), opts) ==
             {:error, {:unsupported_output_format, :best}}
  end

  test "rejects planner-unsupported transform semantics inside a used preset like direct URL options" do
    opts = preset_opts(%{"smart" => "g:sm"})

    assert Imgproxy.parse(conn(:get, "/_/pr:smart/plain/images/cat.jpg"), opts) ==
             {:error, {:unsupported_gravity, :sm}}
  end

  test "merges preset pipeline groups with URL pipeline groups" do
    opts =
      preset_opts(%{
        "test" => "width:300/height:300/-/width:200/height:200/-/width:100/height:200"
      })

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: first_operations},
                %Pipeline{operations: second_operations},
                %Pipeline{operations: third_operations},
                %Pipeline{operations: fourth_operations}
              ]
            }} =
             Imgproxy.parse(
               conn(
                 :get,
                 "/_/width:400/-/preset:test/width:500/-/width:600/plain/images/cat.jpg"
               ),
               opts
             )

    assert [%Operation.Resize{} = first] = first_operations
    assert first.width == pixels(400)
    assert first.height == auto()

    assert [%Operation.Resize{} = second] = second_operations
    assert second.width == pixels(500)
    assert second.height == pixels(300)

    assert [%Operation.Resize{} = third] = third_operations
    assert third.width == pixels(600)
    assert third.height == pixels(200)

    assert [%Operation.Resize{} = fourth] = fourth_operations
    assert fourth.width == pixels(100)
    assert fourth.height == pixels(200)
  end

  test "turns trailing queued preset groups into trailing pipelines" do
    opts = preset_opts(%{"responsive" => "w:900/-/w:450"})

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: first_operations},
                %Pipeline{operations: second_operations}
              ]
            }} = Imgproxy.parse(conn(:get, "/_/pr:responsive/plain/images/cat.jpg"), opts)

    assert [%Operation.Resize{} = first] = first_operations
    assert first.width == pixels(900)

    assert [%Operation.Resize{} = second] = second_operations
    assert second.width == pixels(450)
  end

  test "applies default preset pipeline groups before URL groups" do
    opts = preset_opts(%{"default" => "w:900/-/w:450"})

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: first_operations},
                %Pipeline{operations: second_operations}
              ]
            }} = Imgproxy.parse(conn(:get, "/_/w:100/-/h:200/plain/images/cat.jpg"), opts)

    assert [%Operation.Resize{} = first] = first_operations
    assert first.width == pixels(100)
    assert first.height == auto()

    assert [%Operation.Resize{} = second] = second_operations
    assert second.width == pixels(450)
    assert second.height == pixels(200)
  end

  test "merges same-offset queued groups from multiple presets into the same later pipeline" do
    opts =
      preset_opts(%{
        "wide" => "w:300/-/w:100",
        "tall" => "h:300/-/h:200"
      })

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: first_operations},
                %Pipeline{operations: second_operations}
              ]
            }} = Imgproxy.parse(conn(:get, "/_/pr:wide:tall/-/h:400/plain/images/cat.jpg"), opts)

    assert [%Operation.Resize{} = first] = first_operations
    assert first.width == pixels(300)
    assert first.height == pixels(300)

    assert [%Operation.Resize{} = second] = second_operations
    assert second.width == pixels(100)
    assert second.height == pixels(400)
  end

  test "merges same-offset default and explicit preset groups into the same later pipeline" do
    opts =
      preset_opts(%{
        "default" => "w:900/-/h:450",
        "responsive" => "h:900/-/w:450"
      })

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: first_operations},
                %Pipeline{operations: second_operations}
              ]
            }} = Imgproxy.parse(conn(:get, "/_/pr:responsive/-/h:100/plain/images/cat.jpg"), opts)

    assert [%Operation.Resize{} = first] = first_operations
    assert first.width == pixels(900)
    assert first.height == pixels(900)

    assert [%Operation.Resize{} = second] = second_operations
    assert second.width == pixels(450)
    assert second.height == pixels(100)
  end

  test "parses chained imgproxy pipeline separators into multiple pipelines" do
    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: first_operations},
                %Pipeline{operations: second_operations}
              ]
            }} = Imgproxy.parse(conn(:get, "/_/w:500/-/h:200/plain/images/cat.jpg"), [])

    assert [%Operation.Resize{mode: :fit} = first_params] = first_operations
    assert first_params.width == pixels(500)
    assert first_params.height == auto()

    assert [%Operation.Resize{mode: :fit} = second_params] = second_operations
    assert second_params.width == auto()
    assert second_params.height == pixels(200)
  end

  test "ignores empty groups around chained imgproxy pipeline separators" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: leading_operations}]}} =
             Imgproxy.parse(conn(:get, "/_/-/w:500/plain/images/cat.jpg"), [])

    assert [%Operation.Resize{mode: :fit} = leading_params] = leading_operations
    assert leading_params.width == pixels(500)

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: trailing_operations}]}} =
             Imgproxy.parse(conn(:get, "/_/w:500/-/plain/images/cat.jpg"), [])

    assert [%Operation.Resize{mode: :fit} = trailing_params] = trailing_operations
    assert trailing_params.width == pixels(500)

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: first_operations},
                %Pipeline{operations: second_operations}
              ]
            }} = Imgproxy.parse(conn(:get, "/_/w:500/-/-/h:200/plain/images/cat.jpg"), [])

    assert [%Operation.Resize{mode: :fit} = first_params] = first_operations
    assert first_params.width == pixels(500)

    assert [%Operation.Resize{mode: :fit} = second_params] = second_operations
    assert second_params.height == pixels(200)
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

    assert [%Operation.Resize{mode: :fit} = first_params] = first_operations
    assert first_params.width == pixels(600)

    assert [%Operation.Resize{mode: :fit} = second_params] = second_operations
    assert second_params.height == pixels(300)
  end

  test "detects raw source extension before percent decoding" do
    assert {:ok,
            %Plan{
              source: {:plain, ["images", "cat@v1.jpg"]},
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
              source: {:plain, ["images", "cat.jpg"]},
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

  defp parsed_pipeline!(path) do
    assert {:ok, parsed} = Imgproxy.parse_request(conn(:get, path), [])
    [pipeline] = parsed.pipelines
    pipeline
  end

  defp assert_output_mode(path, mode) do
    assert {:ok, %Plan{output: %Output{mode: ^mode}}} =
             Imgproxy.parse(conn(:get, path), [])
  end

  defp signed_parser_opts(overrides \\ []) do
    imgproxy_opts =
      [signature: [keys: ["746573742d6b6579"], salts: ["746573742d73616c74"]]]
      |> Keyword.merge(overrides)
      |> Imgproxy.validate_options!()

    [imgproxy: imgproxy_opts]
  end

  defp preset_opts(definitions) do
    [imgproxy: Imgproxy.validate_options!(presets: definitions)]
  end

  defp assert_error_status(reason, status) do
    conn = Imgproxy.handle_error(conn(:get, "/"), {:error, reason})

    assert conn.status == status

    conn
  end

  defp pixels(value), do: {:px, value}
  defp auto, do: :auto
  defp clock_at(unix), do: fn -> DateTime.from_unix!(unix) end

  defp anchor(:center), do: {:center, :center}
  defp anchor({:anchor, x, y}), do: {x, y}

  defp focal_point(
         {:focal, {:ratio, x_numerator, x_denominator}, {:ratio, y_numerator, y_denominator}}
       ) do
    {x_numerator, x_denominator, y_numerator, y_denominator}
  end

  defp operation_names(operations), do: Enum.map(operations, &operation_name/1)

  defp operation_name(%AutoOrient{}), do: :auto_orient
  defp operation_name(%Operation.CropGuided{}), do: :crop_guided

  defp forbidden_parsed_transform_operations(%Plan{} = plan) do
    plan.pipelines
    |> Enum.flat_map(& &1.operations)
    |> Enum.filter(&forbidden_parsed_transform_operation?/1)
  end

  defp forbidden_parsed_transform_operation?(%{__struct__: module}) do
    transform_operation_module?(module) and module not in @allowed_parsed_transform_operations
  end

  defp forbidden_parsed_transform_operation?(_operation), do: false

  defp transform_operation_module?(module) do
    module
    |> Module.split()
    |> Enum.take(3)
    |> Kernel.==(["ImagePlug", "Transform", "Operation"])
  end

  defp permutations([]), do: [[]]

  defp permutations(list) do
    for item <- list,
        rest <- permutations(list -- [item]) do
      [item | rest]
    end
  end
end
