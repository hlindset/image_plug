defmodule ImagePlug.ProcessingRequestTest do
  use ExUnit.Case, async: true

  alias ImagePlug.ProcessingRequest

  test "has native request defaults" do
    request = %ProcessingRequest{
      signature: "_",
      source_kind: :plain,
      source_path: ["images", "cat.jpg"]
    }

    assert request.signature == "_"
    assert request.source_kind == :plain
    assert request.source_path == ["images", "cat.jpg"]
    assert request.width == nil
    assert request.height == nil
    assert request.fit == nil
    assert request.focus == {:anchor, :center, :center}
    assert request.format == :auto
  end
end
