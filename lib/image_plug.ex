defmodule ImagePlug do
  @moduledoc """
  Plug entry point for fetching, transforming, caching, and encoding images.
  """

  use Boundary,
    deps: [
      ImagePlug.Origin,
      ImagePlug.Parser,
      ImagePlug.Plan,
      ImagePlug.Request,
      ImagePlug.Response,
      ImagePlug.Transform
    ],
    exports: []

  @behaviour Plug

  alias ImagePlug.Plan
  alias ImagePlug.Parser.Imgproxy
  alias ImagePlug.Request.Options
  alias ImagePlug.Request.Runner
  alias ImagePlug.Response.Sender
  alias ImagePlug.Origin.Identity
  alias ImagePlug.Transform

  @impl Plug
  def init(opts) do
    opts
    |> Options.validate!()
    |> validate_parser_options()
  end

  @impl Plug
  def call(%Plug.Conn{} = conn, opts) do
    parser = Keyword.fetch!(opts, :parser)

    with {:ok, %Plan{} = plan} <- parser.parse(conn, opts) |> wrap_parser_error(),
         {:ok, %Plan{} = plan} <- validate_client_plan(plan),
         {:ok, origin_identity} <- Identity.resolve(plan, opts) |> wrap_origin_error() do
      result = Runner.run(conn, plan, origin_identity, opts)
      Sender.send_result(conn, result, opts)
    else
      {:error, {:parser, error}} ->
        parser.handle_error(conn, error)

      {:error, {:plan_validation, error}} ->
        Sender.send_result(conn, {:error, {:processing, error, []}}, opts)

      {:error, {:origin, error}} ->
        Sender.send_origin_error(conn, error)
    end
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

  defp wrap_origin_error({:error, error}), do: {:error, {:origin, error}}
  defp wrap_origin_error(result), do: result

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
