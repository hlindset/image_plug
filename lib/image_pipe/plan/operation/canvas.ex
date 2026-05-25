defmodule ImagePipe.Plan.Operation.Canvas do
  @moduledoc """
  Semantic operation that places the current image onto a canvas.
  """

  @enforce_keys [:width, :height, :placement, :fill, :overflow]
  defstruct @enforce_keys ++ [x_offset: 0.0, y_offset: 0.0]

  @type ratio :: {:ratio, non_neg_integer(), pos_integer()}
  @type dimension :: :auto | {:px, pos_integer()} | ratio()
  @type fill :: :transparent | {:solid, ImagePipe.Plan.Color.t()}

  @type t :: %__MODULE__{
          width: dimension(),
          height: dimension(),
          placement:
            :center
            | :top_left
            | :top
            | :top_right
            | :left
            | :right
            | :bottom_left
            | :bottom
            | :bottom_right
            | {:focal, ratio(), ratio()},
          fill: fill(),
          overflow: :reject,
          x_offset: number(),
          y_offset: number()
        }
end
