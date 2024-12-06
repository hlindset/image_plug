defmodule ImagePlug.ParamParser.TwicpicsV2.Formatters do
  def format_error({err, opts}) do
    error_offset = Keyword.get(opts, :pos, 0)
    error_padding = String.duplicate(" ", error_offset)
    IO.puts("#{error_padding}▲")
    IO.puts("#{error_padding}└── #{err}")
  end
end
