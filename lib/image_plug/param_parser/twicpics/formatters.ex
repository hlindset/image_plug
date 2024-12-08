defmodule ImagePlug.ParamParser.Twicpics.Formatters do
  defp format_char(:eoi), do: "end of input"
  defp format_char(other), do: other

  defp join_chars([choice | tail]), do: join_chars(tail, ~s|"#{format_char(choice)}"|)
  defp join_chars([], acc), do: acc
  defp join_chars([last_choice], acc), do: ~s|#{acc} or "#{format_char(last_choice)}"|

  defp join_chars([choice | tail], acc),
    do: join_chars(tail, ~s|#{acc}, "#{format_char(choice)}"|)

  defp format_msg({:error, {:expected_value, opts}}) do
    ~s|Expected value.|
  end

  defp format_msg({:error, {:unexpected_char, opts}}) do
    expected_chars = Keyword.get(opts, :expected)
    found_char = Keyword.get(opts, :found)
    ~s|Expected #{join_chars(expected_chars)} but "#{format_char(found_char)}" found.|
  end

  defp format_msg({:error, {:strictly_positive_number_required, opts}}) do
    found_number = Keyword.get(opts, :found)
    ~s|Strictly positive number expected, found #{format_char(found_number)} instead.|
  end

  defp format_msg({:error, {:positive_number_required, opts}}) do
    found_number = Keyword.get(opts, :found)
    ~s|Positive number expected, found #{format_char(found_number)} instead.|
  end

  defp format_msg({other, _}), do: to_string(other)

  def format_error({:error, {_, opts}} = error) when is_list(opts) do
    input = Keyword.get(opts, :input, "")
    error_offset = Keyword.get(opts, :pos, 0)
    error_padding = String.duplicate(" ", error_offset)

    """
    #{input}
    #{error_padding}▲
    #{error_padding}└── #{format_msg(error)}
    """
  end

  def format_error(_error) do
    "An unhandled error occurred."
  end
end
