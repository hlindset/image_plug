defmodule ImagePlug.PipelinePlannerTest do
  use ExUnit.Case, async: true

  alias ImagePlug.PipelinePlanner
  alias ImagePlug.ProcessingRequest
  alias ImagePlug.Transform

  test "plans no transforms for a plain request without dimensions or explicit output" do
    assert PipelinePlanner.plan(request()) == {:ok, []}
  end

  test "plans width-only fit as contain with auto height and max constraint" do
    assert PipelinePlanner.plan(request(width: {:pixels, 300})) ==
             {:ok,
              [
                {Transform.Contain,
                 %Transform.Contain.ContainParams{
                   type: :dimensions,
                   width: {:pixels, 300},
                   height: :auto,
                   constraint: :max,
                   letterbox: false
                 }}
              ]}
  end

  test "plans zero dimensions according to fit semantics" do
    assert PipelinePlanner.plan(request(width: {:pixels, 0}, height: {:pixels, 0})) ==
             {:ok, []}

    assert PipelinePlanner.plan(request(width: {:pixels, 0}, height: {:pixels, 200})) ==
             {:ok,
              [
                {Transform.Contain,
                 %Transform.Contain.ContainParams{
                   type: :dimensions,
                   width: :auto,
                   height: {:pixels, 200},
                   constraint: :max,
                   letterbox: false
                 }}
              ]}
  end

  test "maps enlarge to fit constraints" do
    assert {:ok,
            [
              {Transform.Contain,
               %Transform.Contain.ContainParams{constraint: :max, letterbox: false}}
            ]} = PipelinePlanner.plan(request(width: {:pixels, 300}, enlarge: false))

    assert {:ok,
            [
              {Transform.Contain,
               %Transform.Contain.ContainParams{constraint: :regular, letterbox: false}}
            ]} = PipelinePlanner.plan(request(width: {:pixels, 300}, enlarge: true))
  end

  test "maps enlarge to fill constraints" do
    assert {:ok, [{Transform.Cover, %Transform.Cover.CoverParams{constraint: :max}}]} =
             PipelinePlanner.plan(
               request(resizing_type: :fill, width: {:pixels, 300}, height: {:pixels, 200})
             )

    assert {:ok, [{Transform.Cover, %Transform.Cover.CoverParams{constraint: :none}}]} =
             PipelinePlanner.plan(
               request(
                 resizing_type: :fill,
                 width: {:pixels, 300},
                 height: {:pixels, 200},
                 enlarge: true
               )
             )
  end

  test "plans zero fill dimensions as no geometry" do
    assert PipelinePlanner.plan(
             request(resizing_type: :fill, width: {:pixels, 0}, height: {:pixels, 0})
           ) == {:ok, []}
  end

  test "plans zero fill dimensions with explicit output as output only" do
    assert PipelinePlanner.plan(
             request(
               resizing_type: :fill,
               width: {:pixels, 0},
               height: {:pixels, 0},
               format: :webp
             )
           ) == {:ok, [{Transform.Output, %Transform.Output.OutputParams{format: :webp}}]}
  end

  test "plans fill with non-center anchor gravity as focus before cover" do
    assert PipelinePlanner.plan(
             request(
               resizing_type: :fill,
               width: {:pixels, 300},
               height: {:pixels, 200},
               gravity: {:anchor, :left, :top}
             )
           ) ==
             {:ok,
              [
                {Transform.Focus, %Transform.Focus.FocusParams{type: {:anchor, :left, :top}}},
                {Transform.Cover,
                 %Transform.Cover.CoverParams{
                   type: :dimensions,
                   width: {:pixels, 300},
                   height: {:pixels, 200},
                   constraint: :max
                 }}
              ]}
  end

  test "plans fill with focal point gravity as percent coordinate focus before cover" do
    assert PipelinePlanner.plan(
             request(
               resizing_type: :fill,
               width: {:pixels, 300},
               height: {:pixels, 200},
               gravity: {:fp, 0.5, 0.25}
             )
           ) ==
             {:ok,
              [
                {Transform.Focus,
                 %Transform.Focus.FocusParams{
                   type: {:coordinate, {:percent, 50.0}, {:percent, 25.0}}
                 }},
                {Transform.Cover,
                 %Transform.Cover.CoverParams{
                   type: :dimensions,
                   width: {:pixels, 300},
                   height: {:pixels, 200},
                   constraint: :max
                 }}
              ]}
  end

  test "plans force as scale" do
    assert PipelinePlanner.plan(
             request(resizing_type: :force, width: {:pixels, 300}, height: nil)
           ) ==
             {:ok,
              [
                {Transform.Scale,
                 %Transform.Scale.ScaleParams{
                   type: :dimensions,
                   width: {:pixels, 300},
                   height: :auto
                 }}
              ]}
  end

  test "plans force without dimensions as no geometry" do
    assert PipelinePlanner.plan(request(resizing_type: :force)) == {:ok, []}
  end

  test "plans force without dimensions with explicit output as output only" do
    assert PipelinePlanner.plan(request(resizing_type: :force, format: :webp)) ==
             {:ok, [{Transform.Output, %Transform.Output.OutputParams{format: :webp}}]}
  end

  test "appends explicit output format last" do
    assert {:ok, chain} = PipelinePlanner.plan(request(width: {:pixels, 300}, format: :webp))

    assert [
             {Transform.Contain, %Transform.Contain.ContainParams{}},
             {Transform.Output, %Transform.Output.OutputParams{format: :webp}}
           ] = chain
  end

  test "appends explicit output format when no geometry is planned" do
    assert PipelinePlanner.plan(request(format: :png)) ==
             {:ok, [{Transform.Output, %Transform.Output.OutputParams{format: :png}}]}
  end

  test "rejects unsupported semantic combinations" do
    assert PipelinePlanner.plan(request(format: :best)) ==
             {:error, {:unsupported_output_format, :best}}

    assert PipelinePlanner.plan(request(format: :gif)) ==
             {:error, {:invalid_output_format, :gif}}

    assert PipelinePlanner.plan(request(gravity: :sm)) == {:error, {:unsupported_gravity, :sm}}

    assert PipelinePlanner.plan(request(resizing_type: :auto)) ==
             {:error, {:unsupported_resizing_type, :auto}}

    assert PipelinePlanner.plan(request(resizing_type: :fill_down)) ==
             {:error, {:unsupported_resizing_type, :fill_down}}

    assert PipelinePlanner.plan(request(extend: true)) == {:error, {:unsupported_extend, true}}

    assert PipelinePlanner.plan(request(extend_gravity: {:anchor, :left, :top})) ==
             {:error, {:unsupported_extend_gravity, {:anchor, :left, :top}}}

    assert PipelinePlanner.plan(request(extend_x_offset: 5.0)) ==
             {:error, {:unsupported_extend_offset, 5.0}}

    assert PipelinePlanner.plan(request(extend_y_offset: -3.0)) ==
             {:error, {:unsupported_extend_offset, -3.0}}

    assert PipelinePlanner.plan(request(gravity_x_offset: 1.0)) ==
             {:error, {:unsupported_gravity_offset, {1.0, 0.0}}}

    assert PipelinePlanner.plan(request(gravity_y_offset: -2.0)) ==
             {:error, {:unsupported_gravity_offset, {0.0, -2.0}}}
  end

  test "rejects invalid enum values from pluggable parsers" do
    assert PipelinePlanner.plan(request(resizing_type: :bogus)) ==
             {:error, {:invalid_resizing_type, :bogus}}

    assert PipelinePlanner.plan(
             request(
               resizing_type: :fill,
               width: {:pixels, 300},
               height: {:pixels, 200},
               gravity: :bogus
             )
           ) == {:error, {:invalid_gravity, :bogus}}

    assert PipelinePlanner.plan(
             request(
               resizing_type: :fill,
               width: {:pixels, 300},
               height: {:pixels, 200},
               gravity: {:fp, -0.1, 0.5}
             )
           ) == {:error, {:invalid_gravity, {:fp, -0.1, 0.5}}}

    assert PipelinePlanner.plan(
             request(
               resizing_type: :fill,
               width: {:pixels, 300},
               height: {:pixels, 200},
               gravity: {:fp, 0.5, 1.1}
             )
           ) == {:error, {:invalid_gravity, {:fp, 0.5, 1.1}}}
  end

  test "rejects fill without both dimensions" do
    assert PipelinePlanner.plan(request(resizing_type: :fill)) ==
             {:error, {:missing_dimensions, :fill}}

    assert PipelinePlanner.plan(request(resizing_type: :fill, width: {:pixels, 300})) ==
             {:error, {:missing_dimensions, :fill}}

    assert PipelinePlanner.plan(request(resizing_type: :fill, height: {:pixels, 200})) ==
             {:error, {:missing_dimensions, :fill}}
  end

  test "rejects force with zero dimension" do
    assert PipelinePlanner.plan(
             request(resizing_type: :force, width: {:pixels, 0}, height: {:pixels, 200})
           ) == {:error, {:unsupported_zero_dimension, :force}}

    assert PipelinePlanner.plan(
             request(resizing_type: :force, width: {:pixels, 300}, height: {:pixels, 0})
           ) == {:error, {:unsupported_zero_dimension, :force}}
  end

  defp request(attrs \\ []) do
    struct!(
      ProcessingRequest,
      Keyword.merge(
        [
          signature: "_",
          source_kind: :plain,
          source_path: ["images", "cat.jpg"]
        ],
        attrs
      )
    )
  end
end
