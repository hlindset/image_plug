defmodule ImagePlug.Plan.Policy do
  @moduledoc false

  defstruct expires: 0

  @type t :: %__MODULE__{expires: non_neg_integer()}

  @spec expired?(t(), integer()) :: boolean()
  def expired?(%__MODULE__{expires: expires}, now) when is_integer(expires) and is_integer(now) do
    expires > 0 and expires < now
  end
end
