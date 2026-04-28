defmodule ImagePlug.ParamParser do
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

  @type parse_error() ::
          {:invalid_params, transform_module(), String.t()}
          | {:invalid_transform, String.t()}
          | {:unexpected_char, keyword()}
          | {:expected_key, keyword()}
          | {:expected_value, keyword()}
          | {:strictly_positive_number_required, keyword()}

  @doc """
  Parse a transform chain from a `Plug.Conn`.
  """
  @callback parse(Plug.Conn.t()) :: {:ok, transform_chain()} | {:error, any()}

  @doc """
  Render parser-specific errors to the client.
  """
  @callback handle_error(Plug.Conn.t(), {:error, any()}) :: Plug.Conn.t()
end
