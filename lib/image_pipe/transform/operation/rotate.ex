defmodule ImagePipe.Transform.Operation.Rotate do
  @moduledoc """
  Represents an executable operation that rotates the current image by a
  right-angle amount.

  ## Construct When

  Transform Plan execution creates this executable primitive from semantic
  `ImagePipe.Plan.Operation.Rotate` intent. Parser modules should construct
  semantic `ImagePipe.Plan.Operation.*` structs through Plan constructors.

  ## Fields

  Required fields:

  - `angle`: one of `0`, `90`, `180`, or `270`.

  The operation does not normalize arbitrary degree values; semantic planning
  must translate compatible syntax into one of the accepted right-angle values
  before Plan execution.

  ## Execution Semantics

  `execute/2` with `angle: 0` returns the existing
  `ImagePipe.Transform.State` unchanged.

  For `90`, `180`, and `270`, execution calls the exact `vips_rot`
  (`Vix.Vips.Operation.rot/2`) for `ImagePipe.Transform.State.image` and stores
  the rotated image back into state. If rotation fails, execution returns
  `{:error, {__MODULE__, error}}`.

  ## Examples

      rotate = %ImagePipe.Transform.Operation.Rotate{angle: 90}
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State
  alias Vix.Vips.Operation

  defstruct [:angle]

  @type t :: %__MODULE__{angle: 0 | 90 | 180 | 270}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :rotate

  @impl ImagePipe.Transform
  def requires_materialization?(%__MODULE__{}), do: true

  @impl ImagePipe.Transform
  def execute(%__MODULE__{angle: 0}, %State{} = state), do: {:ok, state}

  def execute(%__MODULE__{angle: angle}, %State{} = state) do
    case Operation.rot(state.image, vips_angle(angle)) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  # Call `Vix.Vips.Operation.rot/2` (libvips' exact right-angle `vips_rot`)
  # directly: the `image` library has no public exact-rotate facade, and its
  # `Image.rotate/2` is the arbitrary-angle affine rotate (`vips_rotate`), which
  # at a 90° multiple maps the content ~1px off the output canvas and leaves a 1px
  # strip filled with its `:background` colour (black by default) — the #211 seam.
  # imgproxy rotates with `vips_rot` too, so this is the parity-correct primitive.
  defp vips_angle(90), do: :VIPS_ANGLE_D90
  defp vips_angle(180), do: :VIPS_ANGLE_D180
  defp vips_angle(270), do: :VIPS_ANGLE_D270
end
