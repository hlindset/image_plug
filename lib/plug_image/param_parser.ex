defmodule PlugImage.ParamParser do
  alias PlugImage.Transform

  @type transform_module() :: Transform.Crop | Transform.Focus | Transform.Scale

  @typedoc """
  A tuple of a module implementing `PlugImage.Transform`
  and the parsed parameters for that transform.
  """
  @type transform_chain_item() ::
          {Transform.Crop, Transform.Crop.Parameters.t()}
          | {Transform.Focus, Transform.Focus.Parameters.t()}
          | {Transform.Scale, Transform.Scale.Parameters.t()}

  @type transform_chain() :: list(transform_chain_item())

  @type parse_error() ::
          {:invalid_params, transform_module(), String.t()}
          | {:invalid_transform, String.t()}

  @doc """
  Parse transform chain (a list of `PlugImage.Transform` with parameters) from a `Plug.Conn`.

  ## Examples

      iex> PlugImage.ParamParser.parse("focus=20x30;scale=50p")
      {:ok, [
        {PlugImage.Transform.Focus, %PlugImage.Transform.Focus.FocusParams{left: 20, top: 30},
        {PlugImage.Transform.Scale, %PlugImage.Transform.Scale.ScaleParams{width: {:pct, 50}, height: :auto}}
      ]}
  """
  @callback parse(Plug.Conn.t()) :: {:ok, transform_chain()} | {:error, list(parse_error())}
end
