defmodule ImagePlug.Output.EncoderTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Output.Encoder
  alias ImagePlug.Transform.State

  test "memory_output returns encoded bytes and content type" do
    {:ok, image} = Image.new(1, 1)

    assert {:ok, %Encoder.EncodedOutput{} = output} =
             Encoder.memory_output(%State{image: image}, :png, [])

    assert output.content_type == "image/png"
    assert is_binary(output.body)
    assert byte_size(output.body) > 0
  end

  test "memory_output returns tagged error for unsupported atom format" do
    {:ok, image} = Image.new(1, 1)

    assert {:error, {:encode, %ArgumentError{}, []}} =
             Encoder.memory_output(%State{image: image}, :not_a_real_format, [])
  end

  test "memory_output returns tagged error for non-atom format" do
    {:ok, image} = Image.new(1, 1)

    assert {:error, {:encode, %ArgumentError{}, []}} =
             Encoder.memory_output(%State{image: image}, "png", [])
  end
end
