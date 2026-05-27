defmodule ImagePipe.Parser.Imgproxy.Options do
  @moduledoc false

  alias ImagePipe.Parser.Imgproxy.OptionGrammar
  alias ImagePipe.Parser.Imgproxy.ParsedRequest
  alias ImagePipe.Parser.Imgproxy.PipelineRequest
  alias ImagePipe.Parser.Imgproxy.Presets
  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.Orientation

  @type request_options :: %{
          pipelines: [PipelineRequest.t()],
          output: ParsedRequest.output_request(),
          policy: ParsedRequest.policy_request(),
          cache: ParsedRequest.cache_request(),
          response: ParsedRequest.response_request()
        }

  @spec parse([String.t()], Presets.t(), keyword()) :: {:ok, request_options()} | {:error, term()}
  def parse(option_segments, %Presets{} = presets, defaults \\ []) when is_list(defaults) do
    with {:ok, options} <- initial_request_options() |> apply_default_preset(presets),
         {:ok, options} <- apply_segments(option_segments, options, presets, []),
         {:ok, options} <- drain_queued_preset_groups(options, presets) do
      request =
        options
        |> finalize_request_options()
        |> apply_request_defaults(defaults)
        |> Map.take([:pipelines, :output, :policy, :cache, :response])

      {:ok, request}
    end
  end

  defp initial_request_options do
    %{
      current_pipeline: %PipelineRequest{},
      queued_preset_groups: [],
      pipelines: [],
      output: ParsedRequest.output_request(),
      policy: ParsedRequest.policy_request(),
      cache: ParsedRequest.cache_request(),
      response: ParsedRequest.response_request()
    }
  end

  defp finalize_request_options(options) do
    options = finalize_current_pipeline(options)
    pipelines = Enum.reverse(options.pipelines)

    pipelines =
      if pipelines == [] do
        [%PipelineRequest{}]
      else
        pipelines
      end

    %{
      options
      | current_pipeline: %PipelineRequest{},
        queued_preset_groups: [],
        pipelines: pipelines
    }
  end

  defp apply_default_preset(options, %Presets{} = presets) do
    case Presets.fetch(presets, "default") do
      {:ok, groups} -> apply_preset_groups(groups, options, presets, ["default"])
      :error -> {:ok, options}
    end
  end

  defp apply_segments(segments, options, presets, active_presets) do
    Enum.reduce_while(segments, {:ok, options}, fn segment, {:ok, options} ->
      case apply_segment(segment, options, presets, active_presets) do
        {:ok, options} -> {:cont, {:ok, options}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp apply_segment("-", options, presets, _active_presets) do
    options
    |> finalize_current_pipeline()
    |> apply_next_queued_preset_group(presets)
  end

  defp apply_segment(segment, options, presets, active_presets) do
    case OptionGrammar.parse(segment) do
      {:ok, {:preset, names}} ->
        apply_preset_names(names, options, presets, active_presets)

      {:ok, {:pipeline, assignments}} ->
        {:ok, update_current_pipeline(options, assignments)}

      {:ok, {:output, assignments}} ->
        {:ok, update_output(options, assignments)}

      {:ok, {:cache, assignments}} ->
        {:ok, update_cache(options, assignments)}

      {:ok, {:policy, assignments}} ->
        {:ok, update_policy(options, assignments)}

      {:ok, {:response, assignments}} ->
        {:ok, update_response(options, assignments)}

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_preset_names(names, options, presets, active_presets) do
    Enum.reduce_while(names, {:ok, options}, fn name, {:ok, options} ->
      case apply_preset(name, options, presets, active_presets) do
        {:ok, options} -> {:cont, {:ok, options}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp apply_preset(name, options, presets, active_presets) do
    case name in active_presets do
      true ->
        {:ok, options}

      false ->
        case Presets.fetch(presets, name) do
          {:ok, groups} -> apply_preset_groups(groups, options, presets, [name | active_presets])
          :error -> {:error, {:unknown_preset, name}}
        end
    end
  end

  defp apply_preset_groups([first_group | remaining_groups], options, presets, active_presets) do
    with {:ok, options} <- apply_segments(first_group, options, presets, active_presets) do
      {:ok, enqueue_preset_groups(options, remaining_groups, active_presets)}
    end
  end

  defp enqueue_preset_groups(options, [], _active_presets), do: options

  defp enqueue_preset_groups(%{queued_preset_groups: queue} = options, groups, active_presets) do
    levels = Enum.map(groups, &[{&1, active_presets}])
    %{options | queued_preset_groups: merge_queued_preset_levels(queue, levels)}
  end

  defp apply_next_queued_preset_group(%{queued_preset_groups: []} = options, _presets),
    do: {:ok, options}

  defp apply_next_queued_preset_group(
         %{queued_preset_groups: [entries | queue]} = options,
         presets
       ) do
    %{options | queued_preset_groups: queue}
    |> apply_queued_preset_entries(entries, presets)
  end

  defp apply_queued_preset_entries(options, entries, presets) do
    Enum.reduce_while(entries, {:ok, options}, fn {segments, active_presets}, {:ok, options} ->
      case apply_segments(segments, options, presets, active_presets) do
        {:ok, options} -> {:cont, {:ok, options}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp merge_queued_preset_levels([], levels), do: levels
  defp merge_queued_preset_levels(queue, []), do: queue

  defp merge_queued_preset_levels([queue_level | queue], [new_level | levels]) do
    [queue_level ++ new_level | merge_queued_preset_levels(queue, levels)]
  end

  defp drain_queued_preset_groups(%{queued_preset_groups: []} = options, _presets),
    do: {:ok, options}

  defp drain_queued_preset_groups(options, presets) do
    with {:ok, options} <-
           options
           |> finalize_current_pipeline()
           |> apply_next_queued_preset_group(presets) do
      drain_queued_preset_groups(options, presets)
    end
  end

  defp finalize_current_pipeline(%{current_pipeline: pipeline, pipelines: pipelines} = options) do
    if pipeline_empty?(pipeline) do
      %{options | current_pipeline: %PipelineRequest{}}
    else
      %{options | current_pipeline: %PipelineRequest{}, pipelines: [pipeline | pipelines]}
    end
  end

  defp update_current_pipeline(%{current_pipeline: pipeline} = options, assignments) do
    pipeline =
      Enum.reduce(assignments, pipeline, fn
        {:orientation, orientation_assignments}, pipeline ->
          %{
            pipeline
            | orientation: struct!(pipeline.orientation, orientation_assignments),
              orientation_requested: true,
              auto_rotate_requested:
                pipeline.auto_rotate_requested or
                  Keyword.has_key?(orientation_assignments, :auto_orient)
          }

        {:padding, padding_args}, pipeline ->
          apply_padding(pipeline, padding_args)

        {:background_color, color}, pipeline ->
          apply_background_color(pipeline, color)

        {:background_alpha, alpha}, pipeline ->
          apply_background_alpha(pipeline, alpha)

        assignment, pipeline ->
          struct!(pipeline, [assignment])
      end)

    %{options | current_pipeline: pipeline}
  end

  defp update_output(%{output: output} = options, assignments) do
    output =
      Enum.reduce(assignments, output, fn
        {:format_qualities, format_qualities}, output ->
          %{
            output
            | format_qualities: Map.merge(output.format_qualities, format_qualities)
          }

        assignment, output ->
          merge_request_map(output, [assignment])
      end)

    %{options | output: output}
  end

  defp update_cache(%{cache: cache} = options, assignments) do
    %{options | cache: merge_request_map(cache, assignments)}
  end

  defp update_policy(%{policy: policy} = options, assignments) do
    %{options | policy: merge_request_map(policy, assignments)}
  end

  defp update_response(%{response: response} = options, assignments) do
    %{options | response: merge_request_map(response, assignments)}
  end

  defp merge_request_map(request, assignments) do
    attrs = Map.new(assignments)
    unknown_keys = Map.keys(attrs) -- Map.keys(request)

    case unknown_keys do
      [] -> Map.merge(request, attrs)
      keys -> raise ArgumentError, "unknown request keys: #{inspect(keys)}"
    end
  end

  defp pipeline_empty?(%PipelineRequest{
         width: nil,
         height: nil,
         min_width: nil,
         min_height: nil,
         resizing_type: :fit,
         zoom_x: nil,
         zoom_y: nil,
         dpr: nil,
         enlarge: false,
         extend: false,
         extend_requested: false,
         extend_gravity: nil,
         extend_x_offset: nil,
         extend_y_offset: nil,
         extend_aspect_ratio: nil,
         padding_top: 0,
         padding_right: 0,
         padding_bottom: 0,
         padding_left: 0,
         background_color: nil,
         background_alpha: nil,
         gravity: {:anchor, :center, :center},
         gravity_x_offset: gravity_x_offset,
         gravity_y_offset: gravity_y_offset,
         crop: nil,
         orientation_requested: false,
         orientation: %Orientation{} = orientation
       })
       when gravity_x_offset in [{:pixels, 0.0}, 0.0] and
              gravity_y_offset in [{:pixels, 0.0}, 0.0] do
    orientation == %Orientation{}
  end

  defp pipeline_empty?(%PipelineRequest{}), do: false

  defp apply_request_defaults(%{pipelines: pipelines} = options, defaults) do
    auto_rotate? = effective_auto_rotate(pipelines, Keyword.get(defaults, :auto_rotate, false))

    pipelines =
      pipelines
      |> Enum.map(&consume_auto_rotate_request/1)
      |> apply_auto_rotate_to_first_pipeline(auto_rotate?)
      |> reject_empty_pipelines()

    %{options | pipelines: pipelines}
  end

  defp effective_auto_rotate(pipelines, default) do
    Enum.reduce(pipelines, default, fn
      %PipelineRequest{
        auto_rotate_requested: true,
        orientation: %Orientation{auto_orient: auto_rotate?}
      },
      _auto_rotate? ->
        auto_rotate?

      %PipelineRequest{}, auto_rotate? ->
        auto_rotate?
    end)
  end

  defp consume_auto_rotate_request(
         %PipelineRequest{orientation: %Orientation{} = orientation} = pipeline
       ) do
    orientation = %Orientation{orientation | auto_orient: false}

    %{
      pipeline
      | orientation: orientation,
        orientation_requested: orientation_requested?(orientation),
        auto_rotate_requested: false
    }
  end

  defp apply_auto_rotate_to_first_pipeline(pipelines, false), do: pipelines

  defp apply_auto_rotate_to_first_pipeline(
         [%PipelineRequest{orientation: %Orientation{} = orientation} = pipeline | pipelines],
         true
       ) do
    pipeline = %{
      pipeline
      | orientation: %Orientation{orientation | auto_orient: true},
        orientation_requested: true
    }

    [pipeline | pipelines]
  end

  defp reject_empty_pipelines(pipelines) do
    case Enum.reject(pipelines, &pipeline_empty?/1) do
      [] -> [%PipelineRequest{}]
      pipelines -> pipelines
    end
  end

  defp orientation_requested?(%Orientation{} = orientation), do: orientation != %Orientation{}

  defp apply_padding(%PipelineRequest{} = pipeline, values) do
    top = padding_value(Enum.at(values, 0), pipeline.padding_top)
    right = padding_value(Enum.at(values, 1), fallback_padding(top, pipeline.padding_right))
    bottom = padding_value(Enum.at(values, 2), fallback_padding(top, pipeline.padding_bottom))
    left = padding_value(Enum.at(values, 3), fallback_padding(right, pipeline.padding_left))

    %{
      pipeline
      | padding_top: top,
        padding_right: right,
        padding_bottom: bottom,
        padding_left: left
    }
  end

  defp padding_value(nil, current), do: current
  defp padding_value(:unset, current), do: current
  defp padding_value(value, _current) when is_integer(value), do: value

  defp fallback_padding(:unset, current), do: current
  defp fallback_padding(value, _current), do: value

  defp apply_background_color(%PipelineRequest{} = pipeline, nil) do
    %{pipeline | background_color: nil, background_alpha: nil}
  end

  defp apply_background_color(%PipelineRequest{} = pipeline, %Color{} = color) do
    %{pipeline | background_color: color_with_alpha!(color, pipeline.background_alpha)}
  end

  defp apply_background_alpha(%PipelineRequest{} = pipeline, alpha) do
    color =
      pipeline.background_color
      |> default_background_color()
      |> color_with_alpha!(alpha)

    %{pipeline | background_color: color, background_alpha: alpha}
  end

  defp default_background_color(nil) do
    {:ok, black} = Color.rgb(0, 0, 0)
    black
  end

  defp default_background_color(%Color{} = color), do: color

  defp color_with_alpha!(%Color{} = color, nil), do: color

  defp color_with_alpha!(%Color{} = color, alpha) do
    {:ok, color} = Color.with_alpha(color, alpha)
    color
  end
end
