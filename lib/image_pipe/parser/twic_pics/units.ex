defmodule ImagePipe.Parser.TwicPics.Units do
  @moduledoc false

  import Kernel, except: [length: 1]

  @type length :: {:px, pos_integer()} | {:percent, number()} | {:scale, number()}

  # TwicPics lengths have only two unit suffixes: `p` (percent) and `s` (scale).
  # Pixels are bare numbers — there is NO `px` unit. A `px` substring only ever
  # appears inside a Size/Coordinates token (e.g. `10px150`), where the caller
  # splits on `x` first (`10p` × `150` = 10% × 150px), so `length/1` never
  # receives a `px`-suffixed token from real input.
  @spec length(String.t()) :: {:ok, length()} | {:error, term()}
  def length("-"), do: {:error, {:invalid_length, "-"}}

  def length(value) when is_binary(value) do
    cond do
      String.ends_with?(value, "p") -> percent(String.trim_trailing(value, "p"))
      String.ends_with?(value, "s") -> scale(String.trim_trailing(value, "s"))
      true -> pixels(value)
    end
  end

  defp pixels(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, {:px, n}}
      _ -> {:error, {:invalid_length, value}}
    end
  end

  defp percent(value) do
    with {:ok, n} <- number(value), true <- n > 0 do
      {:ok, {:percent, n}}
    else
      _ -> {:error, {:invalid_length, value}}
    end
  end

  defp scale(value) do
    with {:ok, n} <- number(value), true <- n > 0 do
      {:ok, {:scale, n}}
    else
      _ -> {:error, {:invalid_length, value}}
    end
  end

  @spec number(String.t()) :: {:ok, number()} | :error
  defp number(value) do
    case Integer.parse(value) do
      {n, ""} ->
        {:ok, n}

      _ ->
        case Float.parse(value) do
          {n, ""} -> {:ok, n}
          _ -> :error
        end
    end
  end

  @spec size(String.t()) :: {:ok, {length() | :auto, length() | :auto}} | {:error, term()}
  def size(value), do: pair(value, :auto)

  @spec crop_size(String.t()) ::
          {:ok, {length() | :full_axis, length() | :full_axis}} | {:error, term()}
  def crop_size(value), do: pair(value, :full_axis)

  defp pair(value, omitted) do
    case String.split(value, "x", parts: 2) do
      [single] ->
        with {:ok, w} <- dimension(single, omitted), do: {:ok, {w, omitted}}

      [w, h] ->
        with {:ok, w} <- dimension(w, omitted),
             {:ok, h} <- dimension(h, omitted) do
          {:ok, {w, h}}
        end
    end
  end

  defp dimension("-", omitted), do: {:ok, omitted}
  defp dimension("", omitted), do: {:ok, omitted}
  defp dimension(value, _omitted), do: length(value)

  @spec ratio(String.t()) :: {:ok, {:ratio, pos_integer(), pos_integer()}} | {:error, term()}
  def ratio(value) do
    with [w, h] <- String.split(value, ":", parts: 2),
         {:ok, n} <- positive_ratio_term(w),
         {:ok, d} <- positive_ratio_term(h) do
      {:ok, {:ratio, n, d}}
    else
      _ -> {:error, {:invalid_ratio, value}}
    end
  end

  defp positive_ratio_term(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  @spec coordinates(String.t()) :: {:ok, {length(), length()}} | {:error, term()}
  def coordinates(value) do
    with [x, y] <- String.split(value, "x", parts: 2),
         {:ok, x} <- length(x),
         {:ok, y} <- length(y) do
      {:ok, {x, y}}
    else
      _ -> {:error, {:invalid_coordinates, value}}
    end
  end

  @anchors %{
    "top" => {:anchor, :center, :top},
    "bottom" => {:anchor, :center, :bottom},
    "left" => {:anchor, :left, :center},
    "right" => {:anchor, :right, :center},
    "top-left" => {:anchor, :left, :top},
    "top-right" => {:anchor, :right, :top},
    "bottom-left" => {:anchor, :left, :bottom},
    "bottom-right" => {:anchor, :right, :bottom}
  }

  @spec anchor(String.t()) :: {:ok, {:anchor, atom(), atom()}} | {:error, term()}
  def anchor(value) do
    case Map.fetch(@anchors, value) do
      {:ok, guide} -> {:ok, guide}
      :error -> {:error, {:invalid_anchor, value}}
    end
  end
end
