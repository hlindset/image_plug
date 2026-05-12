defmodule ImagePlug.Runtime.ResponseCacheTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.Output.Resolved
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.Runtime.ResponseCache
  alias ImagePlug.Transform.State

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

  defp plan(overrides \\ []) do
    struct!(
      Plan,
      Keyword.merge(
        [
          source: %Plain{path: ["images", "cat.jpg"]},
          pipelines: [%Pipeline{operations: []}],
          output: %Output{mode: :automatic}
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
               plan(),
               "https://origin.test/images/cat.jpg",
               cache: {CaptureAdapter, key_headers: ["accept"]}
             )

    assert key.data[:output] == [
             mode: :automatic,
             modern_candidates: [:avif, :webp],
             auto: [avif: true, webp: true],
             quality: :default,
             format_qualities: %{}
           ]

    assert_received {:cache_get, ^key, adapter_opts}
    refute Keyword.has_key?(adapter_opts, :selected_output_format)
    refute Keyword.has_key?(adapter_opts, :selected_output_reason)
  end

  test "store encodes and writes using a key returned by lookup" do
    conn = conn(:get, "/_/f:png/plain/images/cat.jpg")
    plan = plan(output: %Output{mode: {:explicit, :png}})

    assert {:miss, %Key{} = key} =
             ResponseCache.lookup(
               conn,
               plan,
               "https://origin.test/images/cat.jpg",
               cache: {CaptureAdapter, []}
             )

    {:ok, image} = Image.new(1, 1)
    state = %State{image: image}

    resolved_output = %Resolved{
      format: :png,
      quality: :default,
      representation_headers: [{"vary", "Accept"}]
    }

    assert {:ok, %Entry{} = entry} =
             ResponseCache.store(
               key,
               state,
               resolved_output,
               cache: {CaptureAdapter, []}
             )

    assert entry.content_type == "image/png"
    assert entry.headers == [{"vary", "Accept"}]
    assert_received {:cache_put, ^key, ^entry, _adapter_opts}
  end

  test "lookup keys include output quality fields" do
    conn = conn(:get, "/_/f:webp/q:80/plain/images/cat.jpg")

    plan =
      plan(
        output: %Output{
          mode: {:explicit, :webp},
          quality: {:quality, 80},
          format_qualities: %{webp: {:quality, 70}}
        }
      )

    assert {:miss, %Key{} = key} =
             ResponseCache.lookup(
               conn,
               plan,
               "https://origin.test/images/cat.jpg",
               cache: {CaptureAdapter, []}
             )

    assert key.data[:output] == [
             mode: :explicit,
             format: :webp,
             quality: {:quality, 80},
             format_qualities: %{webp: {:quality, 70}}
           ]
  end

  test "lookup keys include transform key_data version" do
    assert {:miss, %Key{} = key} =
             ResponseCache.lookup(
               conn(:get, "/_/f:jpeg/plain/images/cat.jpg"),
               plan(output: %Output{mode: {:explicit, :jpeg}}),
               "https://origin.test/images/cat.jpg",
               cache: {CaptureAdapter, []}
             )

    assert key.data[:transform] == [key_data_version: 1]
  end

  test "store reports skipped when cache writing is disabled" do
    {:ok, image} = Image.new(1, 1)
    state = %State{image: image}
    resolved_output = %Resolved{format: :png, quality: :default, representation_headers: []}

    key = %Key{
      hash: String.duplicate("a", 64),
      data: [schema_version: 2],
      serialized_data: :erlang.term_to_binary(schema_version: 2)
    }

    assert :skipped = ResponseCache.store(key, state, resolved_output, [])
  end

  test "store returns tagged encode errors for invalid response headers" do
    {:ok, image} = Image.new(1, 1)
    state = %State{image: image}

    resolved_output = %Resolved{
      format: :png,
      quality: :default,
      representation_headers: [{"invalid header name", "value"}]
    }

    assert {:error, {:encode, %ArgumentError{} = exception, _stacktrace}} =
             ResponseCache.store(
               %Key{
                 hash: String.duplicate("a", 64),
                 data: [schema_version: 2],
                 serialized_data: :erlang.term_to_binary(schema_version: 2)
               },
               state,
               resolved_output,
               cache: {CaptureAdapter, []}
             )

    assert Exception.message(exception) =~ "invalid cache entry"
  end
end
