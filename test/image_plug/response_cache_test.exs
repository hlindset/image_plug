defmodule ImagePlug.ResponseCacheTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.ProcessingRequest
  alias ImagePlug.ResponseCache
  alias ImagePlug.TransformState

  defmodule CaptureAdapter do
    def get(%Key{} = key, opts) do
      send(self(), {:cache_get, key, opts})
      :miss
    end

    def put(%Key{} = key, %Entry{} = entry, opts) do
      send(self(), {:cache_put, key, entry, opts})
      :ok
    end
  end

  defp request(overrides \\ []) do
    struct!(
      ProcessingRequest,
      Keyword.merge(
        [
          signature: "_",
          source_kind: :plain,
          source_path: ["images", "cat.jpg"],
          format: nil
        ],
        overrides
      )
    )
  end

  test "lookup builds automatic keys from modern candidates without selected output opts" do
    conn =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/avif,image/webp")

    assert {:miss, %Key{} = key} =
             ResponseCache.lookup(
               conn,
               request(),
               "https://origin.test/images/cat.jpg",
               cache: {CaptureAdapter, key_headers: ["accept"]}
             )

    assert key.material[:output] == [
             mode: :automatic,
             modern_candidates: [:avif, :webp],
             auto: [avif: true, webp: true]
           ]

    assert_received {:cache_get, ^key, adapter_opts}
    refute Keyword.has_key?(adapter_opts, :selected_output_format)
    refute Keyword.has_key?(adapter_opts, :selected_output_reason)
  end

  test "store encodes and writes using a key returned by lookup" do
    conn = conn(:get, "/_/f:png/plain/images/cat.jpg")
    request = request(format: :png)

    assert {:miss, %Key{} = key} =
             ResponseCache.lookup(
               conn,
               request,
               "https://origin.test/images/cat.jpg",
               cache: {CaptureAdapter, []}
             )

    {:ok, image} = Image.new(1, 1)
    state = %TransformState{image: image, output: :png}

    assert {:ok, %Entry{} = entry} =
             ResponseCache.store(key, state, [{"vary", "Accept"}], cache: {CaptureAdapter, []})

    assert entry.content_type == "image/png"
    assert_received {:cache_put, ^key, ^entry, _adapter_opts}
  end

  test "store reports skipped when cache writing is disabled" do
    {:ok, image} = Image.new(1, 1)
    state = %TransformState{image: image, output: :png}

    key = %Key{
      hash: String.duplicate("a", 64),
      material: [schema_version: 1],
      serialized_material: :erlang.term_to_binary(schema_version: 1)
    }

    assert :skipped = ResponseCache.store(key, state, [], [])
  end

  test "store returns tagged encode errors for invalid response headers" do
    {:ok, image} = Image.new(1, 1)
    state = %TransformState{image: image, output: :png}

    assert {:error, {:encode, %ArgumentError{} = exception, _stacktrace}} =
             ResponseCache.store(
               %Key{
                 hash: String.duplicate("a", 64),
                 material: [schema_version: 1],
                 serialized_material: :erlang.term_to_binary(schema_version: 1)
               },
               state,
               [{"invalid header name", "value"}],
               cache: {CaptureAdapter, []}
             )

    assert Exception.message(exception) =~ "invalid cache entry"
  end
end
