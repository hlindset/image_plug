defmodule ImagePipe.Transform.ResizeRelativeResolutionPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Transform.Operation.Resize

  property "percent width resolves proportionally against the running width" do
    check all running <- integer(1..6000),
              percent <- integer(1..400) do
      op = %Resize{mode: :fit, width: {:percent, percent}, height: :auto, enlarge: true}
      result = Resize.resolve_dimensions(op, source_width: running, source_height: running)

      # Exact: mirror the production computation order (Geometry.to_pixels does
      # `round(percent / 100 * length)`), then the sub-pixel floor to 1. Writing
      # the operands in the SAME order avoids float-associativity drift while
      # keeping the assertion tight (delta 0).
      assert result.intermediate_width == max(1, round(percent / 100 * running))
    end
  end
end
