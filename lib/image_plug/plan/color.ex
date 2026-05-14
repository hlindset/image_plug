defmodule ImagePlug.Plan.Color do
  @moduledoc """
  Canonical product-neutral color model for Plan operations.

  The first slice supports opaque sRGB RGB colors only. The `:color`
  dependency stays behind this module so parser, runtime, and cache data do
  not depend on third-party structs.
  """

  @enforce_keys [:space, :channels, :alpha]
  defstruct @enforce_keys

  @type channel :: 0..255
  @type alpha :: {:ratio, pos_integer(), pos_integer()}
  @type t :: %__MODULE__{
          space: :srgb,
          channels: {channel(), channel(), channel()},
          alpha: alpha()
        }

  @spec rgb(term(), term(), term()) :: {:ok, t()} | {:error, term()}
  def rgb(red, green, blue)
      when is_integer(red) and red in 0..255 and is_integer(green) and green in 0..255 and
             is_integer(blue) and blue in 0..255 do
    with {:ok, _external} <- Color.new([red, green, blue]) do
      {:ok,
       %__MODULE__{
         space: :srgb,
         channels: {red, green, blue},
         alpha: {:ratio, 1, 1}
       }}
    else
      {:error, _reason} -> {:error, {:invalid_color, [red, green, blue]}}
    end
  end

  def rgb(red, green, blue), do: {:error, {:invalid_color, [red, green, blue]}}

  @spec valid?(term()) :: boolean()
  def valid?(%__MODULE__{space: :srgb, channels: {red, green, blue}, alpha: {:ratio, 1, 1}}) do
    match?({:ok, %__MODULE__{}}, rgb(red, green, blue))
  end

  def valid?(_color), do: false

  @spec key_data(t()) :: keyword()
  def key_data(%__MODULE__{
        space: :srgb,
        channels: {red, green, blue},
        alpha: {:ratio, 1, 1}
      }) do
    [
      space: :srgb,
      red: red,
      green: green,
      blue: blue,
      alpha: [unit: :ratio, numerator: 1, denominator: 1]
    ]
  end

  @spec to_rgb_list(t()) :: [channel()]
  def to_rgb_list(%__MODULE__{channels: {red, green, blue}}), do: [red, green, blue]
end
