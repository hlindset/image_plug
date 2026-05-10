defmodule ImagePlug.Transform.DecodePlanner do
  @moduledoc """
  Chooses image decode access from transform operation metadata.

  Decode planning interprets each operation's product-neutral metadata and
  reduces the chain to either sequential or random image access. It is
  intentionally conservative for valid metadata: empty chains, missing access
  metadata, and invalid access values all fall back to random access.
  """

  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Transform

  @type access_requirement() :: :sequential | :random | :neutral

  @spec open_options(ImagePlug.Transform.Chain.t()) :: keyword()
  def open_options(chain) when is_list(chain) do
    [access: access(chain), fail_on: :error]
  end

  @spec access(ImagePlug.Transform.Chain.t()) :: :sequential | :random
  def access([]), do: :random

  def access(chain) when is_list(chain) do
    chain
    |> Enum.map(&access_requirement/1)
    |> resolve_access()
  end

  defp access_requirement(operation) do
    operation
    |> safe_metadata()
    |> access_from_metadata()
  end

  defp safe_metadata(operation) do
    if Operation.semantic?(operation) do
      semantic_metadata(operation)
    else
      Transform.metadata(operation)
    end
  rescue
    _exception in [ArgumentError, FunctionClauseError, RuntimeError, UndefinedFunctionError] ->
      %{access: :random}
  catch
    :throw, _reason -> %{access: :random}
  end

  defp access_from_metadata(%{access: access}), do: normalize_access(access)
  defp access_from_metadata(_metadata), do: :random

  defp normalize_access(access) when access in [:sequential, :random, :neutral], do: access
  defp normalize_access(_access), do: :random

  defp semantic_metadata(%Operation.ResizeFit{} = operation), do: resize_metadata(operation)
  defp semantic_metadata(%Operation.ResizeStretch{} = operation), do: resize_metadata(operation)
  defp semantic_metadata(%Operation.AutoOrient{}), do: %{access: :sequential}
  defp semantic_metadata(%Operation.ResizeCover{}), do: %{access: :random}
  defp semantic_metadata(%Operation.ResizeAuto{}), do: %{access: :random}
  defp semantic_metadata(%Operation.CropGuided{}), do: %{access: :random}
  defp semantic_metadata(%Operation.CropRegion{}), do: %{access: :random}
  defp semantic_metadata(%Operation.Canvas{}), do: %{access: :random}
  defp semantic_metadata(%Operation.Rotate{}), do: %{access: :random}
  defp semantic_metadata(%Operation.Flip{}), do: %{access: :random}
  defp semantic_metadata(_operation), do: %{access: :random}

  defp resize_metadata(%{size: size, min_width: nil, min_height: nil}) do
    if requested_dimension?(size.width) or requested_dimension?(size.height) do
      %{access: :sequential}
    else
      %{access: :random}
    end
  end

  defp resize_metadata(_operation), do: %{access: :random}

  defp requested_dimension?(%Dimension{unit: :logical_px, value: value})
       when is_integer(value) and value > 0,
       do: true

  defp requested_dimension?(_dimension), do: false

  defp resolve_access(requirements) do
    cond do
      Enum.any?(requirements, &(&1 == :random)) -> :random
      Enum.any?(requirements, &(&1 == :sequential)) -> :sequential
      true -> :random
    end
  end
end
