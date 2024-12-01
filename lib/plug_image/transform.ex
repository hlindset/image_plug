defmodule ImagePlug.Transform do
  alias ImagePlug.TransformState
  alias ImagePlug.ArithmeticParser

  @callback execute(TransformState.t(), String.t()) :: TransformState.t()

  def eval_number({:int, int}), do: {:ok, int}
  def eval_number({:float, float}), do: {:ok, float}
  def eval_number({:expr, expr}), do: ArithmeticParser.parse_and_evaluate(expr)

  def image_dim(%TransformState{image: image}, :width), do: Image.width(image)
  def image_dim(%TransformState{image: image}, :height), do: Image.height(image)

  @spec to_coord(TransformState.t(), :width | :height, ImagePlug.imgp_length()) ::
          {:ok, integer()} | {:error, atom()}
  def to_coord(state, dimension, length)
  def to_coord(_state, _dimension, {:int, int}), do: {:ok, int}
  def to_coord(_state, _dimension, {:float, float}), do: {:ok, round(float)}
  def to_coord(_state, _dimension, {:expr, _} = expr), do: eval_number(expr)

  def to_coord(state, dimension, {:scale, numerator_num, denominator_num}) do
    with {:ok, numerator} <- eval_number(numerator_num),
         {:ok, denominator} <- eval_number(denominator_num) do
      {:ok, round(image_dim(state, dimension) * numerator / denominator)}
    else
      {:error, _} = error -> error
    end
  end

  def to_coord(state, dimension, {:pct, num}) do
    case eval_number(num) do
      {:ok, result} -> {:ok, round(result / 100 * image_dim(state, dimension))}
      {:error, _} = error -> error
    end
  end
end
