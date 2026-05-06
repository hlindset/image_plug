defmodule ImagePlug.Transform.Crop do
  @moduledoc """
  Represents a product-neutral crop operation that selects a bounded rectangle
  from the current image.

  ## Construct When

  Construct `Crop` when parser or planner code has a visible crop to apply to
  the image. Use it for explicit crop requests, focus- or coordinate-based
  crops, and result crops that trim an already resized image back to resolved
  target geometry.

  Native parser translations use explicit crops for `crop`/`c` request fields
  and result crops after fill, fill-down, or auto resize planning. In that
  translation layer, a crop-specific gravity overrides top-level gravity, while
  an explicit crop without its own gravity inherits the top-level gravity before
  this operation is constructed.

  ## Construction API

  `new/1` accepts a keyword list and returns
  `{:ok, operation}` when all fields are valid. Invalid attributes, missing
  required fields, or unknown keys return `{:error, exception}`.

  `new!/1` accepts the same input and returns an operation, raising
  `ArgumentError` or `KeyError` for invalid attributes.

  ## Fields

  Required fields:

  - `width`: crop width as a positive length or `:auto`.
  - `height`: crop height as a positive length or `:auto`.
  - `crop_from`: crop source, one of `:focus`, `:gravity`, or
    `%{left: left, top: top}` with non-negative position lengths.

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
  - `orientation`: `nil` or a map/struct with `auto_orient`, `rotate`, and
    `flip` fields. `rotate` must be `0`, `90`, `180`, or `270`; `flip` may be
    `nil`, `:none`, `:horizontal`, `:vertical`, or `:both`.
  - `target_rule`: `nil` or an `ImagePlug.Transform.Geometry.DimensionRule`
    with mode `:fit`, `:fill`, `:fill_down`, `:force`, or `:auto`. Result crops
    use this rule to resolve crop dimensions from the current image.

  Numeric length units are resolved against the current image dimensions during
  execution. `:auto` crop dimensions resolve to the current image dimension on
  that axis.

  ## Execution Semantics

  `execute/2` crops `ImagePlug.Transform.State.image`, stores the cropped image
  back into the state, and resets focus. If coordinate mapping or image cropping
  fails, execution records `{__MODULE__, reason}` in the state errors.

  For `crop_from: :gravity`, execution resolves crop dimensions, defaulting
  gravity to center when none is provided, and delegates rectangle mapping to
  `ImagePlug.Transform.Geometry.CropCoordinateMapper`. Anchor gravity pins the
  crop to an edge or center. Focal-point gravity centers the crop around a
  normalized image point and clamps it into source bounds.

  Result crops are represented as `crop_from: :gravity` with a `target_rule`.
  The rule resolves the final crop size, including the effective DPR used by
  resize planning. Pixel offsets are multiplied by that effective DPR during
  coordinate mapping; scale and percent offsets are resolved relative to the
  oriented source bounds.

  For `crop_from: :focus`, execution centers the crop on
  `ImagePlug.Transform.State.focus`. For coordinate crops, `crop_from` is the
  requested top-left crop position before the rectangle is clamped to image
  bounds.

  The optional `orientation` context tells `CropCoordinateMapper` how to map
  semantic crop coordinates through right-angle rotation and flip metadata
  before returning physical source-image coordinates. Auto-orientation cannot be
  mapped from metadata alone; parser translations that support auto-orient plus
  crop should plan auto-orientation as an earlier operation before this crop.

  ## Decode Planning Metadata

  `metadata/1` returns `%{access: :random}`. Crops need random source access
  because execution may read from any bounded rectangle rather than consuming
  pixels safely in a single sequential pass.

  ## Cache Material

  For `crop_from: :gravity`, material emits:

  - `:op`
  - `:width`
  - `:height`
  - `:crop_from`
  - `:gravity`
  - `:x_offset`
  - `:y_offset`
  - `:orientation`

  `:orientation` is a keyword list with `:auto_orient`, `:rotate`, and `:flip`;
  `nil` orientation materializes as
  `[auto_orient: false, rotate: 0, flip: nil]`.

  When `target_rule` is present, material also emits `:target_rule` with:

  - `:mode`
  - `:width`
  - `:height`
  - `:min_width`
  - `:min_height`
  - `:zoom_x`
  - `:zoom_y`
  - `:dpr`
  - `:enlarge`

  For non-gravity crops, material emits only:

  - `:op`
  - `:width`
  - `:height`
  - `:crop_from`

  ## Examples

      {:ok, crop} =
        ImagePlug.Transform.Crop.new(
          width: {:pixels, 300},
          height: {:pixels, 200},
          crop_from: :gravity,
          gravity: {:fp, 0.25, 0.75},
          x_offset: {:scale, 0.1},
          y_offset: {:pixels, -12}
        )

      result_crop =
        ImagePlug.Transform.Crop.new!(
          width: :auto,
          height: :auto,
          crop_from: :gravity,
          gravity: {:anchor, :center, :center},
          target_rule: %ImagePlug.Transform.Geometry.DimensionRule{
            mode: :fill,
            width: {:pixels, 300},
            height: {:pixels, 200}
          }
        )

  A Native parser translation for a crop request with focal-point gravity would
  construct the same kind of `Crop` operation; the URL grammar and aliases stay
  in the parser documentation.
  """

  @behaviour ImagePlug.Transform

  import ImagePlug.Transform.State
  import ImagePlug.Transform.Geometry

  alias ImagePlug.Transform.Geometry.CropCoordinateMapper
  alias ImagePlug.Transform.Geometry.DimensionResolver
  alias ImagePlug.Transform.Geometry.DimensionRule
  alias ImagePlug.Transform.State
  alias ImagePlug.Transform.Validation

  @default_gravity {:anchor, :center, :center}
  @default_orientation %{auto_orient: false, rotate: 0, flip: nil}

  @doc """
  The parsed operation used by `ImagePlug.Transform.Crop`.
  """
  defstruct [
    :width,
    :height,
    :crop_from,
    gravity: nil,
    x_offset: 0.0,
    y_offset: 0.0,
    orientation: nil,
    target_rule: nil
  ]

  @type t :: %__MODULE__{
          width: ImagePlug.imgp_length() | :auto,
          height: ImagePlug.imgp_length() | :auto,
          # Future parser work can output focus + crop actions instead of this special crop_from handling.
          crop_from:
            :focus | :gravity | %{left: ImagePlug.imgp_length(), top: ImagePlug.imgp_length()},
          gravity:
            {:anchor, :left | :center | :right, :top | :center | :bottom}
            | {:fp, float(), float()}
            | nil,
          x_offset: ImagePlug.imgp_length() | number(),
          y_offset: ImagePlug.imgp_length() | number(),
          orientation: map() | struct() | nil,
          target_rule: DimensionRule.t() | nil
        }

  def new(attrs) do
    {:ok, new!(attrs)}
  rescue
    exception in [ArgumentError, KeyError] ->
      {:error, exception}
  end

  def new!(attrs) when is_list(attrs) do
    attrs
    |> validate_attrs!()
    |> then(&struct!(__MODULE__, &1))
  end

  def new!(attrs), do: Validation.invalid_options!("crop", attrs)

  @impl ImagePlug.Transform
  def name(%__MODULE__{}), do: :crop

  @impl ImagePlug.Transform
  def metadata(%__MODULE__{}), do: %{access: :random}

  @impl ImagePlug.Transform
  def execute(%__MODULE__{} = params, %State{} = state) do
    image_width = image_width(state)
    image_height = image_height(state)

    case crop_coordinates(params, state, image_width, image_height) do
      {:ok, %{left: left, top: top, width: crop_width, height: crop_height}} ->
        case Image.crop(state.image, left, top, crop_width, crop_height) do
          {:ok, cropped_image} -> state |> set_image(cropped_image) |> reset_focus()
          {:error, error} -> add_error(state, {__MODULE__, error})
        end

      {:error, error} ->
        add_error(state, {__MODULE__, error})
    end
  end

  defp crop_coordinates(
         %__MODULE__{crop_from: :gravity} = params,
         %State{},
         image_width,
         image_height
       ) do
    with {:ok, crop} <- crop_dimensions(params, image_width, image_height) do
      CropCoordinateMapper.map(
        source_width: image_width,
        source_height: image_height,
        crop_width: crop.width,
        crop_height: crop.height,
        gravity: default_if_nil(params.gravity, @default_gravity),
        x_offset: default_if_nil(params.x_offset, 0.0),
        y_offset: default_if_nil(params.y_offset, 0.0),
        offset_scale: crop.offset_scale,
        orientation: default_if_nil(params.orientation, @default_orientation)
      )
    end
  end

  defp crop_coordinates(%__MODULE__{} = params, %State{} = state, image_width, image_height) do
    # keep :auto dimensions as is
    target_width = if params.width == :auto, do: image_width, else: params.width
    target_height = if params.height == :auto, do: image_height, else: params.height

    # make sure crop is within image bounds
    crop_width = max(1, min(image_width, to_pixels(image_width, target_width)))
    crop_height = max(1, min(image_height, to_pixels(image_height, target_height)))

    # figure out the crop anchor
    {center_x, center_y} =
      anchor_crop_to_pixels(
        state,
        params.crop_from,
        image_width,
        image_height,
        crop_width,
        crop_height
      )

    # ...and make sure crop still stays within bounds
    left = max(0, min(image_width - crop_width, round(center_x - crop_width / 2)))
    top = max(0, min(image_height - crop_height, round(center_y - crop_height / 2)))

    {:ok, %{left: left, top: top, width: crop_width, height: crop_height}}
  end

  defp default_if_nil(nil, default), do: default
  defp default_if_nil(value, _default), do: value

  defp crop_dimensions(%__MODULE__{target_rule: nil} = params, _image_width, _image_height) do
    {:ok, %{width: params.width, height: params.height, offset_scale: 1.0}}
  end

  defp crop_dimensions(
         %__MODULE__{target_rule: %DimensionRule{} = rule},
         image_width,
         image_height
       ) do
    rule = resolve_auto_target_rule(rule, image_width, image_height)
    opts = [source_width: image_width, source_height: image_height]

    with {:ok, dimensions} <- DimensionResolver.resolve(rule, opts) do
      {:ok,
       %{
         width: dimensions.target_width,
         height: dimensions.target_height,
         offset_scale: dimensions.effective_dpr
       }}
    end
  end

  defp resolve_auto_target_rule(%DimensionRule{mode: :auto} = rule, image_width, image_height) do
    %DimensionRule{rule | mode: adaptive_target_mode(rule, image_width, image_height)}
  end

  defp resolve_auto_target_rule(%DimensionRule{} = rule, _image_width, _image_height), do: rule

  defp adaptive_target_mode(%DimensionRule{} = rule, image_width, image_height) do
    with {:ok, width} <- requested_dimension(rule.width, image_width),
         {:ok, height} <- requested_dimension(rule.height, image_height) do
      if same_orientation?(image_width, image_height, width, height), do: :fill, else: :fit
    else
      :error -> :fit
    end
  end

  defp requested_dimension(nil, _source_dimension), do: :error
  defp requested_dimension(:auto, _source_dimension), do: :error

  defp requested_dimension(dimension, source_dimension),
    do: {:ok, to_pixels(source_dimension, dimension)}

  defp same_orientation?(source_width, source_height, target_width, target_height) do
    orientation(source_width, source_height) == orientation(target_width, target_height)
  end

  defp orientation(width, height) when width > height, do: :landscape
  defp orientation(width, height) when width < height, do: :portrait
  defp orientation(_width, _height), do: :square

  defp anchor_crop_to_pixels(
         %State{},
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

  defp anchor_crop_to_pixels(
         %State{} = state,
         :focus,
         image_width,
         image_height,
         _crop_width,
         _crop_height
       ) do
    anchor_to_pixels(state.focus, image_width, image_height)
  end

  defp validate_attrs!(attrs) do
    attrs =
      Validation.attrs!(
        attrs,
        [
          :width,
          :height,
          :crop_from,
          :gravity,
          :x_offset,
          :y_offset,
          :orientation,
          :target_rule
        ],
        "crop"
      )

    Validation.positive_dimension_or_auto!("crop", :width, Map.fetch!(attrs, :width))
    Validation.positive_dimension_or_auto!("crop", :height, Map.fetch!(attrs, :height))
    validate_crop_from!(Map.fetch!(attrs, :crop_from))
    Validation.gravity!("crop", :gravity, Map.get(attrs, :gravity))
    Validation.offset!("crop", :x_offset, Map.get(attrs, :x_offset, 0.0))
    Validation.offset!("crop", :y_offset, Map.get(attrs, :y_offset, 0.0))
    Validation.orientation!("crop", :orientation, Map.get(attrs, :orientation))
    validate_target_rule!(Map.get(attrs, :target_rule))

    attrs
  end

  defp validate_crop_from!(:focus), do: :ok
  defp validate_crop_from!(:gravity), do: :ok

  defp validate_crop_from!(%{left: left, top: top} = crop_from) do
    Validation.keys!(crop_from, [:left, :top], "crop")
    Validation.non_negative_position!("crop", :crop_from_left, left)
    Validation.non_negative_position!("crop", :crop_from_top, top)
  end

  defp validate_crop_from!(crop_from),
    do: raise(ArgumentError, "invalid crop_from: #{inspect(crop_from)}")

  defp validate_target_rule!(nil), do: :ok

  defp validate_target_rule!(%DimensionRule{} = rule) do
    Validation.dimension_rule!("crop", :target_rule, rule, [
      :fit,
      :fill,
      :fill_down,
      :force,
      :auto
    ])
  end

  defp validate_target_rule!(target_rule),
    do: Validation.invalid!("crop", :target_rule, target_rule)
end
