defmodule ImagePlug.Transform.AutoOrient do
  @moduledoc """
  Represents a product-neutral operation that applies embedded image
  orientation metadata to the current image pixels.

  ## Construct When

  Construct `AutoOrient` when parser or planner code has orientation intent
  that should honor source metadata such as EXIF orientation. The operation
  itself is not tied to any URL dialect; dialect parsers translate their own
  orientation syntax into this operation when the requested semantics match.

  Native planner note: Native URLs are declarative, and when orientation
  requests are present the Native planner emits orientation operations in this
  suborder: auto-orient, rotate, then flip. That suborder is a Native planner
  contract, not a universal requirement of the product-neutral transform
  operation model.

  ## Construction API

  `new/1` accepts an empty keyword list, an empty map, or an existing
  `%__MODULE__{}` and returns `{:ok, operation}`. `new!/1` accepts the same
  inputs and returns the operation.

  Non-empty attrs are invalid. `new/1` returns `{:error, exception}` for
  invalid attrs, while `new!/1` raises `ArgumentError`.

  ## Fields

  `AutoOrient` has no fields. The source image metadata and pixel data are read
  from `ImagePlug.Transform.State` during execution.

  ## Execution Semantics

  `execute/2` calls `Image.autorotate/1` for
  `ImagePlug.Transform.State.image`, stores the oriented image back into state,
  and resets focus metadata. The image library may return flags describing the
  orientation work; this operation discards those flags because the transform
  state stores the resulting image, not parser-specific orientation metadata.

  If autorotation fails, execution records `{__MODULE__, error}` in the state
  errors and leaves normal error handling to the transform chain.

  ## Decode Planning Metadata

  `metadata/1` returns `%{access: :sequential}`. Auto-orientation can be used
  with optimized sequential source access because it does not require choosing
  an arbitrary crop rectangle, result crop, canvas expansion, or other
  random-access geometry during decode planning.

  ## Cache Material

  The `ImagePlug.Transform.Material` implementation emits this exact keyword
  shape:

      [
        op: :auto_orient
      ]

  ## Examples

      {:ok, auto_orient} = ImagePlug.Transform.AutoOrient.new([])

      auto_orient = ImagePlug.Transform.AutoOrient.new!(%{})
  """

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State

  alias ImagePlug.Transform.State

  defstruct []

  @type t :: %__MODULE__{}

  @impl ImagePlug.Transform
  def new(attrs) do
    {:ok, new!(attrs)}
  rescue
    exception in [ArgumentError, KeyError] ->
      {:error, exception}
  end

  @impl ImagePlug.Transform
  def new!(attrs) when attrs in [%{}, []], do: %__MODULE__{}

  def new!(attrs), do: raise(ArgumentError, "invalid auto-orient options: #{inspect(attrs)}")

  @impl ImagePlug.Transform
  def name(%__MODULE__{}), do: :auto_orient

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{}), do: %{access: :sequential}

  @impl ImagePlug.Transform
  def execute(%__MODULE__{}, %State{} = state) do
    case Image.autorotate(state.image) do
      {:ok, {image, _flags}} -> state |> set_image(image) |> reset_focus()
      {:error, error} -> add_error(state, {__MODULE__, error})
    end
  end
end
