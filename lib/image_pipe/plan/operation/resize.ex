defmodule ImagePipe.Plan.Operation.Resize do
  @moduledoc """
  Product-neutral semantic resize intent.
  """

  @enforce_keys [:mode, :width, :height, :dpr, :enlargement, :guide]
  defstruct @enforce_keys ++
              [
                x_offset: {:pixels, 0.0},
                y_offset: {:pixels, 0.0},
                min_width: nil,
                min_height: nil,
                zoom_x: 1.0,
                zoom_y: 1.0
              ]

  @type mode :: :fit | :cover | :stretch | :auto
  @type dimension :: :auto | {:px, pos_integer()}
  @type dpr :: {:ratio, pos_integer(), pos_integer()}
  @type enlargement :: :allow | :deny
  @type anchor :: :left | :center | :right | :top | :bottom
  @type guide ::
          :center
          | {:anchor, anchor(), anchor()}
          | {:focal, ratio(), ratio()}
          | :smart
          | {:smart, :face_assist}
          | {:detect, :all}
          | {:detect, nonempty_list(String.t())}
  @type ratio :: {:ratio, non_neg_integer(), pos_integer()}
  @type offset :: number() | {:pixels | :scale, number()}

  @type t :: %__MODULE__{
          mode: mode(),
          width: dimension(),
          height: dimension(),
          dpr: dpr(),
          enlargement: enlargement(),
          guide: guide(),
          x_offset: offset(),
          y_offset: offset(),
          min_width: dimension() | nil,
          min_height: dimension() | nil,
          zoom_x: pos_integer() | float(),
          zoom_y: pos_integer() | float()
        }
end
