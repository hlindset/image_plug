defmodule ImagePlug do
  @moduledoc """
  Plug entry point for fetching, transforming, caching, and encoding images.
  """

  use Boundary,
    deps: [
      ImagePlug.Error,
      ImagePlug.Parser,
      ImagePlug.Plan,
      ImagePlug.Request,
      ImagePlug.Response,
      ImagePlug.Source,
      ImagePlug.Telemetry,
      ImagePlug.Transform
    ],
    exports: []

  @behaviour Plug

  alias ImagePlug.Error
  alias ImagePlug.Parser.Imgproxy
  alias ImagePlug.Plan
  alias ImagePlug.Request.Options
  alias ImagePlug.Request.Runner
  alias ImagePlug.Response.Sender
  alias ImagePlug.Source
  alias ImagePlug.Telemetry
  alias ImagePlug.Transform

  @impl Plug
  def init(opts) do
    opts
    |> Options.validate!()
    |> validate_parser_options()
  end

  @impl Plug
  def call(%Plug.Conn{} = conn, opts) do
    telemetry_opts = Telemetry.telemetry_opts(opts)

    Telemetry.span(telemetry_opts, [:request], request_metadata(conn, opts), fn ->
      {conn, metadata} = do_call(conn, opts)
      {conn, Map.put(metadata, :status, conn.status)}
    end)
  end

  defp do_call(%Plug.Conn{} = conn, opts) do
    parser = Keyword.fetch!(opts, :parser)

    with {:ok, %Plan{} = plan} <- parse(conn, parser, opts),
         {:ok, %Plan{} = plan} <- validate_client_plan(plan),
         {:ok, %Source.Resolved{} = resolved_source} <-
           Source.resolve(plan.source, opts, Options.source_runtime_opts(opts)) do
      result = Runner.run(conn, plan, resolved_source, opts)

      {conn, send_metadata} =
        send_response(conn, opts, request_result(result), fn ->
          Sender.send_result(conn, result, opts)
        end)

      {conn, request_stop_metadata(result, send_metadata)}
    else
      {:error, {:parser, error}} ->
        {conn, _send_metadata} =
          send_response(conn, opts, :parser_error, fn -> parser.handle_error(conn, error) end)

        {conn, %{result: :parser_error}}

      {:error, {:plan_validation, error}} ->
        result = {:error, {:processing, error, []}}

        {conn, _send_metadata} =
          send_response(conn, opts, :plan_error, fn -> Sender.send_result(conn, result, opts) end)

        {conn, %{result: :plan_error, error: Error.tag(error)}}

      {:error, {:source, error}} ->
        {conn, _send_metadata} =
          send_response(conn, opts, :source_error, fn -> Sender.send_source_error(conn, error) end)

        {conn, %{result: :source_error, error: Error.tag(error)}}
    end
  end

  defp parse(conn, parser, opts) do
    Telemetry.span(Telemetry.telemetry_opts(opts), [:parse], request_metadata(conn, opts), fn ->
      result = parser.parse(conn, opts) |> wrap_parser_error()

      {result, result_metadata(result)}
    end)
  end

  defp send_response(_conn, opts, result, fun) do
    Telemetry.span(Telemetry.telemetry_opts(opts), [:send], %{result: result}, fn ->
      sent_conn = fun.()
      metadata = send_stop_metadata(sent_conn, result)

      {{sent_conn, metadata}, metadata}
    end)
  end

  defp validate_client_plan(%Plan{} = plan) do
    with {:ok, _pipelines} <- Transform.validate_prefetch_safe_plan(plan) do
      {:ok, plan}
    end
    |> wrap_plan_validation_error()
  end

  defp wrap_parser_error({:error, _} = error), do: {:error, {:parser, error}}
  defp wrap_parser_error(result), do: result

  defp wrap_plan_validation_error({:error, error}), do: {:error, {:plan_validation, error}}
  defp wrap_plan_validation_error(result), do: result

  defp request_metadata(conn, opts) do
    %{
      parser: Keyword.fetch!(opts, :parser),
      request_method: conn.method
    }
  end

  defp send_stop_metadata(%Plug.Conn{} = conn, result) do
    %{
      result: Map.get(conn.private, :image_plug_send_result, result),
      status: conn.status
    }
  end

  defp request_stop_metadata(result, send_metadata) do
    result
    |> request_result_metadata()
    |> Map.merge(send_metadata)
  end

  defp request_result({:ok, _delivery}), do: :ok
  defp request_result({:error, {:cache, _error}}), do: :cache_error
  defp request_result({:error, {:processing, reason, _headers}}), do: processing_result(reason)

  defp request_result_metadata({:ok, _delivery}), do: %{result: :ok}

  defp request_result_metadata({:error, {:cache, error}}),
    do: %{result: :cache_error, error: Error.tag(error)}

  defp request_result_metadata({:error, {:processing, reason, _headers}}),
    do: %{result: processing_result(reason), error: processing_error_tag(reason)}

  defp processing_result({:source, _error}), do: :source_error
  defp processing_result({:cache_write, _error}), do: :cache_error

  defp processing_result({tag, _error})
       when tag in [:invalid_output_plan, :invalid_pipeline_plan],
       do: :plan_error

  defp processing_result(:empty_pipeline_plan), do: :plan_error
  defp processing_result(_reason), do: :processing_error

  defp processing_error_tag({:source, error}), do: Error.tag(error)
  defp processing_error_tag({:cache_write, error}), do: Error.tag(error)

  defp processing_error_tag({tag, _error})
       when tag in [:invalid_output_plan, :invalid_pipeline_plan],
       do: tag

  defp processing_error_tag(reason), do: Error.tag(reason)

  defp result_metadata({:ok, _value}), do: %{result: :ok}

  defp result_metadata({:error, {_scope, error}}),
    do: %{result: :error, error: Error.tag(error)}

  defp validate_parser_options(opts) do
    opts
    |> Keyword.fetch!(:parser)
    |> validate_parser_options(opts)
  end

  defp validate_parser_options(Imgproxy, opts) do
    imgproxy_opts =
      opts
      |> Keyword.get(:imgproxy, [])
      |> Imgproxy.validate_options!()

    Keyword.put(opts, :imgproxy, imgproxy_opts)
  end

  defp validate_parser_options(_parser, opts), do: opts
end
