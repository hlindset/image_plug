defmodule ImagePlug.Runtime.ProcessorTest.InvalidReturnMaterializer do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePlug.Transform]

  alias ImagePlug.Transform.State

  def materialize(%State{}, _opts), do: {:ok, :not_a_transform_state}
end
