defmodule ImagePipeDemo.Fiddle.DemoStateTest do
  use ExUnit.Case, async: true
  alias ImagePipeDemo.Fiddle.DemoState

  test "default starts on dog.jpg with crop disabled and px sized to the source" do
    s = DemoState.default()
    assert s.source == "images/dog.jpg"
    assert s.crop_enabled == false
    assert s.crop_width_unit == :px
    assert s.crop_width == 5011
    assert s.crop_height == 7516
    assert s.crop_width_percent == 50
    assert s.crop_gravity == "inherit"
  end

  test "put_source resets crop px to the new source dimensions" do
    s = DemoState.default() |> DemoState.put_source("images/beach.jpg")
    assert s.source == "images/beach.jpg"
    assert s.crop_width == 4000
    assert s.crop_height == 2667
  end

  test "put_source ignores unknown sources" do
    s = DemoState.default()
    assert DemoState.put_source(s, "images/nope.jpg") == s
  end
end
