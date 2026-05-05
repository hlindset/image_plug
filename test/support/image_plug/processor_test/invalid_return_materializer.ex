defmodule ImagePlug.ProcessorTest.InvalidReturnMaterializer do
  @moduledoc false

  alias ImagePlug.TransformState

  def materialize(%TransformState{}, _opts), do: {:ok, :not_a_transform_state}
end
