defmodule ImagePipe.Request.ProcessorTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Request.Processor
  alias ImagePipe.Request.ProcessorTest.DecodeErrorImageOpen
  alias ImagePipe.Source
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response
  alias ImagePipe.SourceTest.ValidAdapter
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  defmodule RecordingPathOpen do
    def open(input, opts) do
      send(message_target(), {:opened_input, input})
      Image.open(input, opts)
    end

    defp message_target do
      case Process.get(:"$callers") do
        [pid | _rest] when is_pid(pid) -> pid
        _callers -> self()
      end
    end
  end

  defp opts do
    [
      sources: %{path: {ValidAdapter, []}},
      max_body_bytes: 10_000_000,
      max_input_pixels: 40_000_000,
      max_result_width: 8_192,
      max_result_height: 8_192,
      max_result_pixels: 40_000_000
    ]
  end

  defp resolved_source do
    %Resolved{
      adapter: :path,
      source_kind: :path,
      identity: [kind: :path, root: "test", path: ["images", "beach.jpg"]],
      internal_cache: :enabled,
      http_cache: :inherit,
      cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false},
      fetch: :fixture
    }
  end

  defp plan do
    %Plan{
      source: %Path{segments: ["this", "path", "does-not-drive-fetch.jpg"]},
      pipelines: [%Pipeline{operations: []}],
      output: %Output{mode: {:explicit, :jpeg}}
    }
  end

  defp resize_fit(width, height) do
    Operation.resize(:fit, resize_dimension(width), resize_dimension(height), enlargement: :deny)
  end

  defp resize_cover(width, height) do
    Operation.resize(:cover, resize_dimension(width), resize_dimension(height),
      enlargement: :deny
    )
  end

  defp resize_dimension(:auto), do: :auto
  defp resize_dimension(pixels), do: {:px, pixels}

  defp build_resize_plan(target_w) do
    with {:ok, operation} <- resize_fit(target_w, :auto) do
      {:ok, %Plan{plan() | pipelines: [%Pipeline{operations: [operation]}]}}
    end
  end

  defp svg_supported? do
    case VipsImage.supported_loader_suffixes() do
      {:ok, suffixes} -> ".svg" in suffixes
      {:error, _reason} -> false
    end
  end

  defp svg_body(width, height) do
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="#{width}" height="#{height}" viewBox="0 0 #{width} #{height}">
      <rect width="#{width}" height="#{height}" fill="red"/>
    </svg>
    """
  end

  test "process_source fetches from the resolved source" do
    assert {:ok, %State{} = state} =
             Processor.process_source(
               plan(),
               resolved_source(),
               opts()
             )

    assert state.image
    assert_received {:source_fetch, :fixture}
  end

  test "fetch_decode_validate_source_with_source_format accepts resolved sources" do
    assert {:ok, %{image: %VipsImage{} = _image} = decoded} =
             Processor.fetch_decode_validate_source_with_source_format(
               plan(),
               resolved_source(),
               opts()
             )

    assert decoded.source_format == :jpeg
    assert decoded.decode_options == [access: :sequential, fail_on: :error]
  end

  test "fetch_decode_validate_source_with_source_format plans decode options from the first pipeline only" do
    {:ok, first_operation} = resize_fit(120, :auto)
    {:ok, second_operation} = resize_cover(80, 80)

    plan = %Plan{
      source: %Path{segments: ["images", "beach.jpg"]},
      pipelines: [
        %Pipeline{operations: [first_operation]},
        %Pipeline{operations: [second_operation]}
      ],
      output: %Output{mode: {:explicit, :jpeg}}
    }

    assert {:ok, %{image: %VipsImage{} = _image} = decoded} =
             Processor.fetch_decode_validate_source_with_source_format(
               plan,
               resolved_source(),
               opts()
             )

    # Access is sequential (from the first-pipeline resize). A shrink option may also be present
    # because the planner now receives actual source dims. The key assertion is that only the
    # first-pipeline operations (the fit resize) drove the access selection, not the second-pipeline
    # cover resize (which would force :random).
    assert Keyword.fetch!(decoded.decode_options, :access) == :sequential
    assert Keyword.fetch!(decoded.decode_options, :fail_on) == :error
  end

  test "fetch_decode_validate_source_with_source_format returns singly tagged decode errors" do
    assert {:error, {:decode, :forced_decode_error}} =
             Processor.fetch_decode_validate_source_with_source_format(
               plan(),
               resolved_source(),
               Keyword.put(opts(), :image_open_module, DecodeErrorImageOpen)
             )
  end

  test "decode_validate_source_response returns input limit errors" do
    {:ok, operation} = resize_fit(120, :auto)

    plan = %Plan{
      plan()
      | pipelines: [
          %Pipeline{operations: [operation]}
        ]
    }

    source_response = %Response{stream: [File.read!("priv/static/images/beach.jpg")]}

    assert {:error, {:input_limit, {:too_many_input_pixels, pixel_count, 1}}} =
             Processor.decode_validate_source_response(
               source_response,
               plan,
               Keyword.put(opts(), :max_input_pixels, 1)
             )

    assert pixel_count > 1
  end

  test "process_source rejects final images wider than configured result limit" do
    {:ok, operation} = Operation.resize(:fit, {:px, 21}, :auto, enlargement: :allow)

    plan = %Plan{plan() | pipelines: [%Pipeline{operations: [operation]}]}

    assert {:error, {:result_limit, {:result_width_too_large, 21, 20}}} =
             Processor.process_source(
               plan,
               resolved_source(),
               opts()
               |> Keyword.put(:max_result_width, 20)
               |> Keyword.put(:max_result_height, 10_000)
               |> Keyword.put(:max_result_pixels, 10_000)
             )
  end

  test "process_source accepts final images within configured result limits" do
    {:ok, operation} = Operation.resize(:fit, {:px, 20}, :auto, enlargement: :allow)

    plan = %Plan{plan() | pipelines: [%Pipeline{operations: [operation]}]}

    assert {:ok, %State{} = state} =
             Processor.process_source(
               plan,
               resolved_source(),
               opts()
               |> Keyword.put(:max_result_width, 20)
               |> Keyword.put(:max_result_height, 20)
               |> Keyword.put(:max_result_pixels, 400)
             )

    assert Image.width(state.image) <= 20
    assert Image.height(state.image) <= 20
  end

  test "decode_validate_source_response rejects SVG after decode" do
    if svg_supported?() do
      source_response = %Response{stream: [svg_body(20, 20)]}

      assert {:error, {:unsupported_source_format, :svg}} =
               Processor.decode_validate_source_response(
                 source_response,
                 plan(),
                 opts()
               )
    end
  end

  test "unsupported decoded source format is reported before input pixel limits" do
    if svg_supported?() do
      source_response = %Response{stream: [svg_body(10_000, 10_000)]}

      assert {:error, {:unsupported_source_format, :svg}} =
               Processor.decode_validate_source_response(
                 source_response,
                 plan(),
                 Keyword.put(opts(), :max_input_pixels, 1)
               )
    end
  end

  test "deferred source stream errors remain source errors during decode" do
    response = %Response{stream: Stream.map([:raise], fn _ -> raise "raw stream failure" end)}
    assert {:ok, response} = Source.wrap_response(response, max_body_bytes: 20)

    assert {:error, {:source, :stream_exception}} =
             Processor.decode_validate_source_response(response, plan(), opts())
  end

  test "decode_validate_source_response opens a path response via the path" do
    response = %Response{path: "priv/static/images/beach.jpg"}

    assert {:ok, %{image: image}} =
             Processor.decode_validate_source_response(
               response,
               plan(),
               Keyword.put(opts(), :image_open_module, RecordingPathOpen)
             )

    assert VipsImage.width(image) > 0
    assert_received {:opened_input, "priv/static/images/beach.jpg"}
  end

  test "oversized stream body fails closed before decode is attempted" do
    body = File.read!("priv/static/images/beach.jpg")

    {:ok, response} =
      Source.wrap_response(%Response{stream: [body]}, max_body_bytes: byte_size(body) - 1)

    assert {:error, {:source, :body_too_large}} =
             Processor.decode_validate_source_response(
               response,
               plan(),
               Keyword.put(opts(), :image_open_module, RecordingPathOpen)
             )

    refute_received {:opened_input, _input}
  end

  test "a stream body that happens to equal a local path is decoded as bytes, never opened as a file" do
    # Regression: Image.open/2 on a binary that matches no image signature falls back to a
    # filesystem-path branch (File.exists? -> open). A drained origin body equal to an existing
    # local path must NOT be opened as that file. Routing buffers through Image.from_binary/2
    # (libvips buffer loader) keeps decode purely byte-based, so this returns a decode error.
    path_shaped_body = "priv/static/images/beach.jpg"
    assert File.exists?(path_shaped_body)

    {:ok, response} =
      Source.wrap_response(%Response{stream: [path_shaped_body]}, max_body_bytes: 1_000)

    assert {:error, _reason} =
             Processor.decode_validate_source_response(response, plan(), opts())
  end

  test "the planner's sequential access reaches the libvips buffer loader" do
    # Regression: Image.from_binary/2 deletes :access before new_from_buffer, silently
    # downgrading the planner's :sequential selection. Decoding the drained buffer through
    # new_from_buffer with validated options must carry :access through to libvips.
    body = File.read!("priv/static/images/beach.jpg")

    {:ok, response} =
      Source.wrap_response(%Response{stream: [body]}, max_body_bytes: byte_size(body))

    {:ok, resize} = resize_fit(120, :auto)
    plan = %Plan{plan() | pipelines: [%Pipeline{operations: [resize]}]}

    test_pid = self()

    recording_loader = fn binary, vips_opts ->
      send(test_pid, {:buffer_vips_opts, vips_opts})
      VipsImage.new_from_buffer(binary, vips_opts)
    end

    assert {:ok, %{image: image}} =
             Processor.decode_validate_source_response(
               response,
               plan,
               Keyword.put(opts(), :buffer_loader, recording_loader)
             )

    assert VipsImage.width(image) > 0
    # The two-step open sends two messages: header open (always random access) then
    # the decode open carrying the planner's access selection. Pin both legs so the
    # header probe can't silently start inheriting the planned (sequential) access.
    assert_received {:buffer_vips_opts, header_vips_opts}
    assert Keyword.get(header_vips_opts, :access) == :VIPS_ACCESS_RANDOM
    assert_received {:buffer_vips_opts, decode_vips_opts}
    assert Keyword.get(decode_vips_opts, :access) == :VIPS_ACCESS_SEQUENTIAL
  end

  test "a multi-chunk stream response is drained into one contiguous binary before decode" do
    body = File.read!("priv/static/images/beach.jpg")
    split = div(byte_size(body), 2)
    chunks = [binary_part(body, 0, split), binary_part(body, split, byte_size(body) - split)]

    {:ok, response} =
      Source.wrap_response(%Response{stream: chunks}, max_body_bytes: byte_size(body))

    assert {:ok, %{image: image}} =
             Processor.decode_validate_source_response(
               response,
               plan(),
               Keyword.put(opts(), :image_open_module, RecordingPathOpen)
             )

    assert VipsImage.width(image) > 0
    assert_received {:opened_input, opened}
    assert is_binary(opened)
    assert opened == body
  end

  test "max_input_pixels is checked on original header dims, not the shrunk image" do
    body = File.read!("priv/static/images/beach.jpg")
    {:ok, full_image} = Image.open("priv/static/images/beach.jpg")
    orig_w = Image.width(full_image)
    orig_pixels = orig_w * Image.height(full_image)

    # A shrink-eligible plan (w ≈ orig/9 → JPEG shrink 8 → shrunk pixels ≈ orig/64).
    {:ok, shrink_plan} = build_resize_plan(div(orig_w, 9))

    # The limit sits ABOVE the shrunk pixel count but BELOW the original: a check on
    # the shrunk image would wrongly pass, so a rejection proves validation runs on
    # the ORIGINAL extent (and before the shrink decode open).
    limit = div(orig_pixels, 2)
    tight_limit_opts = Keyword.put(opts(), :max_input_pixels, limit)

    pid = self()

    counting_loader = fn binary, load_opts ->
      send(pid, {:buffer_opened, load_opts})
      VipsImage.new_from_buffer(binary, load_opts)
    end

    response = %Response{stream: [body]}
    {:ok, response} = Source.wrap_response(response, max_body_bytes: byte_size(body) + 100)

    assert {:error, {:input_limit, {:too_many_input_pixels, ^orig_pixels, ^limit}}} =
             Processor.decode_validate_source_response(
               response,
               shrink_plan,
               tight_limit_opts |> Keyword.put(:buffer_loader, counting_loader)
             )

    # Only the header open ran; the shrink decode open was never reached.
    assert_receive {:buffer_opened, _header_opts}
    refute_receive {:buffer_opened, _decode_opts}
  end

  test "shrink-eligible JPEG open: buffer_loader receives shrink option for large downscale" do
    body = File.read!("priv/static/images/beach.jpg")
    {:ok, full_image} = Image.open("priv/static/images/beach.jpg")
    orig_w = Image.width(full_image)

    target_w = div(orig_w, 9)

    pid = self()

    recording_loader = fn binary, load_opts ->
      send(pid, {:buffer_opened, load_opts})
      VipsImage.new_from_buffer(binary, load_opts)
    end

    response = %Response{stream: [body]}
    {:ok, response} = Source.wrap_response(response, max_body_bytes: byte_size(body) + 100)

    {:ok, shrink_plan} = build_resize_plan(target_w)

    {:ok, %{image: image}} =
      Processor.decode_validate_source_response(
        response,
        shrink_plan,
        opts() |> Keyword.put(:buffer_loader, recording_loader)
      )

    assert_receive {:buffer_opened, header_opts}
    refute Keyword.has_key?(header_opts, :shrink)

    assert_receive {:buffer_opened, decode_opts}
    assert Keyword.get(decode_opts, :shrink) == 8

    assert Image.width(image) <= div(orig_w, 5)
  end

  test "PNG downscale: no shrink applied" do
    {:ok, img} = Image.new(400, 300, color: [100, 150, 200])
    png_body = Image.write!(img, :memory, suffix: ".png")

    pid = self()

    recording_loader = fn binary, load_opts ->
      send(pid, {:buffer_opened, load_opts})
      VipsImage.new_from_buffer(binary, load_opts)
    end

    response = %Response{stream: [png_body]}
    {:ok, response} = Source.wrap_response(response, max_body_bytes: byte_size(png_body) + 100)

    {:ok, small_plan} = build_resize_plan(50)

    {:ok, %{image: _image}} =
      Processor.decode_validate_source_response(
        response,
        small_plan,
        opts() |> Keyword.put(:buffer_loader, recording_loader)
      )

    assert_receive {:buffer_opened, _header_opts}
    assert_receive {:buffer_opened, decode_opts}
    refute Keyword.has_key?(decode_opts, :shrink)
    refute Keyword.has_key?(decode_opts, :scale)
  end

  test "decoded map reports original dims and no stored source_dimensions for a non-shrunk PNG" do
    {:ok, frame} = Image.new(400, 300, color: [255, 0, 0])
    png_body = Image.write!(frame, :memory, suffix: ".png")

    response = %Response{stream: [png_body]}
    {:ok, response} = Source.wrap_response(response, max_body_bytes: byte_size(png_body) + 100)

    {:ok, decoded} = Processor.decode_validate_source_response(response, plan(), opts())

    # PNG is not shrink-eligible, so it decodes full-resolution and stores no
    # source_dimensions (the transform layer reads the live image dims instead).
    assert decoded.original_dims == {400, 300}
    assert decoded.source_dimensions == nil
  end

  test "decoded map stores the exact original source_dimensions when a JPEG is shrunk" do
    body = File.read!("priv/static/images/beach.jpg")
    {:ok, full_image} = Image.open("priv/static/images/beach.jpg")
    orig = {Image.width(full_image), Image.height(full_image)}

    {:ok, shrink_plan} = build_resize_plan(div(elem(orig, 0), 9))

    response = %Response{stream: [body]}
    {:ok, response} = Source.wrap_response(response, max_body_bytes: byte_size(body) + 100)

    {:ok, decoded} = Processor.decode_validate_source_response(response, shrink_plan, opts())

    assert decoded.decode_options[:shrink] == 8
    # Exact original is stored (not reconstructed from the shrunk image).
    assert decoded.source_dimensions == orig
  end
end
