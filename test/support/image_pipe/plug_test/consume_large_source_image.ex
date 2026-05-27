defmodule ImagePipe.PlugTest.ConsumeLargeSourceImage do
  def open(stream, decode_options) do
    _chunks = Enum.to_list(stream)

    "priv/static/images/beach.jpg"
    |> File.read!()
    |> Image.open(decode_options)
  end
end
