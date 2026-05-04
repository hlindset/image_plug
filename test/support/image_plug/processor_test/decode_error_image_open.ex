defmodule ImagePlug.ProcessorTest.DecodeErrorImageOpen do
  @moduledoc false

  def open(_stream, _opts), do: {:error, :forced_decode_error}
end
