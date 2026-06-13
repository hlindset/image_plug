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

  @impl ImagePipe.Parser
  def validate_options!(opts) when is_list(opts) do
    twicpics_opts =
      opts
      |> Keyword.get(:twicpics, [])
      |> validate_twicpics_options!()

    Keyword.put(opts, :twicpics, twicpics_opts)
  end

  defp validate_twicpics_options!(twicpics_opts) when is_list(twicpics_opts) do
    case NimbleOptions.validate(twicpics_opts, @schema) do
      {:ok, validated} ->
        validated

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError, "invalid twicpics config: #{Exception.message(error)}"
    end
  end

  defp validate_twicpics_options!(_twicpics_opts),
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
