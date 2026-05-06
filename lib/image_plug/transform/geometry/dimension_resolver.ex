defmodule ImagePlug.Transform.Geometry.DimensionResolver do
  @moduledoc """
  Resolves dimension rules against runtime source image metadata.

  The resolver turns product-neutral requested dimensions into concrete target
  and intermediate dimensions. It accounts for auto dimensions, minimum
  dimensions, zoom factors, device-pixel-ratio scaling, source vector status,
  and whether raster output may enlarge beyond the source image.
  """

  alias ImagePlug.Transform.Geometry.DimensionRule

  @type result() :: %{
          requested_width: pos_integer() | :auto,
          requested_height: pos_integer() | :auto,
          target_width: pos_integer() | :auto,
          target_height: pos_integer() | :auto,
          intermediate_width: pos_integer(),
          intermediate_height: pos_integer(),
          effective_dpr: float()
        }

  @spec resolve(DimensionRule.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def resolve(%DimensionRule{} = rule, opts) when is_list(opts) do
    with {:ok, source} <- source_dimensions(opts),
         {:ok, rule} <- normalize_rule(rule),
         {:ok, base} <- resolve_base_dimensions(rule, source) do
      effective_dpr = effective_dpr(rule, base, source, opts)
      enlarge = effective_enlarge(rule)
      requested = apply_dpr(base, effective_dpr)
      min_dimensions = resolve_min_dimensions(rule, source, effective_dpr)
      target = target_dimensions(rule.mode, requested, min_dimensions, source, enlarge)

      intermediate =
        intermediate_dimensions(rule.mode, requested, min_dimensions, source, enlarge)

      {:ok,
       %{
         requested_width: requested.width,
         requested_height: requested.height,
         target_width: target.width,
         target_height: target.height,
         intermediate_width: intermediate.width,
         intermediate_height: intermediate.height,
         effective_dpr: effective_dpr
       }}
    end
  end

  def resolve(%DimensionRule{}, opts), do: {:error, {:invalid_dimension_resolver_options, opts}}
  def resolve(rule, _opts), do: {:error, {:invalid_dimension_rule, rule}}

  defp source_dimensions(opts) do
    with {:ok, source_width} <- fetch_positive_integer(opts, :source_width),
         {:ok, source_height} <- fetch_positive_integer(opts, :source_height) do
      {:ok, %{width: source_width, height: source_height}}
    end
  end

  defp fetch_positive_integer(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_number(value) and value > 0 ->
        {:ok, positive_round(value)}

      {:ok, value} ->
        {:error, {:invalid_source_dimension, key, value}}

      :error ->
        {:error, {:missing_source_dimension, key}}
    end
  end

  defp normalize_rule(%DimensionRule{} = rule) do
    with {:ok, mode} <- normalize_mode(rule.mode),
         {:ok, width} <- normalize_bound_dimension(:width, rule.width),
         {:ok, height} <- normalize_bound_dimension(:height, rule.height),
         {:ok, min_width} <- normalize_min_dimension(:min_width, rule.min_width),
         {:ok, min_height} <- normalize_min_dimension(:min_height, rule.min_height),
         {:ok, zoom_x} <- normalize_factor(:zoom_x, rule.zoom_x, 1.0),
         {:ok, zoom_y} <- normalize_factor(:zoom_y, rule.zoom_y, 1.0),
         {:ok, dpr} <- normalize_factor(:dpr, rule.dpr, 1.0),
         :ok <- validate_enlarge(rule.enlarge) do
      {:ok,
       %DimensionRule{
         rule
         | mode: mode,
           width: width,
           height: height,
           min_width: min_width,
           min_height: min_height,
           zoom_x: zoom_x,
           zoom_y: zoom_y,
           dpr: dpr
       }}
    end
  end

  defp normalize_mode(mode) when mode in [:fit, :fill, :fill_down, :force], do: {:ok, mode}
  defp normalize_mode(mode), do: {:error, {:invalid_dimension_rule_mode, mode}}

  defp normalize_bound_dimension(_field, nil), do: {:ok, :auto}
  defp normalize_bound_dimension(_field, :auto), do: {:ok, :auto}
  defp normalize_bound_dimension(_field, {:pixels, 0}), do: {:ok, :auto}

  defp normalize_bound_dimension(_field, {:pixels, value}) when is_number(value) and value > 0,
    do: {:ok, positive_round(value)}

  defp normalize_bound_dimension(field, value),
    do: {:error, {:invalid_dimension_rule_dimension, field, value}}

  defp normalize_min_dimension(_field, nil), do: {:ok, nil}
  defp normalize_min_dimension(_field, :auto), do: {:ok, nil}
  defp normalize_min_dimension(_field, {:pixels, 0}), do: {:ok, nil}

  defp normalize_min_dimension(_field, {:pixels, value}) when is_number(value) and value > 0,
    do: {:ok, positive_round(value)}

  defp normalize_min_dimension(field, value),
    do: {:error, {:invalid_dimension_rule_dimension, field, value}}

  defp normalize_factor(_field, nil, default), do: {:ok, default}

  defp normalize_factor(_field, value, _default) when is_number(value) and value > 0,
    do: {:ok, value * 1.0}

  defp normalize_factor(field, value, _default),
    do: {:error, {:invalid_dimension_rule_factor, field, value}}

  defp validate_enlarge(enlarge) when enlarge in [true, false], do: :ok
  defp validate_enlarge(enlarge), do: {:error, {:invalid_dimension_rule_enlarge, enlarge}}

  defp resolve_base_dimensions(%DimensionRule{width: :auto, height: :auto} = rule, source) do
    if factor_requested?(rule) do
      source
      |> apply_zoom(rule)
      |> ok()
    else
      {:ok, %{width: :auto, height: :auto}}
    end
  end

  defp resolve_base_dimensions(%DimensionRule{mode: :fit} = rule, source) do
    rule
    |> requested_box(source)
    |> fit_inside(source)
    |> apply_zoom(rule)
    |> ok()
  end

  defp resolve_base_dimensions(%DimensionRule{mode: :fill} = rule, source) do
    rule
    |> requested_box(source)
    |> apply_zoom(rule)
    |> ok()
  end

  defp resolve_base_dimensions(%DimensionRule{mode: :fill_down} = rule, source) do
    rule
    |> requested_box(source)
    |> apply_zoom(rule)
    |> ok()
  end

  defp resolve_base_dimensions(%DimensionRule{mode: :force} = rule, source) do
    rule
    |> requested_box(source)
    |> apply_zoom(rule)
    |> ok()
  end

  defp requested_box(%DimensionRule{mode: :force, width: :auto, height: height}, source) do
    %{width: source.width, height: height}
  end

  defp requested_box(%DimensionRule{mode: :force, width: width, height: :auto}, source) do
    %{width: width, height: source.height}
  end

  defp requested_box(%DimensionRule{width: :auto, height: height}, source) do
    %{width: positive_round(height * source.width / source.height), height: height}
  end

  defp requested_box(%DimensionRule{width: width, height: :auto}, source) do
    %{width: width, height: positive_round(width * source.height / source.width)}
  end

  defp requested_box(%DimensionRule{width: width, height: height}, _source) do
    %{width: width, height: height}
  end

  defp fit_inside(%{width: width, height: height}, source) do
    source_ratio = source.width / source.height
    target_ratio = width / height

    if source_ratio > target_ratio do
      %{width: width, height: positive_round(width / source_ratio)}
    else
      %{width: positive_round(height * source_ratio), height: height}
    end
  end

  defp apply_zoom(%{width: width, height: height}, %DimensionRule{zoom_x: zoom_x, zoom_y: zoom_y}) do
    %{width: positive_round(width * zoom_x), height: positive_round(height * zoom_y)}
  end

  defp effective_dpr(%DimensionRule{enlarge: true, dpr: dpr}, _base, _source, _opts), do: dpr
  defp effective_dpr(%DimensionRule{dpr: 1.0}, _base, _source, _opts), do: 1.0

  defp effective_dpr(%DimensionRule{dpr: dpr}, %{width: :auto, height: :auto}, _source, _opts),
    do: dpr

  defp effective_dpr(%DimensionRule{dpr: dpr}, base, source, opts) do
    if vector_source?(opts) do
      dpr
    else
      max_dpr = min(source.width / base.width, source.height / base.height)
      min(dpr, max_dpr)
    end
  end

  defp vector_source?(opts) do
    Keyword.get(opts, :vector?, false) or Keyword.get(opts, :source_type) == :vector
  end

  defp apply_dpr(%{width: :auto, height: :auto}, _effective_dpr),
    do: %{width: :auto, height: :auto}

  defp apply_dpr(%{width: width, height: height}, effective_dpr) do
    %{
      width: positive_round(width * effective_dpr),
      height: positive_round(height * effective_dpr)
    }
  end

  defp resolve_min_dimensions(
         %DimensionRule{min_width: nil, min_height: nil},
         _source,
         _effective_dpr
       ),
       do: nil

  defp resolve_min_dimensions(%DimensionRule{} = rule, source, effective_dpr) do
    width = scaled_min(rule.min_width, effective_dpr)
    height = scaled_min(rule.min_height, effective_dpr)

    requested_box(%DimensionRule{rule | width: width || :auto, height: height || :auto}, source)
  end

  defp scaled_min(nil, _effective_dpr), do: nil
  defp scaled_min(value, effective_dpr), do: positive_round(value * effective_dpr)

  defp effective_enlarge(%DimensionRule{width: :auto, height: :auto} = rule) do
    rule.enlarge
  end

  defp effective_enlarge(%DimensionRule{} = rule), do: rule.enlarge

  defp factor_requested?(%DimensionRule{} = rule) do
    rule.zoom_x != 1.0 or rule.zoom_y != 1.0 or rule.dpr != 1.0
  end

  defp target_dimensions(_mode, %{width: :auto, height: :auto}, nil, _source, _enlarge),
    do: %{width: :auto, height: :auto}

  defp target_dimensions(_mode, %{width: :auto, height: :auto}, min_dimensions, source, _enlarge) do
    target_box_dimensions(source, min_dimensions)
  end

  defp target_dimensions(:fill_down, requested, min_dimensions, source, _enlarge) do
    requested
    |> clamp_to_source(source, false)
    |> target_box_dimensions(min_dimensions)
  end

  defp target_dimensions(_mode, requested, min_dimensions, source, enlarge) do
    requested
    |> clamp_to_source(source, enlarge)
    |> target_box_dimensions(min_dimensions)
  end

  defp intermediate_dimensions(_mode, %{width: :auto, height: :auto}, nil, source, _enlarge),
    do: source

  defp intermediate_dimensions(
         _mode,
         %{width: :auto, height: :auto},
         min_dimensions,
         source,
         _enlarge
       ) do
    target_box_dimensions(source, min_dimensions)
  end

  defp intermediate_dimensions(:fill, requested, min_dimensions, source, enlarge) do
    requested
    |> clamp_to_source(source, enlarge)
    |> target_box_dimensions(min_dimensions)
    |> cover_resize_dimensions(source)
  end

  defp intermediate_dimensions(:fill_down, requested, min_dimensions, source, _enlarge) do
    requested
    |> clamp_to_source(source, false)
    |> target_box_dimensions(min_dimensions)
    |> cover_resize_dimensions(source)
  end

  defp intermediate_dimensions(_mode, requested, nil, source, enlarge) do
    clamp_to_source(requested, source, enlarge)
  end

  defp intermediate_dimensions(_mode, requested, min_dimensions, source, enlarge) do
    requested
    |> clamp_to_source(source, enlarge)
    |> target_box_dimensions(min_dimensions)
  end

  defp target_box_dimensions(requested, nil), do: requested

  defp target_box_dimensions(requested, min_dimensions) do
    width_scale = min_dimensions.width / requested.width
    height_scale = min_dimensions.height / requested.height
    scale = max(1.0, max(width_scale, height_scale))

    scale_dimensions(requested, scale)
  end

  defp cover_resize_dimensions(%{width: width, height: height}, source) do
    source_ratio = source.width / source.height
    target_ratio = width / height

    if source_ratio > target_ratio do
      %{width: positive_round(height * source_ratio), height: height}
    else
      %{width: width, height: positive_round(width / source_ratio)}
    end
  end

  defp scale_dimensions(%{width: width, height: height}, scale) do
    %{width: positive_round(width * scale), height: positive_round(height * scale)}
  end

  defp clamp_to_source(dimensions, _source, true), do: dimensions

  defp clamp_to_source(%{width: width, height: height} = dimensions, source, false) do
    scale = min(1.0, min(source.width / width, source.height / height))

    if scale < 1.0 do
      scale_dimensions(dimensions, scale)
    else
      dimensions
    end
  end

  defp positive_round(value) when is_number(value) do
    value
    |> round()
    |> max(1)
  end

  defp ok(value), do: {:ok, value}
end
