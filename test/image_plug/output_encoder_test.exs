defmodule ImagePlug.OutputEncoderTest do
  use ExUnit.Case, async: true

  alias ImagePlug.OutputEncoder
  alias ImagePlug.TransformState

  test "cache_entry returns tagged encode errors for invalid response headers" do
    {:ok, image} = Image.new(1, 1)

    assert {:error, {:encode, %ArgumentError{} = exception, _stacktrace}} =
             OutputEncoder.cache_entry(
               %TransformState{image: image, output: :png},
               [],
               [{"invalid header name", "value"}]
             )

    assert Exception.message(exception) =~ "invalid cache entry"
  end
end
