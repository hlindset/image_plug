defmodule ImagePlug.PipelinePlannerTest do
  use ExUnit.Case, async: true

  alias ImagePlug.PipelinePlanner
  alias ImagePlug.ProcessingRequest
  alias ImagePlug.Transform

  test "plans no transforms for a plain request without options" do
    request = %ProcessingRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"]
    }

    assert PipelinePlanner.plan(request) == {:ok, []}
  end

  test "ignores focus when no geometry transform is planned" do
    request = request(focus: {:anchor, :center, :top})

    assert PipelinePlanner.plan(request) == {:ok, []}
  end

  test "plans width-only resize as scale with auto height" do
    request = request(width: {:pixels, 300})

    assert PipelinePlanner.plan(request) ==
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

  test "plans focus before cover transform" do
    request =
      request(
        fit: :cover,
        width: {:pixels, 300},
        height: {:pixels, 200},
        focus: {:anchor, :left, :center}
      )

    assert PipelinePlanner.plan(request) ==
             {:ok,
              [
                {Transform.Focus, %Transform.Focus.FocusParams{type: {:anchor, :left, :center}}},
                {Transform.Cover,
                 %Transform.Cover.CoverParams{
                   type: :dimensions,
                   width: {:pixels, 300},
                   height: {:pixels, 200},
                   constraint: :none
                 }}
              ]}
  end

  test "plans contain without letterbox" do
    request = request(fit: :contain, width: {:pixels, 800})

    assert PipelinePlanner.plan(request) ==
             {:ok,
              [
                {Transform.Contain,
                 %Transform.Contain.ContainParams{
                   type: :dimensions,
                   width: {:pixels, 800},
                   height: :auto,
                   constraint: :none,
                   letterbox: false
                 }}
              ]}
  end

  test "plans inside as contain with letterbox" do
    request = request(fit: :inside, width: {:pixels, 300}, height: {:pixels, 200})

    assert PipelinePlanner.plan(request) ==
             {:ok,
              [
                {Transform.Contain,
                 %Transform.Contain.ContainParams{
                   type: :dimensions,
                   width: {:pixels, 300},
                   height: {:pixels, 200},
                   constraint: :none,
                   letterbox: true
                 }}
              ]}
  end

  test "plans fill as direct scale" do
    request = request(fit: :fill, width: {:pixels, 300}, height: {:pixels, 200})

    assert PipelinePlanner.plan(request) ==
             {:ok,
              [
                {Transform.Scale,
                 %Transform.Scale.ScaleParams{
                   type: :dimensions,
                   width: {:pixels, 300},
                   height: {:pixels, 200}
                 }}
              ]}
  end

  test "appends explicit output format last" do
    request = request(width: {:pixels, 300}, format: :webp)

    assert PipelinePlanner.plan(request) ==
             {:ok,
              [
                {Transform.Scale,
                 %Transform.Scale.ScaleParams{
                   type: :dimensions,
                   width: {:pixels, 300},
                   height: :auto
                 }},
                {Transform.Output, %Transform.Output.OutputParams{format: :webp}}
              ]}
  end

  test "rejects cover without both dimensions" do
    request = request(fit: :cover, width: {:pixels, 300})

    assert PipelinePlanner.plan(request) == {:error, {:missing_dimensions, :cover}}
  end

  test "rejects contain without any dimensions" do
    request = request(fit: :contain)

    assert PipelinePlanner.plan(request) == {:error, {:missing_dimensions, :contain}}
  end

  test "rejects fill without both dimensions" do
    assert PipelinePlanner.plan(request(fit: :fill, width: {:pixels, 300})) ==
             {:error, {:missing_dimensions, :fill}}

    assert PipelinePlanner.plan(request(fit: :fill, height: {:pixels, 200})) ==
             {:error, {:missing_dimensions, :fill}}
  end

  test "rejects inside without both dimensions" do
    assert PipelinePlanner.plan(request(fit: :inside, width: {:pixels, 300})) ==
             {:error, {:missing_dimensions, :inside}}

    assert PipelinePlanner.plan(request(fit: :inside, height: {:pixels, 200})) ==
             {:error, {:missing_dimensions, :inside}}
  end

  defp request(attrs) do
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
