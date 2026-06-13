defmodule ImagePipe.Output.EncoderTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan.Color

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
      color_profile: :preserve_source
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
                 color_profile: :preserve_source
               },
               image_module: RaisingStreamImage
             )

    assert is_list(stacktrace)
  end

  test "stream_output flattens an alpha image onto the resolved flatten_background for a non-alpha format" do
    {:ok, image} = Image.new(8, 8, color: [0, 0, 0, 0], bands: 4)
    {:ok, red} = Color.rgb(255, 0, 0)

    resolved = %Resolved{
      format: :jpeg,
      quality: :default,
      response_headers: [],
      strip_metadata: false,
      keep_copyright: true,
      color_profile: :preserve_source,
      flatten_background: red
    }

    assert {:ok, stream, "image/jpeg"} = Encoder.stream_output(image, resolved, [])

    decoded =
      stream
      |> Enum.to_list()
      |> IO.iodata_to_binary()
      |> Image.open!(access: :random, fail_on: :error)

    refute Image.has_alpha?(decoded)
    # Fully transparent source flattened onto the resolved red background; JPEG is
    # lossy so allow a small tolerance.
    assert [r, g, b] = Image.get_pixel!(decoded, 4, 4)
    assert r > 250 and g < 5 and b < 5
  end

  test "stream_output blends a semi-transparent image onto the default flatten_background for a non-alpha format" do
    {:ok, image} = Image.new(8, 8, color: [255, 0, 0, 128], bands: 4)

    resolved = %Resolved{
      format: :jpeg,
      quality: :default,
      response_headers: [],
      strip_metadata: false,
      keep_copyright: true,
      color_profile: :preserve_source
      # flatten_background omitted -> defaults to opaque white
    }

    assert {:ok, stream, "image/jpeg"} = Encoder.stream_output(image, resolved, [])

    decoded =
      stream
      |> Enum.to_list()
      |> IO.iodata_to_binary()
      |> Image.open!(access: :random, fail_on: :error)

    refute Image.has_alpha?(decoded)
    # ~50% red composited onto white: out = fg*a + bg*(1-a) ≈ [255, 127, 127].
    assert [r, g, b] = Image.get_pixel!(decoded, 4, 4)
    assert r > 245
    assert_in_delta g, 128, 12
    assert_in_delta b, 128, 12
  end

  test "stream_output leaves an alpha image untouched when the format carries alpha" do
    {:ok, image} = Image.new(8, 8, color: [10, 20, 30, 0], bands: 4)

    resolved = %Resolved{
      format: :png,
      quality: :default,
      response_headers: [],
      strip_metadata: false,
      keep_copyright: true,
      color_profile: :preserve_source
      # default white flatten_background must be ignored for an alpha-capable format
    }

    assert {:ok, stream, "image/png"} = Encoder.stream_output(image, resolved, [])

    decoded =
      stream
      |> Enum.to_list()
      |> IO.iodata_to_binary()
      |> Image.open!(access: :random, fail_on: :error)

    # PNG carries alpha, so the transparent band is preserved (not flattened to white).
    assert Image.has_alpha?(decoded)
    assert [_r, _g, _b, alpha] = Image.get_pixel!(decoded, 4, 4)
    assert alpha == 0
  end
end
