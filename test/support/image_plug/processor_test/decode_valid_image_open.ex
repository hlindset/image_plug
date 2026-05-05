defmodule ImagePlug.Runtime.ProcessorTest.DecodeValidImageOpen do
  @moduledoc false

  def open(_stream, _decode_options) do
    Image.new(20, 20, color: :white)
  end
end
