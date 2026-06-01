defmodule ImagePipe.Transform.ResizeRelativeResolutionPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Transform.Operation.Resize

  property "percent width resolves to round(running_width * percent / 100)" do
    check all running <- integer(1..6000),
              percent <- integer(1..400) do
      op = %Resize{mode: :fit, width: {:percent, percent}, height: :auto, enlarge: true}
      result = Resize.resolve_dimensions(op, source_width: running, source_height: running)

      assert result.intermediate_width == max(1, round(running * percent / 100))
    end
  end
end
