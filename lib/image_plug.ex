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

  @type imgp_number() :: integer() | float()
  @type imgp_pixels() :: {:pixels, imgp_number()}
  @type imgp_pct() :: {:percent, imgp_number()}
  @type imgp_scale() :: {:scale, imgp_number(), imgp_number()}
  @type imgp_ratio() :: {imgp_number(), imgp_number()}
  @type imgp_length() :: imgp_pixels() | imgp_pct() | imgp_scale()

  @impl Plug
  def init(opts), do: Options.validate!(opts)

  @impl Plug
  def call(%Plug.Conn{} = conn, opts) do
    parser = Keyword.fetch!(opts, :parser)

    with {:ok, %Plan{} = plan} <- parser.parse(conn, opts) |> wrap_parser_error(),
         {:ok, %Plan{} = plan} <- Plan.validate_shape(plan) |> wrap_parser_error(),
         {:ok, origin_identity} <- SourceIdentity.resolve(plan, opts) |> wrap_origin_error() do
      result = RequestRunner.run(conn, plan, origin_identity, opts)
      ResponseSender.send_result(conn, result, opts)
    else
      {:error, {:parser, error}} ->
        parser.handle_error(conn, error)

      {:error, {:origin, error}} ->
        ResponseSender.send_origin_error(conn, error)
    end
  end

  defp wrap_parser_error({:error, _} = error), do: {:error, {:parser, error}}
  defp wrap_parser_error(result), do: result

  defp wrap_origin_error({:error, error}), do: {:error, {:origin, error}}
  defp wrap_origin_error(result), do: result
end
