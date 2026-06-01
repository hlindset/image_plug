defmodule ImagePipe.Parser.TwicPics do
  @moduledoc """
  Parser for the TwicPics `?twic=v1/…` URL dialect.

  See `docs/twicpics_support_matrix.md` for the supported surface.
  """

  use Boundary,
    deps: [ImagePipe.Parser, ImagePipe.Plan],
    exports: []

  @behaviour ImagePipe.Parser

  alias ImagePipe.Parser.TwicPics.Manipulation
  alias ImagePipe.Parser.TwicPics.Path
  alias ImagePipe.Parser.TwicPics.PlanBuilder

  @schema NimbleOptions.new!([])

  @doc false
  def validate_options!(opts) when is_list(opts) do
    case NimbleOptions.validate(opts, @schema) do
      {:ok, validated} ->
        validated

      {:error, error} ->
        raise ArgumentError, "invalid twicpics config: #{Exception.message(error)}"
    end
  end

  def validate_options!(_opts),
    do: raise(ArgumentError, "invalid twicpics options: expected a keyword list")

  @impl ImagePipe.Parser
  def parse(%Plug.Conn{} = conn, _opts) do
    with {:ok, source, manipulation} <- Path.extract(conn),
         {:ok, chain} <- Manipulation.parse(manipulation) do
      PlanBuilder.to_plan(source, chain)
    end
  end

  @impl ImagePipe.Parser
  def handle_error(%Plug.Conn{} = conn, {:error, reason}) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(400, "invalid image request: #{inspect(reason)}")
  end
end
