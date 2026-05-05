defmodule ImagePlug.ParamParser.NativeTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePlug.OutputPlan
  alias ImagePlug.ParamParser.Native
  alias ImagePlug.Pipeline
  alias ImagePlug.Plan
  alias ImagePlug.Source.Plain
  alias ImagePlug.Transform

  test "parses a plain source with no processing options" do
    assert {:ok,
            %Plan{
              source: %Plain{path: ["images", "cat.jpg"]},
              pipelines: [%Pipeline{operations: []}],
              output: %OutputPlan{mode: :automatic}
            }} = Native.parse(conn(:get, "/_/plain/images/cat.jpg"))
  end

  test "supports unsafe as the disabled-signing signature segment" do
    assert {:ok, %Plan{source: %Plain{path: ["images", "cat.jpg"]}}} =
             conn(:get, "/unsafe/plain/images/cat.jpg") |> Native.parse()
  end

  test "rejects unsupported signature segments while signing is disabled" do
    assert Native.parse(conn(:get, "/signed-value/plain/images/cat.jpg")) ==
             {:error, {:unsupported_signature, "signed-value"}}
  end

  test "rejects missing signature" do
    assert Native.parse(conn(:get, "/")) == {:error, :missing_signature}
  end

  test "rejects missing source kind" do
    assert Native.parse(conn(:get, "/_/w:300")) == {:error, :missing_source_kind}
  end

  test "rejects missing plain source identifier" do
    assert Native.parse(conn(:get, "/_/plain")) ==
             {:error, {:missing_source_identifier, "plain"}}
  end

  test "treats option-like segments after plain as source path" do
    assert {:ok, %Plan{source: %Plain{path: ["images", "w:300", "cat.jpg"]}}} =
             conn(:get, "/_/plain/images/w:300/cat.jpg") |> Native.parse()
  end

  test "parses resize and rs full grammar" do
    assert [{Transform.Cover, cover_params}] =
             operations_for("/_/resize:fill:300:200:1:0/plain/images/cat.jpg")

    assert cover_params.width == {:pixels, 300}
    assert cover_params.height == {:pixels, 200}
    assert cover_params.constraint == :none

    assert [{Transform.Scale, scale_params}] =
             operations_for("/_/rs:force:300:200/plain/images/cat.jpg")

    assert scale_params.width == {:pixels, 300}
    assert scale_params.height == {:pixels, 200}
  end

  test "parses omitted resize arguments with imgproxy defaults" do
    assert [{Transform.Contain, width_params}] =
             operations_for("/_/rs:fit:300/plain/images/cat.jpg")

    assert width_params.width == {:pixels, 300}
    assert width_params.height == :auto

    assert [{Transform.Contain, dimensions_params}] =
             operations_for("/_/rs::300:200/plain/images/cat.jpg")

    assert dimensions_params.width == {:pixels, 300}
    assert dimensions_params.height == {:pixels, 200}
  end

  test "rejects empty resize and size option segments" do
    for segment <- ["rs", "rs:", "rs::", "resize", "resize:", "s", "s:", "s::", "size"] do
      assert Native.parse(conn(:get, "/_/#{segment}/plain/images/cat.jpg")) ==
               {:error, {:invalid_option_segment, segment}}
    end
  end

  test "omitted meta-option arguments do not overwrite previous field assignments" do
    assert [{Transform.Cover, params}] =
             operations_for("/_/w:500/rs:fill::200/plain/images/cat.jpg")

    assert params.width == {:pixels, 500}
    assert params.height == {:pixels, 200}
  end

  test "omitted extend argument still parses provided extend gravity tail" do
    assert Native.parse(conn(:get, "/_/rs::::::ce::/plain/images/cat.jpg")) ==
             {:error, {:unsupported_extend_gravity, {:anchor, :center, :center}}}

    assert Native.parse(conn(:get, "/_/s:::::ce::/plain/images/cat.jpg")) ==
             {:error, {:unsupported_extend_gravity, {:anchor, :center, :center}}}
  end

  test "extend gravity invalid arity reports the original option segment" do
    segment = "rs:::::1:ce:1"

    assert Native.parse(conn(:get, "/_/#{segment}/plain/images/cat.jpg")) ==
             {:error, {:invalid_option_segment, segment}}
  end

  test "rejects parsed extend semantics before planning origin work" do
    assert Native.parse(conn(:get, "/_/rs:fit:300:200:0:1:ce:0:0/plain/images/cat.jpg")) ==
             {:error, {:unsupported_extend, true}}
  end

  test "parses size without changing resizing_type" do
    assert [{Transform.Scale, params}] =
             operations_for("/_/rt:force/s:300:200/plain/images/cat.jpg")

    assert params.width == {:pixels, 300}
    assert params.height == {:pixels, 200}
  end

  test "size overwrites dimensions without resetting resizing_type" do
    assert [{Transform.Cover, params}] =
             operations_for("/_/rs:fill:300:200/s:100:100/plain/images/cat.jpg")

    assert params.width == {:pixels, 100}
    assert params.height == {:pixels, 100}
  end

  test "parses supported resizing type aliases into plans and rejects unsupported values" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
             conn(:get, "/_/rt:fit/plain/images/cat.jpg") |> Native.parse()

    assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
             conn(:get, "/_/rt:force/plain/images/cat.jpg") |> Native.parse()

    assert Native.parse(conn(:get, "/_/rt:fill/plain/images/cat.jpg")) ==
             {:error, {:missing_dimensions, :fill}}

    assert Native.parse(conn(:get, "/_/rt:fill-down/plain/images/cat.jpg")) ==
             {:error, {:unsupported_resizing_type, :fill_down}}

    assert Native.parse(conn(:get, "/_/rt:auto/plain/images/cat.jpg")) ==
             {:error, {:unsupported_resizing_type, :auto}}
  end

  test "invalid resizing type reports supported values" do
    assert Native.parse(conn(:get, "/_/rt:crop/plain/images/cat.jpg")) ==
             {:error,
              {:invalid_resizing_type, "crop", ["fit", "fill", "fill-down", "force", "auto"]}}
  end

  test "parses width and height aliases including zero" do
    assert [{Transform.Contain, params}] =
             operations_for("/_/w:0/h:200/plain/images/cat.jpg")

    assert params.width == :auto
    assert params.height == {:pixels, 200}
  end

  test "parses gravity anchors and focal point" do
    assert [{Transform.Focus, anchor_focus}, {Transform.Cover, _cover_params}] =
             operations_for("/_/g:nowe/rs:fill:300:200/plain/images/cat.jpg")

    assert anchor_focus.type == {:anchor, :left, :top}

    assert [{Transform.Focus, focal_focus}, {Transform.Cover, _cover_params}] =
             operations_for("/_/gravity:fp:0.5:0.25/rs:fill:300:200/plain/images/cat.jpg")

    assert focal_focus.type == {:coordinate, {:percent, 50.0}, {:percent, 25.0}}

    assert [{Transform.Focus, edge_focus}, {Transform.Cover, _cover_params}] =
             operations_for("/_/g:fp:1:0/rs:fill:300:200/plain/images/cat.jpg")

    assert edge_focus.type == {:coordinate, {:percent, 100.0}, {:percent, 0.0}}
  end

  test "rejects out-of-range focal point coordinates as gravity coordinate errors" do
    assert Native.parse(conn(:get, "/_/g:fp:1.2:0.5/plain/images/cat.jpg")) ==
             {:error, {:invalid_gravity_coordinate, "1.2"}}

    assert Native.parse(conn(:get, "/_/g:fp:nope:0.5/plain/images/cat.jpg")) ==
             {:error, {:invalid_gravity_coordinate, "nope"}}
  end

  test "rejects smart gravity as an unsupported planner semantic" do
    assert Native.parse(conn(:get, "/_/g:sm/plain/images/cat.jpg")) ==
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

  test "dangling raw @ does not overwrite an explicit format" do
    assert {:ok,
            %Plan{
              source: %Plain{path: ["images", "cat.jpg"]},
              output: %OutputPlan{mode: {:explicit, :webp}}
            }} = Native.parse(conn(:get, "/_/f:webp/plain/images/cat.jpg@"))
  end

  test "rejects format auto because it is not imgproxy grammar" do
    assert Native.parse(conn(:get, "/_/format:auto/plain/images/cat.jpg")) ==
             {:error, {:invalid_format, "auto", ["webp", "avif", "jpeg", "jpg", "png", "best"]}}
  end

  test "later field assignments overwrite earlier assignments" do
    assert [{Transform.Contain, contain_params}] =
             operations_for("/_/w:100/width:200/plain/images/cat.jpg")

    assert contain_params.width == {:pixels, 200}

    assert [{Transform.Cover, resized_params}] =
             operations_for("/_/resize:fill:300:200/w:500/plain/images/cat.jpg")

    assert resized_params.width == {:pixels, 500}
    assert resized_params.height == {:pixels, 200}

    assert [{Transform.Cover, overwritten_params}] =
             operations_for("/_/w:500/resize:fill:300:200/plain/images/cat.jpg")

    assert overwritten_params.width == {:pixels, 300}
    assert overwritten_params.height == {:pixels, 200}

    assert [{Transform.Scale, scale_params}] =
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
            }} = Native.parse(conn(:get, "/_/w:500/-/h:200/plain/images/cat.jpg"))

    assert [{Transform.Contain, first_params}] = first_operations
    assert first_params.width == {:pixels, 500}
    assert first_params.height == :auto

    assert [{Transform.Contain, second_params}] = second_operations
    assert second_params.width == :auto
    assert second_params.height == {:pixels, 200}
  end

  test "rejects malformed chained native pipeline separators" do
    assert {:error, :empty_pipeline_group} =
             Native.parse(conn(:get, "/_/-/w:500/plain/images/cat.jpg"))

    assert {:error, :empty_pipeline_group} =
             Native.parse(conn(:get, "/_/w:500/-/plain/images/cat.jpg"))

    assert {:error, :empty_pipeline_group} =
             Native.parse(conn(:get, "/_/w:500/-/-/h:200/plain/images/cat.jpg"))
  end

  test "preserves no-op single-pipeline behavior" do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
             Native.parse(conn(:get, "/_/plain/images/cat.jpg"))
  end

  test "later field assignments are scoped to each native pipeline" do
    assert {:ok,
            %Plan{
              pipelines: [
                %Pipeline{operations: first_operations},
                %Pipeline{operations: second_operations}
              ]
            }} =
             Native.parse(conn(:get, "/_/w:500/w:600/-/h:200/h:300/plain/images/cat.jpg"))

    assert [{Transform.Contain, first_params}] = first_operations
    assert first_params.width == {:pixels, 600}

    assert [{Transform.Contain, second_params}] = second_operations
    assert second_params.height == {:pixels, 300}
  end

  test "detects raw source extension before percent decoding" do
    assert {:ok,
            %Plan{
              source: %Plain{path: ["images", "cat@v1.jpg"]},
              output: %OutputPlan{mode: {:explicit, :webp}}
            }} = conn(:get, "/_/plain/images/cat%40v1.jpg@webp") |> Native.parse()
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
              output: %OutputPlan{mode: :automatic}
            }} = conn(:get, "/_/plain/images/cat.jpg@") |> Native.parse()
  end

  test "rejects empty plain source before extension" do
    assert Native.parse(conn(:get, "/_/plain/@webp")) ==
             {:error, {:missing_source_identifier, "plain"}}
  end

  test "rejects multiple raw @ source extension separators" do
    assert Native.parse(conn(:get, "/_/plain/images/cat.jpg@webp@png")) ==
             {:error, {:multiple_source_format_separators, "images/cat.jpg@webp@png"}}
  end

  test "rejects unknown source extensions as parser errors" do
    assert Native.parse(conn(:get, "/_/plain/images/cat.jpg@unknown")) ==
             {:error,
              {:invalid_format, "unknown", ["webp", "avif", "jpeg", "jpg", "png", "best"]}}
  end

  test "rejects best source extension as an unsupported output semantic" do
    assert Native.parse(conn(:get, "/_/plain/images/cat.jpg@best")) ==
             {:error, {:unsupported_output_format, :best}}
  end

  defp operations_for(path) do
    assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
             conn(:get, path) |> Native.parse()

    operations
  end

  defp assert_output_mode(path, mode) do
    assert {:ok, %Plan{output: %OutputPlan{mode: ^mode}}} =
             conn(:get, path) |> Native.parse()
  end
end
