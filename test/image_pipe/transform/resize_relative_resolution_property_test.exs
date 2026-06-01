defmodule ImagePipe.Transform.ResizeRelativeResolutionPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Transform.Operation.Resize

  property "percent width resolves proportionally against the running width" do
    check all running <- integer(1..6000),
              percent <- integer(1..400) do
      op = %Resize{mode: :fit, width: {:percent, percent}, height: :auto, enlarge: true}
      result = Resize.resolve_dimensions(op, source_width: running, source_height: running)

      # The resolved width tracks `running * percent / 100` to within one pixel.
      # We allow ±1 because resolution rounds (and floors a sub-pixel result to 1),
      # and float associativity makes `percent/100*running` differ from
      # `running*percent/100` at exact half-pixel boundaries.
      assert_in_delta result.intermediate_width, running * percent / 100, 1.0
      assert result.intermediate_width >= 1
    end
  end
end
