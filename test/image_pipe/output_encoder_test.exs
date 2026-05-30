defmodule ImagePipe.Output.EncoderTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Resolved

  defmodule CaptureImage do
    def stream!(_image, opts) do
      send(Process.get(:test_pid), {:stream_opts, opts})
      ["encoded"]
    end
  end

  defmodule RaisingStreamImage do
    def stream!(_image, _opts) do
      raise "forced stream failure"
    end
  end

  test "stream_output returns an enumerable and content type" do
    {:ok, image} = Image.new(1, 1)
    Process.put(:test_pid, self())

    resolved_output = %Resolved{
      format: :webp,
      quality: {:quality, 80},
      response_headers: [],
      strip_metadata: false,
      keep_copyright: true,
      strip_color_profile: false
    }

    assert {:ok, stream, "image/webp"} =
             Encoder.stream_output(image, resolved_output, image_module: CaptureImage)

    assert Enum.to_list(stream) == ["encoded"]
    assert_received {:stream_opts, [suffix: ".webp", quality: 80]}
  end

  test "stream_output normalizes stream construction exceptions as encode errors" do
    {:ok, image} = Image.new(1, 1)

    assert {:error, {:encode, %RuntimeError{message: "forced stream failure"}, stacktrace}} =
             Encoder.stream_output(
               image,
               %Resolved{
                 format: :jpeg,
                 quality: :default,
                 response_headers: [],
                 strip_metadata: false,
                 keep_copyright: true,
                 strip_color_profile: false
               },
               image_module: RaisingStreamImage
             )

    assert is_list(stacktrace)
  end
end
