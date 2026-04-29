defmodule ImagePlug.ParamParser do
  alias ImagePlug.ProcessingRequest

  @type parse_error() :: term()

  @doc """
  Parse a request from a `Plug.Conn`.
  """
  @callback parse(Plug.Conn.t()) :: {:ok, ProcessingRequest.t()} | {:error, any()}

  @doc """
  Render request parsing or request validation errors to the client.
  """
  @callback handle_error(Plug.Conn.t(), {:error, any()}) :: Plug.Conn.t()
end
