defmodule ImagePipe.Transform.Operation.Crop do
  @moduledoc """
  Represents an executable crop operation that selects a bounded rectangle
  from the current image.

  ## Construct When

  Transform Plan execution may convert semantic Plan operations to this
  executable operation. Parser modules should construct
  `ImagePipe.Plan.Operation.*` through Plan constructors.

  Use `Crop` for resolved visible crop work, coordinate-based crops, and result
  crops that trim an already resized image back to resolved target geometry.
  Parser-specific gravity inheritance belongs in the parser/adapter layer
  before semantic Plan operations are constructed.

  ## Fields

  Required fields:

  - `width`: crop width as a positive length or `:auto`.
  - `height`: crop height as a positive length or `:auto`.
  - `crop_from`: crop source, either `:gravity` or `%{left: left, top: top}`
    with non-negative position lengths.

  Optional fields:

  - `gravity`: `nil`, an anchor tuple
    `{:anchor, :left | :center | :right, :top | :center | :bottom}`, or a
    focal point tuple `{:fp, x, y}` where `x` and `y` are normalized `0.0..1.0`
    coordinates.
  - `x_offset`: horizontal offset as a number, `{:pixels, value}`,
    `{:scale, value}`, `{:scale, numerator, denominator}`, or
    `{:percent, value}`. Defaults to `0.0`.
  - `y_offset`: vertical offset using the same units as `x_offset`. Defaults
    to `0.0`.
  - `offset_scale`: multiplier applied to pixel offsets, usually the effective
    DPR used by the preceding resize. Defaults to `1.0`.

  Numeric length units are resolved against the current image dimensions during
  execution. `:auto` crop dimensions resolve to the current image dimension on
  that axis.

  ## Execution Semantics

  `execute/2` crops `ImagePipe.Transform.State.image` and returns a state with
  the cropped image. If coordinate mapping or image cropping fails, execution
  returns `{:error, {__MODULE__, reason}}`.

  For `crop_from: :gravity`, execution resolves crop dimensions against the
  current image, defaulting gravity to center when none is provided. Anchor
  gravity pins the crop to an edge or center. Focal-point gravity centers the
  crop around a normalized current-image point and clamps it into image bounds.

  Result crops are represented as `crop_from: :gravity` with explicit `width`
  and `height`. Pixel offsets are multiplied by `offset_scale`; scale and
  percent offsets are resolved relative to the current image bounds.

  For coordinate crops, `crop_from` is the requested top-left crop position
  before the rectangle is clamped to image bounds.

  ## Examples

      crop = %ImagePipe.Transform.Operation.Crop{
        width: {:pixels, 300},
        height: {:pixels, 200},
        crop_from: :gravity,
        gravity: {:fp, 0.25, 0.75},
        x_offset: {:scale, 0.1},
        y_offset: {:pixels, -12}
      }

  A semantic crop request with focal-point guide may execute as the same kind
  of `Crop` operation. URL grammar and aliases stay in parser documentation.
  """

  @behaviour ImagePipe.Transform

  import ImagePipe.Transform.State, only: [set_image: 2]

  import ImagePipe.Transform.Geometry,
    only: [anchor_to_pixels: 3, image_height: 1, image_width: 1, to_pixels: 2]

  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.State
  alias Vix.Vips.Operation

  @default_gravity {:anchor, :center, :center}

  # Face-favoring blend weight for `{:smart, :face_assist}` gravity. ImagePipe's
  # documented approximation of imgproxy's `smart_crop_face_detection`, whose
  # exact combination of attention saliency and detected faces is unspecified.
  @face_assist_weight 0.7

  @type length_unit() ::
          integer()
          | float()
          | {:pixels, integer() | float()}
          | {:percent, integer() | float()}
          | {:scale, integer() | float()}
          | {:scale, integer() | float(), integer() | float()}

  @doc """
  The executable operation used by `ImagePipe.Transform.Operation.Crop`.
  """
  defstruct [
    :width,
    :height,
    :crop_from,
    gravity: nil,
    x_offset: 0.0,
    y_offset: 0.0,
    offset_scale: 1.0,
    aspect_ratio: nil,
    enlarge: false
  ]

  @type t :: %__MODULE__{
          width: length_unit() | :auto,
          height: length_unit() | :auto,
          crop_from:
            :gravity
            | %{
                left: length_unit(),
                top: length_unit()
              },
          gravity:
            {:anchor, :left | :center | :right, :top | :center | :bottom}
            | {:fp, float(), float()}
            | :smart
            | {:smart, :face_assist}
            | {:detect, [String.t()]}
            | nil,
          x_offset: length_unit() | number(),
          y_offset: length_unit() | number(),
          offset_scale: pos_integer() | float(),
          aspect_ratio: nil | {:ratio, pos_integer(), pos_integer()},
          enlarge: boolean()
        }

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :crop

  @impl ImagePipe.Transform
  def execute(%__MODULE__{gravity: :smart} = params, %State{} = state) do
    smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)
  end

  def execute(%__MODULE__{gravity: {:detect, classes}} = params, %State{} = state) do
    detect_crop(params, state, classes)
  end

  def execute(%__MODULE__{gravity: {:smart, :face_assist}} = params, %State{} = state) do
    {module, dopts} = normalize_detector(state.detector)

    if is_nil(module) do
      emit_no_detector_span(["face"], state.telemetry_opts)
      smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)
    else
      face_assist_crop(params, state, module, dopts)
    end
  end

  def execute(%__MODULE__{} = params, %State{} = state) do
    image_width = image_width(state)
    image_height = image_height(state)

    case crop_coordinates(params, state, image_width, image_height) do
      {:ok, %{left: left, top: top, width: crop_width, height: crop_height}} ->
        case Image.crop(state.image, left, top, crop_width, crop_height) do
          {:ok, cropped_image} -> {:ok, set_image(state, cropped_image)}
          {:error, error} -> {:error, {__MODULE__, error}}
        end

      {:error, error} ->
        {:error, {__MODULE__, error}}
    end
  end

  defp crop_coordinates(
         %__MODULE__{crop_from: :gravity} = params,
         %State{},
         image_width,
         image_height
       ) do
    with {:ok, crop} <- crop_dimensions(params, image_width, image_height),
         {:ok, crop_width} <- crop_dimension(crop.width, image_width),
         {:ok, crop_height} <- crop_dimension(crop.height, image_height),
         {crop_width, crop_height} =
           correct_aspect_ratio(
             crop_width,
             crop_height,
             params.aspect_ratio,
             params.enlarge,
             image_width,
             image_height
           ),
         {:ok, gravity} <- crop_gravity(default_if_nil(params.gravity, @default_gravity)),
         {:ok, offset_scale} <- offset_scale(crop.offset_scale),
         {:ok, x_offset} <-
           crop_offset(default_if_nil(params.x_offset, 0.0), image_width, offset_scale),
         {:ok, y_offset} <-
           crop_offset(default_if_nil(params.y_offset, 0.0), image_height, offset_scale) do
      {:ok,
       gravity_crop_coordinates(
         image_width,
         image_height,
         crop_width,
         crop_height,
         gravity,
         x_offset,
         y_offset
       )}
    end
  end

  defp crop_coordinates(%__MODULE__{} = params, %State{}, image_width, image_height) do
    # keep :auto dimensions as is
    target_width = if params.width == :auto, do: image_width, else: params.width
    target_height = if params.height == :auto, do: image_height, else: params.height

    # make sure crop is within image bounds
    crop_width = max(1, min(image_width, to_pixels(image_width, target_width)))
    crop_height = max(1, min(image_height, to_pixels(image_height, target_height)))

    # figure out the crop anchor
    {center_x, center_y} =
      anchor_crop_to_pixels(params.crop_from, image_width, image_height, crop_width, crop_height)

    # ...and make sure crop still stays within bounds
    left = max(0, min(image_width - crop_width, round(center_x - crop_width / 2)))
    top = max(0, min(image_height - crop_height, round(center_y - crop_height / 2)))

    {:ok, %{left: left, top: top, width: crop_width, height: crop_height}}
  end

  defp smart_crop(%__MODULE__{} = params, %State{} = state, interesting) do
    image_width = image_width(state)
    image_height = image_height(state)

    with {:ok, crop} <- crop_dimensions(params, image_width, image_height),
         {:ok, crop_width} <- crop_dimension(crop.width, image_width),
         {:ok, crop_height} <- crop_dimension(crop.height, image_height),
         {crop_width, crop_height} =
           correct_aspect_ratio(
             crop_width,
             crop_height,
             params.aspect_ratio,
             params.enlarge,
             image_width,
             image_height
           ),
         {:ok, {cropped, _attention}} <-
           Operation.smartcrop(state.image, crop_width, crop_height, interesting: interesting) do
      {:ok, set_image(state, cropped)}
    else
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  defp face_assist_crop(%__MODULE__{} = params, %State{} = state, module, dopts) do
    with {:ok, [_ | _] = regions} <-
           run_detect(module, dopts, state.image, ["face"], state.telemetry_opts),
         {:ok, {:fp, fx, fy}} <-
           focal_from_regions(regions, image_width(state), image_height(state)),
         {:ok, {ax, ay}} <- attention_point(params, state) do
      blended = {:fp, blend_axis(ax, fx), blend_axis(ay, fy)}
      execute(%{params | gravity: blended}, state)
    else
      _ -> smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)
    end
  end

  defp blend_axis(attention, face),
    do: clamp_unit((1 - @face_assist_weight) * attention + @face_assist_weight * face)

  defp attention_point(%__MODULE__{} = params, %State{} = state) do
    image_width = image_width(state)
    image_height = image_height(state)

    with {:ok, crop} <- crop_dimensions(params, image_width, image_height),
         {:ok, crop_width} <- crop_dimension(crop.width, image_width),
         {:ok, crop_height} <- crop_dimension(crop.height, image_height),
         {crop_width, crop_height} =
           correct_aspect_ratio(
             crop_width,
             crop_height,
             params.aspect_ratio,
             params.enlarge,
             image_width,
             image_height
           ),
         {:ok, {_cropped, attention}} <-
           Operation.smartcrop(state.image, crop_width, crop_height,
             interesting: :VIPS_INTERESTING_ATTENTION
           ) do
      ax = Map.fetch!(attention, :"attention-x")
      ay = Map.fetch!(attention, :"attention-y")
      {:ok, {clamp_unit(ax / image_width), clamp_unit(ay / image_height)}}
    end
  end

  defp detect_crop(%__MODULE__{} = params, %State{} = state, classes) do
    {module, dopts} = normalize_detector(state.detector)

    if is_nil(module) do
      emit_no_detector_span(classes, state.telemetry_opts)
      smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)
    else
      detect_crop_with_module(params, state, module, dopts, classes)
    end
  end

  defp detect_crop_with_module(%__MODULE__{} = params, %State{} = state, module, dopts, classes) do
    with {:ok, [_ | _] = regions} <-
           run_detect(module, dopts, state.image, classes, state.telemetry_opts),
         {:ok, focal} <- focal_from_regions(regions, image_width(state), image_height(state)) do
      execute(%{params | gravity: focal}, state)
    else
      _ -> smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)
    end
  end

  defp normalize_detector(nil), do: {nil, []}
  defp normalize_detector(module) when is_atom(module), do: {module, []}

  defp normalize_detector({module, opts}) when is_atom(module) and is_list(opts),
    do: {module, opts}

  defp run_detect(module, opts, image, classes, telemetry_opts) do
    Telemetry.span(telemetry_opts, [:transform, :detect], %{classes: classes}, fn ->
      result = validate_detect_result(module.detect(image, Keyword.put(opts, :classes, classes)))
      {result, %{regions: region_count(result), result: detect_reason(result)}}
    end)
  end

  # Emits a detect span for the "face-aware request, but no detector configured"
  # fallback so every face-aware request produces exactly one detect span. There
  # is no detection work to measure, so the duration is near-zero by design; the
  # observable signal is `result: :no_detector`.
  defp emit_no_detector_span(classes, telemetry_opts) do
    Telemetry.span(telemetry_opts, [:transform, :detect], %{classes: classes}, fn ->
      {:no_detector, %{regions: 0, result: :no_detector}}
    end)
  end

  # The detector-level outcome recorded on the detect span's stop metadata. It
  # reflects what the detector returned, not the final crop decision: a usable
  # `:detected` result whose boxes all fall outside the image still degrades to
  # attention downstream. `:no_regions` is normal (no face in the frame);
  # `:unavailable`, `:error`, and `:no_detector` mark a face-aware request that
  # could not be fulfilled and fell back to attention saliency.
  defp detect_reason({:ok, [_ | _]}), do: :detected
  defp detect_reason({:ok, []}), do: :no_regions
  defp detect_reason({:error, {:detector, :unavailable}}), do: :unavailable
  defp detect_reason({:error, _}), do: :error

  defp validate_detect_result({:ok, regions}) when is_list(regions) do
    if Enum.all?(regions, &valid_region?/1),
      do: {:ok, regions},
      else: {:error, {:detector, :invalid_adapter_result}}
  end

  defp validate_detect_result({:error, _} = error), do: error
  defp validate_detect_result(_other), do: {:error, {:detector, :invalid_adapter_result}}

  defp region_count({:ok, regions}), do: length(regions)
  defp region_count(_), do: 0

  defp valid_region?(%{box: {x, y, w, h}})
       when is_number(x) and is_number(y) and is_number(w) and is_number(h),
       do: true

  defp valid_region?(_), do: false

  defp focal_from_regions(regions, image_width, image_height) do
    in_image =
      Enum.filter(regions, fn %{box: {x, y, w, h}} ->
        w > 0 and h > 0 and x >= 0 and y >= 0 and x + w <= image_width and y + h <= image_height
      end)

    case in_image do
      [] ->
        :none

      boxes ->
        total = Enum.reduce(boxes, 0.0, fn %{box: {_x, _y, w, h}}, acc -> acc + w * h end)

        {sx, sy} =
          Enum.reduce(boxes, {0.0, 0.0}, fn %{box: {x, y, w, h}}, {ax, ay} ->
            area = w * h
            {ax + area * (x + w / 2), ay + area * (y + h / 2)}
          end)

        {:ok, {:fp, clamp_unit(sx / total / image_width), clamp_unit(sy / total / image_height)}}
    end
  end

  defp clamp_unit(value), do: value |> max(0.0) |> min(1.0)

  defp default_if_nil(nil, default), do: default
  defp default_if_nil(value, _default), do: value

  defp crop_dimensions(%__MODULE__{} = params, _image_width, _image_height) do
    {:ok, %{width: params.width, height: params.height, offset_scale: params.offset_scale}}
  end

  defp gravity_crop_coordinates(
         image_width,
         image_height,
         crop_width,
         crop_height,
         gravity,
         x_offset,
         y_offset
       ) do
    crop_width = max(1, min(image_width, crop_width))
    crop_height = max(1, min(image_height, crop_height))

    {left, top} = gravity_origin(gravity, image_width, image_height, crop_width, crop_height)

    %{
      left: clamp_position(round_ties_to_even(left + x_offset), image_width - crop_width),
      top: clamp_position(round_ties_to_even(top + y_offset), image_height - crop_height),
      width: crop_width,
      height: crop_height
    }
  end

  defp gravity_origin(
         {:anchor, x_anchor, y_anchor},
         image_width,
         image_height,
         crop_width,
         crop_height
       ) do
    {
      anchor_origin(x_anchor, image_width, crop_width),
      anchor_origin(y_anchor, image_height, crop_height)
    }
  end

  defp gravity_origin({:fp, x, y}, image_width, image_height, crop_width, crop_height) do
    {
      x * image_width - crop_width / 2,
      y * image_height - crop_height / 2
    }
  end

  defp anchor_origin(:left, _bounds, _crop), do: 0.0
  defp anchor_origin(:top, _bounds, _crop), do: 0.0
  defp anchor_origin(:center, bounds, crop), do: (bounds - crop + 1) / 2
  defp anchor_origin(:right, bounds, crop), do: bounds - crop
  defp anchor_origin(:bottom, bounds, crop), do: bounds - crop

  defp clamp_position(value, max_value), do: max(0, min(max_value, value))

  defp crop_dimension(:auto, bounds), do: {:ok, bounds}

  defp crop_dimension(value, bounds) when is_integer(value) and value > 0,
    do: {:ok, min(value, bounds)}

  defp crop_dimension(value, bounds) when is_float(value) and value > 0,
    do: {:ok, min(round_ties_to_even(value), bounds)}

  defp crop_dimension({:pixels, value}, bounds), do: crop_dimension(value, bounds)

  defp crop_dimension({:scale, numerator, denominator}, bounds)
       when is_number(numerator) and is_number(denominator) and numerator > 0 and denominator > 0 do
    {:ok, min(round_ties_to_even(bounds * numerator / denominator), bounds)}
  end

  defp crop_dimension({:scale, value}, bounds) when is_number(value) and value > 0 do
    {:ok, min(round_ties_to_even(bounds * value), bounds)}
  end

  defp crop_dimension({:percent, value}, bounds) when is_number(value) and value > 0 do
    {:ok, min(round_ties_to_even(bounds * value / 100), bounds)}
  end

  defp crop_dimension(value, _bounds), do: {:error, {:invalid_crop_dimension, value}}

  defp crop_offset(value, _bounds, _offset_scale) when is_number(value), do: {:ok, value}

  defp crop_offset({:scale, numerator, denominator}, bounds, _offset_scale)
       when is_number(numerator) and is_number(denominator) and denominator != 0 do
    {:ok, bounds * numerator / denominator}
  end

  defp crop_offset({:scale, value}, bounds, _offset_scale) when is_number(value),
    do: {:ok, bounds * value}

  defp crop_offset({:percent, value}, bounds, _offset_scale) when is_number(value),
    do: {:ok, bounds * value / 100}

  defp crop_offset({:pixels, value}, _bounds, offset_scale) when is_number(value),
    do: {:ok, value * offset_scale}

  defp crop_offset(value, _bounds, _offset_scale), do: {:error, {:invalid_crop_offset, value}}

  defp offset_scale(value) when is_number(value) and value > 0, do: {:ok, value * 1.0}
  defp offset_scale(value), do: {:error, {:invalid_crop_offset_scale, value}}

  defp crop_gravity({:anchor, x, y} = gravity)
       when x in [:left, :center, :right] and y in [:top, :center, :bottom],
       do: {:ok, gravity}

  defp crop_gravity({:fp, x, y} = gravity)
       when is_number(x) and is_number(y) and x >= 0.0 and x <= 1.0 and y >= 0.0 and y <= 1.0,
       do: {:ok, gravity}

  defp crop_gravity(value), do: {:error, {:invalid_crop_gravity, value}}

  defp round_ties_to_even(value) when is_integer(value), do: value

  defp round_ties_to_even(value) when is_float(value) do
    floor = Float.floor(value)
    fraction = value - floor
    floor = trunc(floor)

    cond do
      fraction < 0.5 -> floor
      fraction > 0.5 -> floor + 1
      rem(floor, 2) == 0 -> floor
      true -> floor + 1
    end
  end

  defp anchor_crop_to_pixels(
         %{left: left, top: top},
         image_width,
         image_height,
         crop_width,
         crop_height
       ) do
    # if explicit coordinates are given, they are to be the top-left corner of the crop,
    # so we need to move the center point based on the crop dimensions
    {left, top} = anchor_to_pixels({:coordinate, left, top}, image_width, image_height)
    center_x = round(left + crop_width / 2)
    center_y = round(top + crop_height / 2)
    {center_x, center_y}
  end

  defp correct_aspect_ratio(width, height, nil, _enlarge, _image_width, _image_height),
    do: {width, height}

  defp correct_aspect_ratio(
         width,
         height,
         {:ratio, numerator, denominator},
         enlarge,
         image_width,
         image_height
       ) do
    target = numerator / denominator
    current = width / height

    {corrected_width, corrected_height} =
      cond do
        current == target -> {width, height}
        enlarge and current > target -> {width, round_ties_to_even(width / target)}
        enlarge -> {round_ties_to_even(height * target), height}
        current > target -> {round_ties_to_even(height * target), height}
        true -> {width, round_ties_to_even(width / target)}
      end

    clamp_to_bounds(corrected_width, corrected_height, image_width, image_height)
  end

  defp clamp_to_bounds(width, height, image_width, image_height) do
    scale = min(1.0, min(image_width / width, image_height / height))

    width = max(1, min(image_width, round_ties_to_even(width * scale)))
    height = max(1, min(image_height, round_ties_to_even(height * scale)))

    {width, height}
  end
end
