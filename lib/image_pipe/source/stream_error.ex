defmodule ImagePipe.Source.StreamError do
  @moduledoc false

  defexception [:reason]

  @type t :: %__MODULE__{reason: atom()}

  def message(%__MODULE__{reason: reason}), do: "source stream failed: #{reason}"
end
