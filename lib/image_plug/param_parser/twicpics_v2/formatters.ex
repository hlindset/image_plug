defmodule ImagePlug.ParamParser.TwicpicsV2.Formatters do
  defp format_char(:eoi), do: "end of input"
  defp format_char(other), do: other

  defp join_chars([choice | tail]), do: join_chars(tail, ~s|"#{format_char(choice)}"|)
  defp join_chars([], acc), do: acc
  defp join_chars([last_choice], acc), do: ~s|#{acc} or "#{format_char(last_choice)}"|

  defp join_chars([choice | tail], acc),
    do: join_chars(tail, ~s|#{acc}, "#{format_char(choice)}"|)

  defp format_msg({:unexpected_char, opts}) do
    expected_chars = Keyword.get(opts, :expected)
    found_char = Keyword.get(opts, :found)
    ~s|Expected #{join_chars(expected_chars)} but "#{format_char(found_char)}" found.|
  end

  defp format_msg({other, _}), do: to_string(other)

  def format_error({_, opts} = error) do
    input = Keyword.get(opts, :input, "")
    error_offset = Keyword.get(opts, :pos, 0)
    error_padding = String.duplicate(" ", error_offset)
    IO.puts(input)
    IO.puts("#{error_padding}▲")
    IO.puts("#{error_padding}└── #{format_msg(error)}")
  end

  def print_result({:ok, result}) do
    IO.puts(inspect(result, syntax_colors: IO.ANSI.syntax_colors()))
  end

  def print_result({:error, err}) do
    format_error(err)
  end
end
