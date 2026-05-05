defmodule ImagePlug.ProcessorTest.InvalidReturnMaterializer do
  @moduledoc false

  alias ImagePlug.Transform.State

  def materialize(%State{}, _opts), do: {:ok, :not_a_transform_state}
end
