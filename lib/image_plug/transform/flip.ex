defmodule ImagePlug.Transform.Flip do
  @moduledoc """
  Represents a product-neutral operation that flips the current image on one or
  both axes.

  ## Construct When

  Construct `Flip` when parser or planner code has explicit orientation intent
  that mirrors the image horizontally, vertically, or on both axes. The
  operation is product-neutral; dialect parsers translate compatible flip
  syntax into the `:axis` field before this operation is constructed.

  Native planner note: Native URLs are declarative, and when orientation
  requests are present the Native planner emits orientation operations in this
  suborder: auto-orient, rotate, then flip. That suborder is a Native planner
  contract, not a universal requirement of the product-neutral transform
  operation model.

  ## Construction API

  `new/1` accepts a keyword list, map, or existing `%__MODULE__{}` and returns
  `{:ok, operation}` when attrs are valid or `{:error, exception}` when
  validation fails. `new!/1` accepts the same inputs and returns the operation
  or raises `ArgumentError` or `KeyError` for invalid attrs.

  The only accepted attr is `:axis`.

  ## Fields

  Required fields:

  - `axis`: one of `:horizontal`, `:vertical`, or `:both`.

  Unknown fields are rejected. Parser or planner code is responsible for
  translating dialect-specific booleans, tokens, or aliases into one of these
  product-neutral axis values.

  ## Execution Semantics

  `execute/2` flips `ImagePlug.Transform.State.image`, stores the flipped image
  back into state, and resets focus metadata. For `axis: :horizontal` and
  `axis: :vertical`, execution calls `Image.flip/2` with that axis.

  For `axis: :both`, execution performs a horizontal flip followed by a
  vertical flip, then stores the resulting image in state. If any flip fails,
  execution records `{__MODULE__, error}` in the state errors and leaves normal
  error handling to the transform chain.

  ## Decode Planning Metadata

  `metadata/1` returns `%{access: :random}`. Flipping is not treated as safe for
  optimized sequential source decoding because the transform may need the full
  decoded image to remap pixels.

  ## Cache Material

  The `ImagePlug.Transform.Material` implementation emits this exact keyword
  shape:

      [
        op: :flip,
        axis: operation.axis
      ]

  ## Examples

      {:ok, flip} = ImagePlug.Transform.Flip.new(axis: :horizontal)

      flip = ImagePlug.Transform.Flip.new!(axis: :both)
  """

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State

  alias ImagePlug.Transform.State

  defstruct [:axis]

  @type t :: %__MODULE__{axis: :horizontal | :vertical | :both}

  @impl ImagePlug.Transform
  def new(attrs) do
    {:ok, new!(attrs)}
  rescue
    exception in [ArgumentError, KeyError] ->
      {:error, exception}
  end

  @impl ImagePlug.Transform
  def new!(%__MODULE__{} = operation) do
    operation
    |> Map.from_struct()
    |> validate_attrs!()

    operation
  end

  def new!(attrs) when is_list(attrs) or is_map(attrs) do
    attrs
    |> validate_attrs!()
    |> then(&struct!(__MODULE__, &1))
  end

  @impl ImagePlug.Transform
  def name(%__MODULE__{}), do: :flip

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{}), do: %{access: :random}

  @impl ImagePlug.Transform
  def execute(%__MODULE__{axis: :both}, %State{} = state) do
    with {:ok, image} <- Image.flip(state.image, :horizontal),
         {:ok, image} <- Image.flip(image, :vertical) do
      state |> set_image(image) |> reset_focus()
    else
      {:error, error} -> add_error(state, {__MODULE__, error})
    end
  end

  def execute(%__MODULE__{axis: axis}, %State{} = state) do
    case Image.flip(state.image, axis) do
      {:ok, image} -> state |> set_image(image) |> reset_focus()
      {:error, error} -> add_error(state, {__MODULE__, error})
    end
  end

  defp validate_attrs!(attrs) do
    attrs = Map.new(attrs)
    validate_keys!(attrs, [:axis])
    validate_axis!(Map.fetch!(attrs, :axis))
    attrs
  end

  defp validate_keys!(attrs, allowed_keys) do
    unknown_keys = Map.keys(attrs) -- allowed_keys

    if unknown_keys != [] do
      keys = unknown_keys |> Enum.sort_by(&inspect/1) |> Enum.map_join(", ", &inspect/1)
      raise ArgumentError, "unknown flip option(s): #{keys}"
    end
  end

  defp validate_axis!(axis) when axis in [:horizontal, :vertical, :both], do: :ok

  defp validate_axis!(axis),
    do: raise(ArgumentError, "invalid flip axis: #{inspect(axis)}")
end
