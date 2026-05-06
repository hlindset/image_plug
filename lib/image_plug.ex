defmodule ImagePlug do
  @moduledoc """
  Plug entry point for fetching, transforming, caching, and encoding images.
  """

  use Boundary,
    deps: [
      ImagePlug.Parser,
      ImagePlug.Plan,
      ImagePlug.Runtime
    ],
    exports: []

  @behaviour Plug

  alias ImagePlug.Plan
  alias ImagePlug.Runtime.Options
  alias ImagePlug.Runtime.RequestRunner
  alias ImagePlug.Runtime.ResponseSender
  alias ImagePlug.Runtime.SourceIdentity

  @impl Plug
  def init(opts), do: Options.validate!(opts)

  @impl Plug
  def call(%Plug.Conn{} = conn, opts) do
    parser = Keyword.fetch!(opts, :parser)

    with {:ok, %Plan{} = plan} <- parser.parse(conn, opts) |> wrap_parser_error(),
         {:ok, %Plan{} = plan} <- validate_client_plan(plan),
         {:ok, origin_identity} <- SourceIdentity.resolve(plan, opts) |> wrap_origin_error() do
      result = RequestRunner.run(conn, plan, origin_identity, opts)
      ResponseSender.send_result(conn, result, opts)
    else
      {:error, {:parser, error}} ->
        parser.handle_error(conn, error)

      {:error, {:plan_validation, error}} ->
        ResponseSender.send_result(conn, {:error, {:processing, error, []}}, opts)

      {:error, {:origin, error}} ->
        ResponseSender.send_origin_error(conn, error)
    end
  end

  defp validate_client_plan(%Plan{} = plan) do
    with {:ok, %Plan{} = plan} <- Plan.validate_shape(plan),
         {:ok, _pipelines} <- Plan.validated_pipelines(plan) do
      {:ok, plan}
    end
    |> wrap_plan_validation_error()
  end

  defp wrap_parser_error({:error, _} = error), do: {:error, {:parser, error}}
  defp wrap_parser_error(result), do: result

  defp wrap_plan_validation_error({:error, error}), do: {:error, {:plan_validation, error}}
  defp wrap_plan_validation_error(result), do: result

  defp wrap_origin_error({:error, error}), do: {:error, {:origin, error}}
  defp wrap_origin_error(result), do: result
end
