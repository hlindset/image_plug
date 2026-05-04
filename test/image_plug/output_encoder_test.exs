defmodule ImagePlug.OutputEncoderTest do
  use ExUnit.Case, async: true

  alias ImagePlug.OutputEncoder
  alias ImagePlug.TransformState

  test "memory_output returns encoded bytes and content type" do
    {:ok, image} = Image.new(1, 1)

    assert {:ok, %OutputEncoder.EncodedOutput{} = output} =
             OutputEncoder.memory_output(%TransformState{image: image}, :png, [])

    assert output.content_type == "image/png"
    assert is_binary(output.body)
    assert byte_size(output.body) > 0
  end

  test "memory_output returns tagged error for unsupported atom format" do
    {:ok, image} = Image.new(1, 1)

    assert {:error, {:encode, %ArgumentError{}, []}} =
             OutputEncoder.memory_output(%TransformState{image: image}, :not_a_real_format, [])
  end

  test "memory_output returns tagged error for non-atom format" do
    {:ok, image} = Image.new(1, 1)

    assert {:error, {:encode, %ArgumentError{}, []}} =
             OutputEncoder.memory_output(%TransformState{image: image}, "png", [])
  end
end
