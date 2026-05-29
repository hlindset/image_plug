defmodule ImagePipe.PlugTest.ConsumeSourceThenDecodeErrorImage do
  @moduledoc false
  def open(stream, _decode_options) do
    _chunks = Enum.to_list(stream)
    {:error, :forced_decode_error}
  end
end
