defmodule ImagePlug.ParamParser do
  alias ImagePlug.ProcessingRequest
  alias ImagePlug.Transform

  @type transform_module() ::
          Transform.Crop
          | Transform.Focus
          | Transform.Scale
          | Transform.Contain
          | Transform.Cover
          | Transform.Output

  @typedoc """
  A tuple of a module implementing `ImagePlug.Transform`
  and the parsed parameters for that transform.
  """
  @type transform_chain_item() ::
          {Transform.Crop, Transform.Crop.CropParams.t()}
          | {Transform.Focus, Transform.Focus.FocusParams.t()}
          | {Transform.Scale, Transform.Scale.ScaleParams.t()}
          | {Transform.Contain, Transform.Contain.ContainParams.t()}
          | {Transform.Cover, Transform.Cover.CoverParams.t()}
          | {Transform.Output, Transform.Output.OutputParams.t()}

  @type transform_chain() :: list(transform_chain_item())

  @type parse_error() :: term()

  @doc """
  Parse a request from a `Plug.Conn`.
  """
  @callback parse(Plug.Conn.t()) :: {:ok, ProcessingRequest.t()} | {:error, any()}

  @doc """
  Render parser-specific errors to the client.
  """
  @callback handle_error(Plug.Conn.t(), {:error, any()}) :: Plug.Conn.t()
end
