defmodule ImagePlug.Parser.NativeTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePlug.Parser.Native
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.Transform

  test "parses a plain source with no processing options" do
    assert {:ok,
            %Plan{
              source: %Plain{path: ["images", "cat.jpg"]},
              pipelines: [%Pipeline{operations: []}],
              output: %Output{mode: :automatic}
            }} = Native.parse(conn(:get, "/_/plain/images/cat.jpg"), [])
  end

  test "parse/2 accepts parser options and keeps no-option parse/1 as a delegating helper" do
    conn = conn(:get, "/_/plain/images/cat.jpg")

    assert Native.parse(conn, []) == Native.parse(conn)
  end

  test "supports unsafe as the disabled-signing signature segment" do
    assert {:ok, %Plan{source: %Plain{path: ["images", "cat.jpg"]}}} =
             Native.parse(conn(:get, "/unsafe/plain/images/cat.jpg"), [])
  end

  test "rejects unsupported signature segments while signing is disabled" do
    assert Native.parse(conn(:get, "/signed-value/plain/images/cat.jpg"), []) ==
             {:error, {:unsupported_signature, "signed-value"}}
  end

  test "rejects missing signature" do
    assert Native.parse(conn(:get, "/"), []) == {:error, :missing_signature}
  end

  test "rejects missing source kind" do
    assert Native.parse(conn(:get, "/_/w:300"), []) == {:error, :missing_source_kind}
  end

  test "rejects missing plain source identifier" do
    assert Native.parse(conn(:get, "/_/plain"), []) ==
             {:error, {:missing_source_identifier, "plain"}}
  end

  test "treats option-like segments after plain as source path" do
    assert {:ok, %Plan{source: %Plain{path: ["images", "w:300", "cat.jpg"]}}} =
             Native.parse(conn(:get, "/_/plain/images/w:300/cat.jpg"), [])
  end

  test "parses resize and rs full grammar" do
    assert [%Transform.Cover{} = cover_params] =
             operations_for("/_/resize:fill:300:200:1:0/plain/images/cat.jpg")

    assert cover_params.width == {:pixels, 300}
    assert cover_params.height == {:pixels, 200}
    assert cover_params.constraint == :none

    assert [%Transform.Scale{} = scale_params] =
             operations_for("/_/rs:force:300:200/plain/images/cat.jpg")

    assert scale_params.width == {:pixels, 300}
    assert scale_params.height == {:pixels, 200}
  end

  test "parses omitted resize arguments with imgproxy defaults" do
    assert [%Transform.Contain{} = width_params] =
             operations_for("/_/rs:fit:300/plain/images/cat.jpg")

    assert width_params.width == {:pixels, 300}
    assert width_params.height == :auto

    assert [%Transform.Contain{} = dimensions_params] =
             operations_for("/_/rs::300:200/plain/images/cat.jpg")

    assert dimensions_params.width == {:pixels, 300}
    assert dimensions_params.height == {:pixels, 200}
  end

  test "rejects empty resize and size option segments" do
    for segment <- ["rs", "rs:", "rs::", "resize", "resize:", "s", "s:", "s::", "size"] do
      assert Native.parse(conn(:get, "/_/#{segment}/plain/images/cat.jpg"), []) ==
               {:error, {:invalid_option_segment, segment}}
    end
  end

  test "omitted meta-option arguments do not overwrite previous field assignments" do
    assert [%Transform.Cover{} = params] =
             operations_for("/_/w:500/rs:fill::200/plain/images/cat.jpg")

    assert params.width == {:pixels, 500}
    assert params.height == {:pixels, 200}
  end

  test "omitted extend argument still parses provided extend gravity tail" do
    assert Native.parse(conn(:get, "/_/rs::::::ce::/plain/images/cat.jpg"), []) ==
             {:error, {:unsupported_extend_gravity, {:anchor, :center, :center}}}

    assert Native.parse(conn(:get, "/_/s:::::ce::/plain/images/cat.jpg"), []) ==
             {:error, {:unsupported_extend_gravity, {:anchor, :center, :center}}}
  end

  test "extend gravity invalid arity reports the original option segment" do
    segment = "rs:::::1:ce:1"

    assert Native.parse(conn(:get, "/_/#{segment}/plain/images/cat.jpg"), []) ==
             {:error, {:invalid_option_segment, segment}}
  end

  test "rejects parsed extend semantics before planning origin work" do
    assert Native.parse(conn(:get, "/_/rs:fit:300:200:0:1:ce:0:0/plain/images/cat.jpg"), []) ==
             {:error, {:unsupported_extend, true}}
  end

  test "parses size without changing resizing_type" do
    assert [%Transform.Scale{} = params] =
             operations_for("/_/rt:force/s:300:200/plain/images/cat.jpg")

    assert params.width == {:pixels, 300}
    assert params.height == {:pixels, 200}
  end

  test "size overwrites dimensions without resetting resizing_type" do
    assert [%Transform.Cover{} = params] =
             operations_for("/_/rs:fill:300:200/s:100:100/plain/images/cat.jpg")

    assert params.width == {:pixels, 100}
    assert params.height == {:pixels, 100}
  end

  test "parses supported resizing type aliases into plans and rejects unsupported values" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
             Native.parse(conn(:get, "/_/rt:fit/plain/images/cat.jpg"), [])

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
             Native.parse(conn(:get, "/_/rt:force/plain/images/cat.jpg"), [])

    assert Native.parse(conn(:get, "/_/rt:fill/plain/images/cat.jpg"), []) ==
             {:error, {:missing_dimensions, :fill}}

    assert Native.parse(conn(:get, "/_/rt:fill-down/plain/images/cat.jpg"), []) ==
             {:error, {:unsupported_resizing_type, :fill_down}}

    assert Native.parse(conn(:get, "/_/rt:auto/plain/images/cat.jpg"), []) ==
             {:error, {:unsupported_resizing_type, :auto}}
  end

  test "invalid resizing type reports supported values" do
    assert Native.parse(conn(:get, "/_/rt:crop/plain/images/cat.jpg"), []) ==
             {:error,
              {:invalid_resizing_type, "crop", ["fit", "fill", "fill-down", "force", "auto"]}}
  end

  test "parses width and height aliases including zero" do
    assert [%Transform.Contain{} = params] =
             operations_for("/_/w:0/h:200/plain/images/cat.jpg")

    assert params.width == :auto
    assert params.height == {:pixels, 200}
  end

  test "parses gravity anchors and focal point" do
    assert [%Transform.Focus{} = anchor_focus, %Transform.Cover{} = _cover_params] =
             operations_for("/_/g:nowe/rs:fill:300:200/plain/images/cat.jpg")

    assert anchor_focus.type == {:anchor, :left, :top}

    assert [%Transform.Focus{} = focal_focus, %Transform.Cover{} = _cover_params] =
             operations_for("/_/gravity:fp:0.5:0.25/rs:fill:300:200/plain/images/cat.jpg")

    assert focal_focus.type == {:coordinate, {:percent, 50.0}, {:percent, 25.0}}

    assert [%Transform.Focus{} = edge_focus, %Transform.Cover{} = _cover_params] =
             operations_for("/_/g:fp:1:0/rs:fill:300:200/plain/images/cat.jpg")

    assert edge_focus.type == {:coordinate, {:percent, 100.0}, {:percent, 0.0}}
  end

  test "rejects out-of-range focal point coordinates as gravity coordinate errors" do
    assert Native.parse(conn(:get, "/_/g:fp:1.2:0.5/plain/images/cat.jpg"), []) ==
             {:error, {:invalid_gravity_coordinate, "1.2"}}

    assert Native.parse(conn(:get, "/_/g:fp:nope:0.5/plain/images/cat.jpg"), []) ==
             {:error, {:invalid_gravity_coordinate, "nope"}}
  end

  test "rejects smart gravity as an unsupported planner semantic" do
    assert Native.parse(conn(:get, "/_/g:sm/plain/images/cat.jpg"), []) ==
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
             Native.parse(conn(:get, "/_/f:webp/-/plain/images/cat.jpg"), [])

    assert operations == []
  end

  test "later global assignments win across groups" do
    assert_output_mode("/_/f:webp/-/f:jpeg/plain/images/cat.jpg", {:explicit, :jpeg})
  end

  test "parses output quality and format quality as output request fields" do
    assert {:ok,
            %Plan{
              output: %ImagePlug.Plan.Output{
                quality: {:quality, 80},
                format_qualities: %{webp: {:quality, 70}}
              }
            }} = Native.parse(conn(:get, "/_/q:80/fq:webp:70/plain/images/cat.jpg"), [])
  end

  test "quality zero and format-quality zero normalize to default" do
    assert {:ok,
            %Plan{
              output: %ImagePlug.Plan.Output{
                quality: :default,
                format_qualities: %{webp: :default}
              }
            }} = Native.parse(conn(:get, "/_/q:0/fq:webp:0/plain/images/cat.jpg"), [])
  end

  test "repeated format quality assignments replace by normalized format" do
    assert {:ok,
            %Plan{
              output: %ImagePlug.Plan.Output{
                format_qualities: %{webp: {:quality, 60}}
              }
            }} =
             Native.parse(conn(:get, "/_/fq:webp:70/-/fq:webp:60/plain/images/cat.jpg"), [])
  end

  test "quality later assignment wins across groups" do
    assert {:ok, %Plan{output: %ImagePlug.Plan.Output{quality: {:quality, 70}}}} =
             Native.parse(conn(:get, "/_/q:80/-/q:70/plain/images/cat.jpg"), [])
  end

  test "format quality normalizes jpg to jpeg" do
    assert {:ok,
            %Plan{
              output: %ImagePlug.Plan.Output{
                format_qualities: %{jpeg: {:quality, 70}}
              }
            }} = Native.parse(conn(:get, "/_/fq:jpg:70/plain/images/cat.jpg"), [])
  end

  test "rejects invalid output quality values" do
    assert Native.parse(conn(:get, "/_/q:101/plain/images/cat.jpg"), []) ==
             {:error, {:invalid_option, :quality, "101"}}

    assert Native.parse(conn(:get, "/_/quality:-1/plain/images/cat.jpg"), []) ==
             {:error, {:invalid_option, :quality, "-1"}}
  end

  test "rejects invalid format quality values" do
    assert Native.parse(conn(:get, "/_/fq:webp:101/plain/images/cat.jpg"), []) ==
             {:error, {:invalid_option, :quality, "101"}}

    assert Native.parse(conn(:get, "/_/format_quality:webp:-1/plain/images/cat.jpg"), []) ==
             {:error, {:invalid_option, :quality, "-1"}}
  end

  test "rejects invalid quality arity" do
    for segment <- ["q", "q:", "q:80:70", "quality", "quality:", "quality:80:70"] do
      assert Native.parse(conn(:get, "/_/#{segment}/plain/images/cat.jpg"), []) ==
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
      assert Native.parse(conn(:get, "/_/#{segment}/plain/images/cat.jpg"), []) ==
               {:error, {:invalid_option_segment, segment}}
    end
  end

  test "global-only and empty groups do not become executable pipelines" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
             Native.parse(conn(:get, "/_/f:webp/-/plain/images/cat.jpg"), [])

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             Native.parse(conn(:get, "/_/-/w:100/plain/images/cat.jpg"), [])

    assert length(operations) == 1
    assert [%{__struct__: _} = operation] = operations
    assert inspect(operation) =~ "100"
  end

  test "dangling raw @ does not overwrite an explicit format" do
    assert {:ok,
            %Plan{
              source: %Plain{path: ["images", "cat.jpg"]},
              output: %Output{mode: {:explicit, :webp}}
            }} = Native.parse(conn(:get, "/_/f:webp/plain/images/cat.jpg@"), [])
  end

  test "rejects format auto because it is not imgproxy grammar" do
    assert Native.parse(conn(:get, "/_/format:auto/plain/images/cat.jpg"), []) ==
             {:error, {:invalid_format, "auto", ["webp", "avif", "jpeg", "jpg", "png", "best"]}}
  end

  test "parses processing options before validating source extension" do
    assert Native.parse(conn(:get, "/_/unknown/plain/images/cat.jpg@unknown"), []) ==
             {:error, {:unknown_option, "unknown"}}
  end

  test "later field assignments overwrite earlier assignments" do
    assert [%Transform.Contain{} = contain_params] =
             operations_for("/_/w:100/width:200/plain/images/cat.jpg")

    assert contain_params.width == {:pixels, 200}

    assert [%Transform.Cover{} = resized_params] =
             operations_for("/_/resize:fill:300:200/w:500/plain/images/cat.jpg")

    assert resized_params.width == {:pixels, 500}
    assert resized_params.height == {:pixels, 200}

    assert [%Transform.Cover{} = overwritten_params] =
             operations_for("/_/w:500/resize:fill:300:200/plain/images/cat.jpg")

    assert overwritten_params.width == {:pixels, 300}
    assert overwritten_params.height == {:pixels, 200}

    assert [%Transform.Scale{} = scale_params] =
             operations_for("/_/size:300:200/rt:force/plain/images/cat.jpg")

    assert scale_params.width == {:pixels, 300}
    assert scale_params.height == {:pixels, 200}
  end

  test "parses chained native pipeline separators into multiple pipelines" do
    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: first_operations},
                %Pipeline{operations: second_operations}
              ]
            }} = Native.parse(conn(:get, "/_/w:500/-/h:200/plain/images/cat.jpg"), [])

    assert [%Transform.Contain{} = first_params] = first_operations
    assert first_params.width == {:pixels, 500}
    assert first_params.height == :auto

    assert [%Transform.Contain{} = second_params] = second_operations
    assert second_params.width == :auto
    assert second_params.height == {:pixels, 200}
  end

  test "ignores empty groups around chained native pipeline separators" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: leading_operations}]}} =
             Native.parse(conn(:get, "/_/-/w:500/plain/images/cat.jpg"), [])

    assert [%Transform.Contain{} = leading_params] = leading_operations
    assert leading_params.width == {:pixels, 500}

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: trailing_operations}]}} =
             Native.parse(conn(:get, "/_/w:500/-/plain/images/cat.jpg"), [])

    assert [%Transform.Contain{} = trailing_params] = trailing_operations
    assert trailing_params.width == {:pixels, 500}

    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: first_operations},
                %Pipeline{operations: second_operations}
              ]
            }} = Native.parse(conn(:get, "/_/w:500/-/-/h:200/plain/images/cat.jpg"), [])

    assert [%Transform.Contain{} = first_params] = first_operations
    assert first_params.width == {:pixels, 500}

    assert [%Transform.Contain{} = second_params] = second_operations
    assert second_params.height == {:pixels, 200}
  end

  test "preserves no-op single-pipeline behavior" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
             Native.parse(conn(:get, "/_/plain/images/cat.jpg"), [])
  end

  test "later field assignments are scoped to each native pipeline" do
    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: first_operations},
                %Pipeline{operations: second_operations}
              ]
            }} =
             Native.parse(conn(:get, "/_/w:500/w:600/-/h:200/h:300/plain/images/cat.jpg"), [])

    assert [%Transform.Contain{} = first_params] = first_operations
    assert first_params.width == {:pixels, 600}

    assert [%Transform.Contain{} = second_params] = second_operations
    assert second_params.height == {:pixels, 300}
  end

  test "detects raw source extension before percent decoding" do
    assert {:ok,
            %Plan{
              source: %Plain{path: ["images", "cat@v1.jpg"]},
              output: %Output{mode: {:explicit, :webp}}
            }} = Native.parse(conn(:get, "/_/plain/images/cat%40v1.jpg@webp"), [])
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
            }} = Native.parse(conn(:get, "/_/plain/images/cat.jpg@"), [])
  end

  test "rejects empty plain source before extension" do
    assert Native.parse(conn(:get, "/_/plain/@webp"), []) ==
             {:error, {:missing_source_identifier, "plain"}}
  end

  test "rejects multiple raw @ source extension separators" do
    assert Native.parse(conn(:get, "/_/plain/images/cat.jpg@webp@png"), []) ==
             {:error, {:multiple_source_format_separators, "images/cat.jpg@webp@png"}}
  end

  test "rejects unknown source extensions as parser errors" do
    assert Native.parse(conn(:get, "/_/plain/images/cat.jpg@unknown"), []) ==
             {:error,
              {:invalid_format, "unknown", ["webp", "avif", "jpeg", "jpg", "png", "best"]}}
  end

  test "rejects best source extension as an unsupported output semantic" do
    assert Native.parse(conn(:get, "/_/plain/images/cat.jpg@best"), []) ==
             {:error, {:unsupported_output_format, :best}}
  end

  defp operations_for(path) do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             Native.parse(conn(:get, path), [])

    operations
  end

  defp assert_output_mode(path, mode) do
    assert {:ok, %Plan{output: %Output{mode: ^mode}}} =
             Native.parse(conn(:get, path), [])
  end
end
