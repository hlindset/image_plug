defmodule ImagePlug.Transform.AdaptiveResize do
  @moduledoc false

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.Geometry

  alias ImagePlug.Transform.Geometry.DimensionRule
  alias ImagePlug.Transform.Resize
  alias ImagePlug.Transform.State

  defstruct [:rule]

  @type t :: %__MODULE__{rule: DimensionRule.t()}

  @impl ImagePlug.Transform
  def new(attrs) do
    {:ok, new!(attrs)}
  rescue
    exception in [ArgumentError, KeyError] ->
      {:error, exception}
  end

  @impl ImagePlug.Transform
  def new!(%__MODULE__{} = operation), do: operation

  def new!(attrs) when is_list(attrs) or is_map(attrs) do
    attrs
    |> validate_attrs!()
    |> then(&struct!(__MODULE__, &1))
  end

  @impl ImagePlug.Transform
  def name(%__MODULE__{}), do: :adaptive_resize

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{}), do: %{access: :random}

  @impl ImagePlug.Transform
  def execute(%__MODULE__{rule: %DimensionRule{} = rule}, %State{} = state) do
    rule
    |> Map.put(:mode, adaptive_mode(state, rule))
    |> then(&%Resize{rule: &1})
    |> Resize.execute(state)
  end

  defp adaptive_mode(%State{} = state, %DimensionRule{} = rule) do
    case requested_dimensions(state, rule) do
      {:ok, %{width: width, height: height}} ->
        if same_orientation?(image_width(state), image_height(state), width, height) do
          :fill
        else
          :fit
        end

      :error ->
        :fit
    end
  end

  defp requested_dimensions(_state, %DimensionRule{width: :auto}), do: :error
  defp requested_dimensions(_state, %DimensionRule{height: :auto}), do: :error
  defp requested_dimensions(_state, %DimensionRule{width: nil}), do: :error
  defp requested_dimensions(_state, %DimensionRule{height: nil}), do: :error

  defp requested_dimensions(%State{} = state, %DimensionRule{} = rule) do
    {:ok,
     %{
       width: to_pixels(image_width(state), rule.width),
       height: to_pixels(image_height(state), rule.height)
     }}
  rescue
    ArgumentError -> :error
  end

  defp same_orientation?(source_width, source_height, target_width, target_height) do
    orientation(source_width, source_height) == orientation(target_width, target_height)
  end

  defp orientation(width, height) when width > height, do: :landscape
  defp orientation(width, height) when width < height, do: :portrait
  defp orientation(_width, _height), do: :square

  defp validate_attrs!(attrs) do
    attrs = Map.new(attrs)
    validate_keys!(attrs, [:rule])
    validate_rule!(Map.fetch!(attrs, :rule))
    attrs
  end

  defp validate_keys!(attrs, allowed_keys) do
    unknown_keys = Map.keys(attrs) -- allowed_keys

    if unknown_keys != [] do
      keys = unknown_keys |> Enum.sort_by(&inspect/1) |> Enum.map_join(", ", &inspect/1)
      raise ArgumentError, "unknown adaptive resize option(s): #{keys}"
    end
  end

  defp validate_rule!(%DimensionRule{}), do: :ok

  defp validate_rule!(rule),
    do: raise(ArgumentError, "invalid adaptive resize rule: #{inspect(rule)}")
end
