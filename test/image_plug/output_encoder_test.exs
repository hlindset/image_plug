defmodule ImagePlug.Output.EncoderTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Output.Encoder
  alias ImagePlug.Output.Resolved

  defmodule CaptureImage do
    def write(_image, :memory, opts) do
      send(Process.get(:test_pid), {:write_opts, opts})
      {:ok, "encoded"}
    end

    def stream!(_image, opts) do
      send(Process.get(:test_pid), {:stream_opts, opts})
      ["encoded"]
    end
  end

  test "memory_output returns encoded bytes and content type" do
    {:ok, image} = Image.new(1, 1)

    assert {:ok, %Encoder.EncodedOutput{} = output} =
             Encoder.memory_output(
               image,
               %Resolved{
                 format: :png,
                 quality: :default,
                 response_headers: []
               },
               []
             )

    assert output.content_type == "image/png"
    assert is_binary(output.body)
    assert byte_size(output.body) > 0
  end

  test "memory_output passes explicit quality to the image writer" do
    {:ok, image} = Image.new(1, 1)
    Process.put(:test_pid, self())

    resolved_output = %Resolved{
      format: :webp,
      quality: {:quality, 80},
      response_headers: []
    }

    assert {:ok, %Encoder.EncodedOutput{body: "encoded", content_type: "image/webp"}} =
             Encoder.memory_output(image, resolved_output, image_module: CaptureImage)

    assert_received {:write_opts, [suffix: ".webp", quality: 80]}
  end

  test "memory_output omits default quality from the image writer" do
    {:ok, image} = Image.new(1, 1)
    Process.put(:test_pid, self())

    resolved_output = %Resolved{
      format: :webp,
      quality: :default,
      response_headers: []
    }

    assert {:ok, %Encoder.EncodedOutput{body: "encoded", content_type: "image/webp"}} =
             Encoder.memory_output(image, resolved_output, image_module: CaptureImage)

    assert_received {:write_opts, [suffix: ".webp"]}
  end

  test "memory_output with a byte limit passes explicit quality to the image streamer" do
    {:ok, image} = Image.new(1, 1)
    Process.put(:test_pid, self())

    resolved_output = %Resolved{
      format: :webp,
      quality: {:quality, 80},
      response_headers: []
    }

    assert {:ok, %Encoder.EncodedOutput{body: "encoded", content_type: "image/webp"}} =
             Encoder.memory_output(
               image,
               resolved_output,
               image_module: CaptureImage,
               max_body_bytes: 100
             )

    assert_received {:stream_opts, [suffix: ".webp", quality: 80]}
  end
end
