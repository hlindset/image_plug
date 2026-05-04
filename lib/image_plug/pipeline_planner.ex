defmodule ImagePlug.PipelinePlanner do
  @moduledoc """
  Converts native processing requests into executable transform chains.
  """

  alias ImagePlug.ProcessingRequest
  alias ImagePlug.Transform
  alias ImagePlug.TransformChain

  @default_gravity {:anchor, :center, :center}
  @supported_resizing_types [:fit, :fill, :fill_down, :force, :auto]
  @supported_output_formats [:webp, :avif, :jpeg, :png]

  @spec plan(ProcessingRequest.t()) :: {:ok, TransformChain.t()} | {:error, term()}
  def plan(%ProcessingRequest{} = request) do
    with :ok <- validate_dimensions(request),
         :ok <- validate_supported_semantics(request),
         {:ok, geometry_chain} <- plan_geometry(request) do
      {:ok, geometry_chain}
    end
  end

  defp validate_dimensions(%ProcessingRequest{width: width, height: height}) do
    with :ok <- validate_dimension(:width, width),
         :ok <- validate_dimension(:height, height) do
      :ok
    end
  end

  defp validate_dimension(_field, nil), do: :ok

  defp validate_dimension(_field, {:pixels, value}) when is_number(value) and value >= 0,
    do: :ok

  defp validate_dimension(field, value), do: {:error, {:invalid_dimension, field, value}}

  defp validate_supported_semantics(%ProcessingRequest{format: :best}),
    do: {:error, {:unsupported_output_format, :best}}

  defp validate_supported_semantics(%ProcessingRequest{format: format})
       when not is_nil(format) and format not in @supported_output_formats,
       do: {:error, {:invalid_output_format, format}}

  defp validate_supported_semantics(%ProcessingRequest{gravity: :sm}),
    do: {:error, {:unsupported_gravity, :sm}}

  defp validate_supported_semantics(%ProcessingRequest{resizing_type: resizing_type})
       when resizing_type in [:auto, :fill_down],
       do: {:error, {:unsupported_resizing_type, resizing_type}}

  defp validate_supported_semantics(%ProcessingRequest{resizing_type: resizing_type})
       when resizing_type not in @supported_resizing_types,
       do: {:error, {:invalid_resizing_type, resizing_type}}

  defp validate_supported_semantics(%ProcessingRequest{enlarge: enlarge})
       when enlarge not in [true, false],
       do: {:error, {:invalid_enlarge, enlarge}}

  defp validate_supported_semantics(%ProcessingRequest{gravity: gravity} = request) do
    if valid_gravity?(gravity) do
      validate_extend_semantics(request)
    else
      {:error, {:invalid_gravity, gravity}}
    end
  end

  defp validate_extend_semantics(%ProcessingRequest{extend: true}),
    do: {:error, {:unsupported_extend, true}}

  defp validate_extend_semantics(%ProcessingRequest{extend_gravity: gravity})
       when not is_nil(gravity),
       do: {:error, {:unsupported_extend_gravity, gravity}}

  defp validate_extend_semantics(%ProcessingRequest{extend_x_offset: offset})
       when not is_nil(offset),
       do: {:error, {:unsupported_extend_offset, offset}}

  defp validate_extend_semantics(%ProcessingRequest{extend_y_offset: offset})
       when not is_nil(offset),
       do: {:error, {:unsupported_extend_offset, offset}}

  defp validate_extend_semantics(%ProcessingRequest{
         gravity_x_offset: x_offset,
         gravity_y_offset: y_offset
       })
       when x_offset != 0.0 or y_offset != 0.0,
       do: {:error, {:unsupported_gravity_offset, {x_offset, y_offset}}}

  defp validate_extend_semantics(%ProcessingRequest{}), do: :ok

  defp plan_geometry(%ProcessingRequest{resizing_type: :force, width: {:pixels, 0}}),
    do: {:error, {:unsupported_zero_dimension, :force}}

  defp plan_geometry(%ProcessingRequest{resizing_type: :force, height: {:pixels, 0}}),
    do: {:error, {:unsupported_zero_dimension, :force}}

  defp plan_geometry(%ProcessingRequest{resizing_type: :fill, width: nil, height: nil}),
    do: missing_dimensions(:fill)

  defp plan_geometry(%ProcessingRequest{width: nil, height: nil}), do: {:ok, []}

  defp plan_geometry(%ProcessingRequest{width: {:pixels, 0}, height: {:pixels, 0}}), do: {:ok, []}

  defp plan_geometry(
         %ProcessingRequest{resizing_type: :fit, width: width, height: height} = request
       ) do
    case {normalize_dimension(width), normalize_dimension(height)} do
      {:auto, :auto} -> {:ok, []}
      {planned_width, planned_height} -> {:ok, [contain(planned_width, planned_height, request)]}
    end
  end

  defp plan_geometry(%ProcessingRequest{resizing_type: :fill, width: nil}),
    do: missing_dimensions(:fill)

  defp plan_geometry(%ProcessingRequest{resizing_type: :fill, height: nil}),
    do: missing_dimensions(:fill)

  defp plan_geometry(%ProcessingRequest{resizing_type: :fill} = request) do
    cover =
      cover(normalize_dimension(request.width), normalize_dimension(request.height), request)

    {:ok, maybe_prepend_focus([cover], request.gravity)}
  end

  defp plan_geometry(%ProcessingRequest{resizing_type: :force, width: width, height: height}) do
    {:ok, [scale(width || :auto, height || :auto)]}
  end

  defp plan_geometry(%ProcessingRequest{resizing_type: resizing_type}),
    do: {:error, {:unsupported_resizing_type, resizing_type}}

  defp scale(width, height) do
    {Transform.Scale,
     %Transform.Scale.ScaleParams{
       type: :dimensions,
       width: width,
       height: height
     }}
  end

  defp contain(width, height, %ProcessingRequest{} = request) do
    {Transform.Contain,
     %Transform.Contain.ContainParams{
       type: :dimensions,
       width: width,
       height: height,
       constraint: contain_constraint(request.enlarge),
       letterbox: false
     }}
  end

  defp cover(width, height, %ProcessingRequest{} = request) do
    {Transform.Cover,
     %Transform.Cover.CoverParams{
       type: :dimensions,
       width: width,
       height: height,
       constraint: cover_constraint(request.enlarge)
     }}
  end

  defp maybe_prepend_focus(chain, @default_gravity), do: chain

  defp maybe_prepend_focus([{Transform.Cover, _params} | _rest] = chain, gravity) do
    [{Transform.Focus, %Transform.Focus.FocusParams{type: focus_type(gravity)}} | chain]
  end

  defp maybe_prepend_focus(chain, _gravity), do: chain

  defp valid_gravity?({:fp, x, y}) do
    is_number(x) and is_number(y) and x >= 0.0 and x <= 1.0 and y >= 0.0 and y <= 1.0
  end

  defp valid_gravity?({:anchor, x, y}) do
    x in [:left, :center, :right] and y in [:top, :center, :bottom]
  end

  defp valid_gravity?(_gravity), do: false

  defp focus_type({:fp, x, y}), do: {:coordinate, {:percent, x * 100.0}, {:percent, y * 100.0}}
  defp focus_type({:anchor, _x, _y} = gravity), do: gravity

  defp normalize_dimension({:pixels, 0}), do: :auto
  defp normalize_dimension(nil), do: :auto
  defp normalize_dimension(dimension), do: dimension

  defp cover_constraint(true), do: :none
  defp cover_constraint(false), do: :max

  defp contain_constraint(true), do: :regular
  defp contain_constraint(false), do: :max

  defp missing_dimensions(resizing_type), do: {:error, {:missing_dimensions, resizing_type}}
end
