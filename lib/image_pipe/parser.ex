defmodule ImagePipe.Parser do
  @moduledoc """
  Behaviour for parsing image request paths into execution plans.
  """

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Format,
      ImagePipe.Plan,
      ImagePipe.Transform
    ],
    exports: [Imgproxy]

  alias ImagePipe.Plan

  @type parse_error() :: term()

  @doc """
  Parse a request from a `Plug.Conn`.
  """
  @callback parse(Plug.Conn.t(), keyword()) :: {:ok, Plan.t()} | {:error, any()}

  @doc """
  Render request parsing or request validation errors to the client.
  """
  @callback handle_error(Plug.Conn.t(), {:error, any()}) :: Plug.Conn.t()
end
