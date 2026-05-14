defmodule ImagePlug.Transform.KeyData do
  @moduledoc """
  Canonical keyword data helpers for transform cache keys.

  Tagged geometry values are already-normalized semantic values. Plan
  constructors normalize DPR before operations reach cache key construction, so
  key data never depends on raw IEEE float representation.
  """

  alias ImagePlug.Plan.Color
  alias ImagePlug.Plan.Operation.Canvas
  alias ImagePlug.Plan.Operation.CropGuided
  alias ImagePlug.Plan.Operation.CropRegion
  alias ImagePlug.Plan.Operation.FlattenBackground
  alias ImagePlug.Plan.Operation.Padding
  alias ImagePlug.Plan.Operation.Resize
  alias ImagePlug.Transform.Operation.AutoOrient
  alias ImagePlug.Transform.Operation.Flip
  alias ImagePlug.Transform.Operation.Rotate

  @crop_anchor_guides [
    :center,
    :top_left,
    :top,
    :top_right,
    :left,
    :right,
    :bottom_left,
    :bottom,
    :bottom_right
  ]

  @type geometry_value ::
          :auto
          | :full_axis
          | {:px, pos_integer()}
          | {:ratio, non_neg_integer(), pos_integer()}

  @type ratio_data :: [
          {:unit, :ratio}
          | {:numerator, non_neg_integer()}
          | {:denominator, pos_integer()}
        ]

  @spec data(
          geometry_value()
          | Canvas.t()
          | CropGuided.t()
          | CropRegion.t()
          | FlattenBackground.t()
          | Padding.t()
          | Resize.t()
          | AutoOrient.t()
          | Rotate.t()
          | Flip.t()
        ) :: keyword()
  def data(%Canvas{} = operation) do
    [
      op: :canvas,
      width: data(operation.width),
      height: data(operation.height),
      placement: guide_data(operation.placement),
      fill: fill_data(operation.fill),
      overflow: operation.overflow,
      x_offset: operation.x_offset,
      y_offset: operation.y_offset
    ]
  end

  def data(%CropGuided{} = operation) do
    [
      op: :crop_guided,
      width: data(operation.width),
      height: data(operation.height),
      guide: guide_data(operation.guide),
      x_offset: operation.x_offset,
      y_offset: operation.y_offset
    ]
  end

  def data(%CropRegion{} = operation) do
    [
      op: :crop_region,
      x: data(operation.x),
      y: data(operation.y),
      width: data(operation.width),
      height: data(operation.height)
    ]
  end

  def data(%Resize{} = operation) do
    [
      op: :resize,
      mode: operation.mode,
      width: data(operation.width),
      height: data(operation.height),
      dpr: data(operation.dpr),
      enlargement: operation.enlargement,
      guide: guide_data(operation.guide),
      x_offset: operation.x_offset,
      y_offset: operation.y_offset,
      min_width: optional_data(operation.min_width),
      min_height: optional_data(operation.min_height),
      zoom_x: operation.zoom_x,
      zoom_y: operation.zoom_y
    ]
    |> resize_rule_data(operation)
  end

  def data(%Padding{} = operation) do
    [
      op: :padding,
      top: data(operation.top),
      right: data(operation.right),
      bottom: data(operation.bottom),
      left: data(operation.left),
      pixel_ratio: data(operation.pixel_ratio),
      fill: fill_data(operation.fill)
    ]
  end

  def data(%FlattenBackground{} = operation) do
    [op: :flatten_background, color: Color.key_data(operation.color)]
  end

  def data(%AutoOrient{}), do: [op: :auto_orient]
  def data(%Rotate{} = operation), do: [op: :rotate, angle: operation.angle]
  def data(%Flip{} = operation), do: [op: :flip, axis: operation.axis]

  def data(:auto), do: [unit: :auto]
  def data(:full_axis), do: [unit: :full_axis]

  def data({:px, value}) when is_integer(value) and value >= 0,
    do: [unit: :logical_px, value: value]

  def data({:ratio, numerator, denominator})
      when is_integer(numerator) and is_integer(denominator) and numerator >= 0 and
             denominator > 0 do
    ratio_data(numerator, denominator)
  end

  def data({:effective, fallback, mode}) when mode in [:resize, :canvas_preserving] do
    [
      unit: :effective_resize_pixel_ratio,
      fallback: data(fallback),
      mode: mode
    ]
  end

  defp optional_data(nil), do: nil
  defp optional_data(value), do: data(value)

  defp fill_data(:transparent), do: :transparent
  defp fill_data({:solid, %Color{} = color}), do: [type: :solid, color: Color.key_data(color)]

  defp guide_data(:center), do: :center

  defp guide_data(guide) when guide in @crop_anchor_guides, do: guide

  defp guide_data({:anchor, x, y}), do: [type: :anchor, x: x, y: y]

  defp guide_data({:focal, x, y}), do: [type: :focal, x: data(x), y: data(y)]

  defp resize_rule_data(data, %Resize{mode: :auto}),
    do: data ++ [rule: :imgproxy_orientation_match_v1]

  defp resize_rule_data(data, %Resize{}), do: data

  defp ratio_data(numerator, denominator) do
    gcd = Integer.gcd(numerator, denominator)

    [
      unit: :ratio,
      numerator: div(numerator, gcd),
      denominator: div(denominator, gcd)
    ]
  end
end
