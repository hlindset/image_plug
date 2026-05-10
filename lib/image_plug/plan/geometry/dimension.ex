defmodule ImagePlug.Plan.Geometry.Dimension do
  @moduledoc """
  Canonical semantic dimension values for Plan geometry.
  """

  @enforce_keys [:unit]
  defstruct [:unit, :value, :numerator, :denominator]

  @type t :: %__MODULE__{
          unit: :auto | :full_axis | :logical_px | :ratio,
          value: non_neg_integer() | nil,
          numerator: non_neg_integer() | nil,
          denominator: pos_integer() | nil
        }

  @type error ::
          {:invalid_dimension, :pixels, term()}
          | {:invalid_dimension, :ratio, {term(), term()}}

  @spec auto() :: {:ok, t()}
  def auto, do: {:ok, %__MODULE__{unit: :auto}}

  @spec full_axis() :: {:ok, t()}
  def full_axis, do: {:ok, %__MODULE__{unit: :full_axis}}

  @spec pixels(term()) :: {:ok, t()} | {:error, error()}
  def pixels(value) when is_integer(value) and value >= 0 do
    {:ok, %__MODULE__{unit: :logical_px, value: value}}
  end

  def pixels(value), do: {:error, {:invalid_dimension, :pixels, value}}

  @spec ratio(term(), term()) :: {:ok, t()} | {:error, error()}
  def ratio(numerator, denominator)
      when is_integer(numerator) and is_integer(denominator) and numerator >= 0 and
             denominator > 0 do
    gcd = Integer.gcd(numerator, denominator)

    {:ok,
     %__MODULE__{
       unit: :ratio,
       numerator: div(numerator, gcd),
       denominator: div(denominator, gcd)
     }}
  end

  def ratio(numerator, denominator),
    do: {:error, {:invalid_dimension, :ratio, {numerator, denominator}}}
end
