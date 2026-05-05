defmodule ImagePlug.ParamParser do
  @moduledoc """
  Behaviour for parsing image request paths into execution plans.
  """

  alias ImagePlug.Plan

  @type parse_error() :: term()

  @doc """
  Parse a request from a `Plug.Conn`.
  """
  @callback parse(Plug.Conn.t()) :: {:ok, Plan.t()} | {:error, any()}

  @doc """
  Render request parsing or request validation errors to the client.
  """
  @callback handle_error(Plug.Conn.t(), {:error, any()}) :: Plug.Conn.t()
end
