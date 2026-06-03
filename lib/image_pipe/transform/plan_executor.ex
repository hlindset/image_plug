defmodule ImagePipe.Transform.PlanExecutor do
  @moduledoc false

  # Deferred orientation (#146): EXIF is seeded into State.pending_orientation once,
  # on the first pipeline (seed_orientation opt); user rotate/flip fold into pending
  # rather than emitting eager ops; pre-flush crop/resize are compensated in the
  # storage frame (Orientation.compensate_gravity_for / Orientation.swap_resize);
  # pending is flushed (OrientationFlush via Materializer) at the first materializing
  # op, immediately after a resize, before a region crop, at each pipeline boundary,
  # or at the delivery backstop — whichever is first. An identity pending is cleared
  # without materializing (streaming fast path).

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.Operation.Background, as: PlanBackground
  alias ImagePipe.Plan.Operation.Blur, as: PlanBlur
  alias ImagePipe.Plan.Operation.Brightness, as: PlanBrightness
  alias ImagePipe.Plan.Operation.Canvas
  alias ImagePipe.Plan.Operation.Contrast, as: PlanContrast
  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Operation.CropRegion
  alias ImagePipe.Plan.Operation.Duotone, as: PlanDuotone
  alias ImagePipe.Plan.Operation.Flip, as: PlanFlip
  alias ImagePipe.Plan.Operation.Monochrome, as: PlanMonochrome
  alias ImagePipe.Plan.Operation.NormalizeColorProfile, as: PlanNormalizeColorProfile
  alias ImagePipe.Plan.Operation.Padding, as: PlanPadding
  alias ImagePipe.Plan.Operation.Pixelate, as: PlanPixelate
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Plan.Operation.Rotate, as: PlanRotate
  alias ImagePipe.Plan.Operation.Saturation, as: PlanSaturation
  alias ImagePipe.Plan.Operation.Sharpen, as: PlanSharpen
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.Operation.Background
  alias ImagePipe.Transform.Operation.Blur
  alias ImagePipe.Transform.Operation.Brightness
  alias ImagePipe.Transform.Operation.Contrast
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.Duotone
  alias ImagePipe.Transform.Operation.ExtendCanvas
  alias ImagePipe.Transform.Operation.Monochrome
  alias ImagePipe.Transform.Operation.NormalizeColorProfile
  alias ImagePipe.Transform.Operation.Padding
  alias ImagePipe.Transform.Operation.Pixelate
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.Operation.Saturation
  alias ImagePipe.Transform.Operation.Sharpen
  alias ImagePipe.Transform.Orientation
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  @spec execute(Plan.t(), State.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def execute(%Plan{pipelines: pipelines, auto_rotate: auto_rotate}, %State{} = state, opts) do
    state = %{
      state
      | detector: ImagePipe.Transform.resolve_detector(Keyword.get(opts, :detector, :default)),
        detector_required: Keyword.get(opts, :detector_required, false),
        telemetry_opts: Telemetry.telemetry_opts(opts)
    }

    state =
      if Keyword.get(opts, :seed_orientation, false) do
        %State{
          state
          | pending_orientation:
              PendingOrientation.from_exif(exif_orientation(state.image), auto_rotate)
        }
      else
        state
      end

    execute_pipelines(pipelines, state, opts)
  end

  defp exif_orientation(image) do
    case VipsImage.header_value(image, "orientation") do
      {:ok, value} when is_integer(value) -> value
      _ -> 1
    end
  end

  defp execute_pipelines(pipelines, %State{} = state, opts) do
    Enum.reduce_while(pipelines, {:ok, state}, fn pipeline, {:ok, state} ->
      case execute_pipeline(pipeline, state, opts) do
        {:ok, %State{} = state} -> {:cont, {:ok, state}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp execute_pipeline(%Pipeline{operations: operations}, %State{} = state, opts) do
    initial_context = %{effective_padding_scale: nil, canvas_preserving_padding_scale: nil}

    Enum.reduce_while(operations, {:ok, state, initial_context}, fn operation,
                                                                    {:ok, state, context} ->
      context = update_execution_context(operation, state, context)

      case execute_operation(operation, state, context, opts) do
        {:ok, %State{} = state} -> {:cont, {:ok, state, context}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, state, _context} -> flush_if_pending(state)
      {:error, _reason} = error -> error
    end
  end

  defp flush_if_pending(%State{pending_orientation: nil} = state), do: {:ok, state}

  # An identity pending orientation has no pixel work: clear it without forcing a
  # materialize so the streaming (no-rotation) fast path is preserved — the delivery
  # backstop still materializes if nothing else did.
  defp flush_if_pending(%State{pending_orientation: %PendingOrientation{} = po} = state) do
    if PendingOrientation.identity?(po) do
      {:ok, %State{state | pending_orientation: nil}}
    else
      case Materializer.materialize(state) do
        {:ok, %State{} = state} -> {:ok, state}
        {:error, reason} -> {:error, {:materialize_error, reason}}
      end
    end
  end

  # User rotate/flip fold into the pending orientation instead of emitting an
  # executable op; the flush replays them with EXIF auto-orient late.
  defp execute_operation(%PlanRotate{angle: angle}, %State{} = state, _ctx, _opts) do
    po = state.pending_orientation || %PendingOrientation{}
    {:ok, %State{state | pending_orientation: PendingOrientation.fold_rotate(po, angle)}}
  end

  defp execute_operation(%PlanFlip{axis: axis}, %State{} = state, _ctx, _opts) do
    po = state.pending_orientation || %PendingOrientation{}
    {:ok, %State{state | pending_orientation: PendingOrientation.fold_flip(po, axis)}}
  end

  # Region crop runs literally on oriented pixels: flush pending first.
  defp execute_operation(
         %CropRegion{} = operation,
         %State{pending_orientation: po} = state,
         ctx,
         opts
       )
       when not is_nil(po) do
    with {:ok, %State{} = state} <- flush_if_pending(state) do
      execute_operation(operation, %State{state | pending_orientation: nil}, ctx, opts)
    end
  end

  # Gravity crop: compensate the built %Crop{} gravity (type + offsets) and swap
  # its dims for a quarter turn, so cropping in the storage frame then flushing
  # matches cropping in the oriented frame.
  defp execute_operation(
         %CropGuided{} = operation,
         %State{pending_orientation: po} = state,
         ctx,
         opts
       )
       when not is_nil(po) do
    cond do
      PendingOrientation.identity?(po) ->
        run_executable(operation, state, ctx, opts)

      # Smart/detect crops materialize, so the auto-flush at the materializing crop
      # fires first and the crop sees oriented (display-frame) pixels — emit literal.
      materializing_gravity?(operation.guide) ->
        run_executable(operation, state, ctx, opts)

      true ->
        # Inlined so compensation sits between translate and execute.
        executable =
          operation
          |> executable_operations(state, ctx)
          |> Enum.map(&compensate_crop(&1, po))

        Chain.execute(state, executable, opts)
    end
  end

  # Resize: swap requested dims for a quarter turn, run, then flush so the cover
  # result-crop and tail are post-flush/literal.
  defp execute_operation(
         %PlanResize{} = operation,
         %State{pending_orientation: po} = state,
         ctx,
         opts
       )
       when not is_nil(po) do
    if PendingOrientation.identity?(po) do
      run_executable(operation, state, ctx, opts)
    else
      # Inlined so compensation sits between translate and execute.
      executable =
        operation
        |> executable_operations(state, ctx)
        |> compensate_resize(po)

      with {:ok, state} <- Chain.execute(state, executable, opts) do
        flush_if_pending(state)
      end
    end
  end

  defp execute_operation(operation, %State{} = state, context, opts) do
    run_executable(operation, state, context, opts)
  end

  defp run_executable(operation, %State{} = state, context, opts) do
    operation
    |> executable_operations(state, context)
    |> then(&Chain.execute(state, &1, opts))
  end

  defp materializing_gravity?(:smart), do: true
  defp materializing_gravity?({:smart, _}), do: true
  defp materializing_gravity?({:detect, _}), do: true
  defp materializing_gravity?(_other), do: false

  defp compensate_crop(
         %Crop{crop_from: :gravity, gravity: gravity} = crop,
         %PendingOrientation{} = po
       ) do
    if materializing_gravity?(gravity) do
      # Smart/detect crops materialize; the auto-flush fires first so they run on
      # display-frame pixels. Leave them literal (no compensation).
      crop
    else
      # The executable crop carries offsets in their tagged unit form
      # ({:pixels, v} | {:scale, v} | {:scale, n, d} | {:percent, v} | number).
      # Orientation.compensate_gravity_for/2 ports imgproxy's RotateAndFlip, which
      # operates on the bare float offset (gravity.go uses a single float64 X/Y).
      # Unwrap to the bare magnitude, compensate, then re-wrap — and on a quarter
      # turn the X/Y *values* swap (g.X, g.Y = g.Y, ...), so the unit wrappers swap
      # with them. The parser emits both offsets in the same unit, but tracking the
      # wrapper per-axis keeps the swap correct even if they ever differ.
      {x_unit, x_value} = split_offset(crop.x_offset)
      {y_unit, y_value} = split_offset(crop.y_offset)

      {gravity, x_value, y_value} =
        Orientation.compensate_gravity_for({gravity, x_value, y_value}, po)

      {x_unit, y_unit} =
        if PendingOrientation.quarter_turn?(po), do: {y_unit, x_unit}, else: {x_unit, y_unit}

      crop = %Crop{
        crop
        | gravity: gravity,
          x_offset: x_unit.(x_value),
          y_offset: y_unit.(y_value)
      }

      if PendingOrientation.quarter_turn?(po) do
        %Crop{crop | width: crop.height, height: crop.width}
      else
        crop
      end
    end
  end

  defp compensate_crop(%Crop{} = crop, %PendingOrientation{}), do: crop

  # Split a tagged crop offset into {rewrap_fun, bare_value}. Orientation
  # compensation negates/swaps the magnitude; the rewrap restores the unit so the
  # executable crop still resolves the offset against the right bounds/scale.
  defp split_offset({:pixels, value}), do: {&{:pixels, &1}, value * 1.0}
  defp split_offset({:scale, value}), do: {&{:scale, &1}, value * 1.0}
  defp split_offset({:scale, num, den}), do: {&{:scale, &1}, num / den}
  defp split_offset({:percent, value}), do: {&{:percent, &1 * 100}, value / 100}
  defp split_offset(value) when is_number(value), do: {& &1, value * 1.0}

  # Compensate a resize expansion in the storage frame. The cover/auto expansion is
  # `[%Resize{}, %Crop{}]`; the resize's requested dims swap on a quarter turn, and
  # the trailing cover result-crop is compensated like any gravity crop (dim swap +
  # gravity/offset remap). The whole expansion runs pre-flush; the caller flushes
  # right after, leaving the tail post-flush/literal.
  defp compensate_resize(operations, %PendingOrientation{} = po) do
    Enum.map(operations, fn
      %Resize{} = resize ->
        if PendingOrientation.quarter_turn?(po), do: Orientation.swap_resize(resize), else: resize

      %Crop{} = crop ->
        compensate_crop(crop, po)

      other ->
        other
    end)
  end

  defp update_execution_context(%PlanResize{} = operation, %State{} = state, context) do
    scale = resize_padding_scale(operation, state, :resize)
    canvas_preserving_scale = resize_padding_scale(operation, state, :canvas_preserving)

    %{
      context
      | effective_padding_scale: scale,
        canvas_preserving_padding_scale: canvas_preserving_scale
    }
  end

  defp update_execution_context(_operation, %State{}, context), do: context

  defp executable_operations(%PlanResize{mode: :fit} = operation, %State{}, _context) do
    [resize_from(operation, :fit)]
  end

  defp executable_operations(%PlanResize{mode: :cover} = operation, %State{} = state, _context) do
    operation
    |> resize_from(:cover)
    |> cover_resize_and_crop(
      state,
      tagged_executable_gravity(operation.guide),
      {operation.x_offset, operation.y_offset}
    )
  end

  defp executable_operations(%PlanResize{mode: :stretch} = operation, %State{}, _context) do
    [resize_from(operation, :stretch)]
  end

  defp executable_operations(%PlanResize{mode: :auto} = operation, %State{} = state, _context) do
    branch = plan_resize_branch(operation, state)
    resize = resize_from(operation, branch)

    tagged_executable_resize_operations(branch, resize, operation, state)
  end

  defp executable_operations(%CropGuided{} = operation, %State{}, _context) do
    [
      %Crop{
        width: crop_dimension(operation.width),
        height: crop_dimension(operation.height),
        crop_from: :gravity,
        gravity: tagged_executable_gravity(operation.guide),
        x_offset: operation.x_offset,
        y_offset: operation.y_offset,
        aspect_ratio: operation.aspect_ratio,
        enlarge: operation.enlarge
      }
    ]
  end

  defp executable_operations(%CropRegion{} = operation, %State{}, _context) do
    [
      %Crop{
        width: crop_dimension(operation.width),
        height: crop_dimension(operation.height),
        crop_from: %{
          left: crop_coordinate(operation.x),
          top: crop_coordinate(operation.y)
        }
      }
    ]
  end

  defp executable_operations(%Canvas{} = operation, %State{}, _context) do
    width = canvas_dimension(operation.width)
    height = canvas_dimension(operation.height)

    [
      %ExtendCanvas{
        rule: canvas_rule(width, height),
        gravity: tagged_executable_gravity(operation.placement),
        x_offset: operation.x_offset,
        y_offset: operation.y_offset,
        background: executable_fill(operation.fill)
      }
    ]
  end

  defp executable_operations(%PlanPadding{} = operation, %State{} = state, context) do
    scale = effective_padding_scale(operation, state, context)

    [
      %Padding{
        top: scaled_padding_side(operation.top, scale),
        right: scaled_padding_side(operation.right, scale),
        bottom: scaled_padding_side(operation.bottom, scale),
        left: scaled_padding_side(operation.left, scale),
        fill: executable_fill(operation.fill)
      }
    ]
  end

  defp executable_operations(%PlanBackground{} = operation, %State{}, _context) do
    [%Background{color: Color.to_rgba_list(operation.color)}]
  end

  defp executable_operations(%PlanNormalizeColorProfile{}, %State{}, _context),
    do: [%NormalizeColorProfile{}]

  defp executable_operations(%PlanBlur{sigma: sigma}, %State{}, _context),
    do: [%Blur{sigma: sigma}]

  defp executable_operations(%PlanSharpen{sigma: sigma}, %State{}, _context),
    do: [%Sharpen{sigma: sigma}]

  defp executable_operations(%PlanPixelate{size: size}, %State{}, _context),
    do: [%Pixelate{size: size}]

  defp executable_operations(%PlanMonochrome{} = operation, %State{}, _context) do
    [
      %Monochrome{
        intensity: tagged_ratio_to_float(operation.intensity),
        color: Color.to_rgb_list(operation.color)
      }
    ]
  end

  defp executable_operations(%PlanDuotone{} = operation, %State{}, _context) do
    [
      %Duotone{
        intensity: tagged_ratio_to_float(operation.intensity),
        shadow: Color.to_rgb_list(operation.shadow),
        highlight: Color.to_rgb_list(operation.highlight)
      }
    ]
  end

  defp executable_operations(%PlanBrightness{value: value}, %State{}, _context),
    do: [%Brightness{value: value}]

  defp executable_operations(%PlanContrast{value: value}, %State{}, _context),
    do: [%Contrast{value: value}]

  defp executable_operations(%PlanSaturation{value: value}, %State{}, _context),
    do: [%Saturation{value: value}]

  defp tagged_executable_resize_operations(
         :cover,
         %Resize{} = resize,
         operation,
         %State{} = state
       ) do
    cover_resize_and_crop(
      resize,
      state,
      tagged_executable_gravity(operation.guide),
      {operation.x_offset, operation.y_offset}
    )
  end

  defp tagged_executable_resize_operations(:fit, %Resize{} = resize, _operation, %State{}) do
    [resize]
  end

  defp cover_resize_and_crop(%Resize{} = resize, %State{} = state, gravity, {x_offset, y_offset}) do
    {src_w, src_h} = State.effective_source_dims(state)

    dimensions =
      Resize.resolve_dimensions(resize,
        source_width: src_w,
        source_height: src_h
      )

    [
      resize,
      %Crop{
        width: dimensions.target_width,
        height: dimensions.target_height,
        crop_from: :gravity,
        gravity: gravity,
        x_offset: x_offset,
        y_offset: y_offset,
        offset_scale: dimensions.effective_dpr
      }
    ]
  end

  defp resize_from(operation, mode) do
    %Resize{
      mode: resize_mode(mode),
      width: tagged_executable_resize_dimension(operation.width),
      height: tagged_executable_resize_dimension(operation.height),
      min_width: tagged_executable_optional_resize_dimension(operation.min_width),
      min_height: tagged_executable_optional_resize_dimension(operation.min_height),
      zoom_x: operation.zoom_x,
      zoom_y: operation.zoom_y,
      dpr: tagged_dpr_float(operation.dpr),
      enlarge: operation.enlargement == :allow
    }
  end

  defp resize_mode(:cover), do: :fill
  defp resize_mode(:fit), do: :fit
  defp resize_mode(:stretch), do: :force

  defp tagged_executable_resize_dimension(:auto), do: :auto
  defp tagged_executable_resize_dimension({:px, value}), do: {:pixels, value}

  defp tagged_executable_optional_resize_dimension(nil), do: nil

  defp tagged_executable_optional_resize_dimension(dimension),
    do: tagged_executable_resize_dimension(dimension)

  defp crop_dimension(:full_axis), do: :auto
  defp crop_dimension({:px, value}), do: {:pixels, value}
  defp crop_dimension({:ratio, numerator, denominator}), do: {:scale, numerator, denominator}

  defp crop_coordinate({:px, value}), do: {:pixels, value}
  defp crop_coordinate({:ratio, numerator, denominator}), do: {:scale, numerator, denominator}

  defp canvas_dimension(:auto), do: :auto
  defp canvas_dimension({:px, value}), do: {:pixels, value}
  defp canvas_dimension({:ratio, numerator, denominator}), do: {:ratio, numerator / denominator}

  defp canvas_rule({:ratio, width}, {:ratio, height}), do: {:aspect_ratio, {width, height}}
  defp canvas_rule(width, height), do: {:dimensions, width, height}

  defp executable_fill(:transparent), do: :transparent

  defp executable_fill({:solid, %Color{alpha: {:ratio, numerator, denominator}} = color})
       when numerator == denominator do
    {:color, Color.to_rgb_list(color)}
  end

  defp executable_fill({:solid, %Color{} = color}), do: {:color, Color.to_rgba_list(color)}

  defp effective_padding_scale(
         %PlanPadding{pixel_ratio: {:effective, _fallback, :resize}},
         %State{},
         %{effective_padding_scale: scale}
       )
       when is_number(scale),
       do: scale

  defp effective_padding_scale(
         %PlanPadding{pixel_ratio: {:effective, _fallback, :canvas_preserving}},
         %State{},
         %{canvas_preserving_padding_scale: scale}
       )
       when is_number(scale),
       do: scale

  defp effective_padding_scale(
         %PlanPadding{pixel_ratio: {:ratio, numerator, denominator}},
         %State{},
         _context
       ),
       do: numerator / denominator

  defp effective_padding_scale(
         %PlanPadding{pixel_ratio: {:effective, {:ratio, numerator, denominator}, _mode}},
         %State{},
         _context
       ),
       do: numerator / denominator

  defp resize_padding_scale(%PlanResize{enlargement: :allow} = operation, %State{}, _mode),
    do: tagged_dpr_float(operation.dpr)

  defp resize_padding_scale(%PlanResize{} = operation, %State{} = state, mode) do
    {src_w, src_h} = State.effective_source_dims(state)
    requested_scale = tagged_dpr_float(operation.dpr)
    branch = plan_resize_branch(operation, state)
    resize = resize_from(operation, branch)

    base =
      %{resize | dpr: 1.0, enlarge: true}
      |> Resize.resolve_dimensions(
        source_width: src_w,
        source_height: src_h
      )

    max_without_enlarge = max_padding_scale_without_enlarge(base, state)
    compensated = compensate_no_enlarge_padding_scale(requested_scale, max_without_enlarge, mode)

    clamp_padding_scale(compensated, max_without_enlarge)
  end

  defp max_padding_scale_without_enlarge(
         %{requested_width: :auto, requested_height: :auto},
         %State{}
       ),
       do: :unbounded

  defp max_padding_scale_without_enlarge(
         %{requested_width: width, requested_height: height},
         %State{} = state
       ) do
    {src_w, src_h} = State.effective_source_dims(state)
    min(src_w / width, src_h / height)
  end

  defp compensate_no_enlarge_padding_scale(requested_scale, :unbounded, _mode),
    do: requested_scale

  # Canvas-preserving composition keeps padding tied to the clamped resize scale
  # instead of compensating DPR upward when enlargement is disabled.
  defp compensate_no_enlarge_padding_scale(
         requested_scale,
         _max_without_enlarge,
         :canvas_preserving
       ),
       do: requested_scale

  defp compensate_no_enlarge_padding_scale(requested_scale, max_without_enlarge, :resize)
       when max_without_enlarge < 1.0 do
    requested_scale / max_without_enlarge
  end

  defp compensate_no_enlarge_padding_scale(requested_scale, _max_without_enlarge, _mode),
    do: requested_scale

  defp clamp_padding_scale(scale, :unbounded), do: scale

  defp clamp_padding_scale(scale, max_without_enlarge),
    do: min(scale, max(max_without_enlarge, 1.0))

  defp plan_resize_branch(%PlanResize{mode: :fit}, %State{}), do: :fit
  defp plan_resize_branch(%PlanResize{mode: :cover}, %State{}), do: :cover
  defp plan_resize_branch(%PlanResize{mode: :stretch}, %State{}), do: :stretch

  defp plan_resize_branch(%PlanResize{mode: :auto} = operation, %State{} = state) do
    {src_w, src_h} = State.effective_source_dims(state)

    resize_auto_branch(
      src_w,
      src_h,
      tagged_logical_pixels(operation.width),
      tagged_logical_pixels(operation.height)
    )
  end

  defp scaled_padding_side({:px, value}, scale), do: round_half_to_even(value * scale)

  defp round_half_to_even(value) do
    floor = Float.floor(value)
    fraction = value - floor

    cond do
      fraction < 0.5 -> trunc(floor)
      fraction > 0.5 -> trunc(floor) + 1
      rem(trunc(floor), 2) == 0 -> trunc(floor)
      true -> trunc(floor) + 1
    end
  end

  defp tagged_executable_gravity(:center), do: {:anchor, :center, :center}
  defp tagged_executable_gravity(:top_left), do: {:anchor, :left, :top}
  defp tagged_executable_gravity(:top), do: {:anchor, :center, :top}
  defp tagged_executable_gravity(:top_right), do: {:anchor, :right, :top}
  defp tagged_executable_gravity(:left), do: {:anchor, :left, :center}
  defp tagged_executable_gravity(:right), do: {:anchor, :right, :center}
  defp tagged_executable_gravity(:bottom_left), do: {:anchor, :left, :bottom}
  defp tagged_executable_gravity(:bottom), do: {:anchor, :center, :bottom}
  defp tagged_executable_gravity(:bottom_right), do: {:anchor, :right, :bottom}
  defp tagged_executable_gravity({:anchor, x, y}), do: {:anchor, x, y}

  defp tagged_executable_gravity({:focal, x, y}),
    do: {:fp, tagged_ratio_to_float(x), tagged_ratio_to_float(y)}

  defp tagged_executable_gravity(:smart), do: :smart
  defp tagged_executable_gravity({:smart, :face_assist}), do: {:smart, :face_assist}
  defp tagged_executable_gravity({:detect, {spec, weights}}), do: {:detect, {spec, weights}}

  defp tagged_logical_pixels({:px, value}), do: value
  defp tagged_logical_pixels(_dimension), do: :unknown

  defp tagged_dpr_float({:ratio, numerator, denominator}), do: numerator / denominator

  defp tagged_ratio_to_float({:ratio, numerator, denominator}), do: numerator / denominator

  defp resize_auto_branch(current_width, current_height, target_width, target_height) do
    current_orientation = orientation(current_width, current_height)
    target_orientation = orientation(target_width, target_height)

    auto_branch(current_orientation, target_orientation)
  end

  defp auto_branch(:unknown, _target_orientation), do: :fit
  defp auto_branch(_current_orientation, :unknown), do: :fit
  defp auto_branch(orientation, orientation), do: :cover
  defp auto_branch(_current_orientation, _target_orientation), do: :fit

  defp orientation(width, height)
       when is_integer(width) and is_integer(height) and width > height,
       do: :landscape

  defp orientation(width, height)
       when is_integer(width) and is_integer(height) and width < height,
       do: :portrait

  defp orientation(width, height)
       when is_integer(width) and is_integer(height) and width == height,
       do: :square

  defp orientation(_width, _height), do: :unknown
end
