defmodule ImagePipe.Request.RenderRunner do
  @moduledoc """
  Request-layer orchestration for non-image renders. Decodes the source to the
  needed depth (Phase 1: header only) and invokes the renderer via the neutral
  `ImagePipe.Renderer` facade, returning a complete body. Never starts a
  SourceSession/Producer and never constructs an `%Output.Resolved{}`.
  """

  alias ImagePipe.Plan
  alias ImagePipe.Plan.RenderContext
  alias ImagePipe.Plan.SourceInfo
  alias ImagePipe.Renderer
  alias ImagePipe.Request.Processor
  alias ImagePipe.Source
  alias ImagePipe.Telemetry
  alias Vix.Vips.Image, as: VipsImage

  @spec run(Plan.t(), Source.Resolved.t(), keyword()) ::
          {:ok, {content_type :: String.t(), body :: iodata()}} | {:error, term()}
  def run(%Plan{render: %Plan.Render{}} = plan, %Source.Resolved{} = resolved_source, opts) do
    Telemetry.span(Telemetry.telemetry_opts(opts), [:render], %{representation: :json}, fn ->
      result = do_run(plan, resolved_source, opts)
      {result, render_stop_metadata(result)}
    end)
  end

  defp do_run(plan, resolved_source, opts) do
    with {:ok, decoded} <-
           Processor.fetch_decode_validate_source_with_source_format(plan, resolved_source, opts) do
      info = build_source_info(decoded, byte_size_of(resolved_source))
      Renderer.run(plan.render, %RenderContext{info: info}, opts)
    end
  end

  @spec build_source_info(map(), non_neg_integer() | nil) :: SourceInfo.t()
  def build_source_info(decoded, byte_size) do
    {width, height} = decoded.original_dims

    %SourceInfo{
      format: decoded.source_format,
      width: width,
      height: height,
      orientation: orientation(decoded.image),
      byte_size: byte_size
    }
  end

  defp orientation(image) do
    case VipsImage.header_value(image, "orientation") do
      {:ok, value} when is_integer(value) and value in 1..8 -> value
      _ -> 1
    end
  end

  # Phase 1: byte size is omitted (a later refinement may thread a cheap
  # Content-Length / File.stat). Never download the body just to compute size.
  defp byte_size_of(%Source.Resolved{}), do: nil

  defp render_stop_metadata({:ok, {content_type, _body}}),
    do: %{result: :ok, content_type: content_type}

  defp render_stop_metadata({:error, reason}),
    do: %{result: :render_error, error: inspect(reason)}
end
