defmodule ImagePlug.ProcessingRequestTest do
  use ExUnit.Case, async: true

  alias ImagePlug.ProcessingRequest

  test "defaults to imgproxy-shaped plain request intent" do
    request = %ProcessingRequest{}

    assert request.signature == nil
    assert request.source_kind == nil
    assert request.source_path == []
    assert request.width == nil
    assert request.height == nil
    assert request.resizing_type == :fit
    assert request.enlarge == false
    assert request.extend == false
    assert request.extend_gravity == nil
    assert request.extend_x_offset == nil
    assert request.extend_y_offset == nil
    assert request.gravity == {:anchor, :center, :center}
    assert request.gravity_x_offset == 0.0
    assert request.gravity_y_offset == 0.0
    assert request.format == nil
  end

  test "represents unsupported but parsed semantic values distinctly" do
    request = %ProcessingRequest{
      resizing_type: :fill_down,
      gravity: :sm,
      format: :best
    }

    assert request.resizing_type == :fill_down
    assert request.gravity == :sm
    assert request.format == :best
  end
end
