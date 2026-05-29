defmodule ImagePipeDemo.Fiddle.ProcessingPathTest do
  use ExUnit.Case, async: true
  alias ImagePipeDemo.Fiddle.{DemoState, ProcessingPath}

  test "no-geometry: crop disabled yields /_/plain/<source>" do
    assert ProcessingPath.build(DemoState.default()) == "/_/plain/images/dog.jpg"
  end

  test "crop in px omits inherit gravity" do
    s = %{DemoState.default() | crop_enabled: true, crop_width: 800, crop_height: 600}
    assert ProcessingPath.build(s) == "/_/c:800:600/plain/images/dog.jpg"
  end

  test "crop in percent encodes value/100" do
    s = %{
      DemoState.default()
      | crop_enabled: true,
        crop_width_unit: :percent,
        crop_width_percent: 50,
        crop_height_unit: :percent,
        crop_height_percent: 25
    }

    assert ProcessingPath.build(s) == "/_/c:0.5:0.25/plain/images/dog.jpg"
  end

  test "crop full encodes 0" do
    s = %{
      DemoState.default()
      | crop_enabled: true,
        crop_width_unit: :full,
        crop_height_unit: :full
    }

    assert ProcessingPath.build(s) == "/_/c:0:0/plain/images/dog.jpg"
  end

  test "non-inherit crop gravity is appended" do
    s = %{
      DemoState.default()
      | crop_enabled: true,
        crop_width: 800,
        crop_height: 600,
        crop_gravity: "no"
    }

    assert ProcessingPath.build(s) == "/_/c:800:600:no/plain/images/dog.jpg"
  end

  test "px is clamped to >= 1" do
    s = %{DemoState.default() | crop_enabled: true, crop_width: 0, crop_height: 600}
    assert ProcessingPath.build(s) == "/_/c:1:600/plain/images/dog.jpg"
  end
end
