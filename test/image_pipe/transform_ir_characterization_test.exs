defmodule ImagePipe.TransformIRCharacterizationTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Parser.Imgproxy
  alias ImagePipe.Request.Runner
  alias ImagePipe.Response.PreparedStream
  alias ImagePipe.Source.Resolved

  defmodule CacheHitProbe do
    @behaviour ImagePipe.Cache

    def get(key, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:cache_get, key})
      {:hit, Keyword.fetch!(opts, :entry)}
    end

    def open_sink(_key, _metadata, _opts), do: raise("cache hit must not write")
    def write_chunk(_state, _chunk, _opts), do: raise("cache hit must not write")
    def commit_sink(_state, _opts), do: raise("cache hit must not write")
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule GeneratedSourceAdapter do
    @behaviour ImagePipe.Source

    @impl ImagePipe.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePipe.Source
    def resolve(_source, _opts, _runtime_opts), do: raise("test builds resolved sources directly")

    @impl ImagePipe.Source
    def fetch(%ImagePipe.Source.Resolved{fetch: source}, _opts, _runtime_opts) do
      {width, height} = source
      {:ok, image} = Image.new(width, height, color: :white)
      body = Image.write!(image, :memory, suffix: ".png")

      {:ok, %ImagePipe.Source.Response{stream: [body]}}
    end
  end

  defmodule SourceShouldNotFetch do
    @behaviour ImagePipe.Source

    @impl ImagePipe.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePipe.Source
    def resolve(_source, _opts, _runtime_opts), do: raise("test builds resolved sources directly")

    @impl ImagePipe.Source
    def fetch(_resolved, _opts, _runtime_opts), do: raise("source should not fetch on cache hit")
  end

  defp parse_plan!(path) do
    conn = conn(:get, path)
    assert {:ok, plan} = Imgproxy.parse(conn, [])
    {conn, plan}
  end

  defp assert_auto_resize_dimensions(source, target, expected) do
    path = auto_resize_path(source, target)
    {conn, plan} = parse_plan!(path)
    resolved_source = resolved_source(source)

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, _response}} =
             Runner.run(
               conn,
               plan,
               resolved_source,
               sources: %{path: {GeneratedSourceAdapter, []}}
             )

    body = collect_prepared_stream(prepared)
    assert {:ok, image} = Image.open(body, access: :random, fail_on: :error)
    assert {Image.width(image), Image.height(image)} == expected
  end

  defp collect_prepared_stream(%PreparedStream{} = prepared) do
    [prepared.first_chunk]
    |> collect_prepared_stream(prepared)
    |> IO.iodata_to_binary()
  end

  defp collect_prepared_stream(chunks, %PreparedStream{} = prepared) do
    case prepared.next.() do
      {:chunk, chunk} -> collect_prepared_stream([chunks, chunk], prepared)
      :done -> chunks
    end
  end

  defp auto_resize_path(source, {target_width, target_height}) do
    "/_/rt:auto/w:#{target_width}/h:#{target_height}/f:jpeg/plain/generated/#{source_basename(source)}"
  end

  defp source_basename({width, height}), do: "#{width}x#{height}.png"

  defp source_identity(source),
    do: [
      kind: :path,
      adapter: :path,
      root: "generated",
      path: ["generated", source_basename(source)]
    ]

  defp resolved_source(source) do
    %Resolved{
      adapter: :path,
      source_kind: :path,
      identity: source_identity(source),
      cache: :normal,
      fetch: source
    }
  end

  test "cache hit returns before source fetch for resize:auto requests" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    source = {300, 200}
    path = auto_resize_path(source, {100, 100})
    {conn, plan} = parse_plan!(path)
    resolved_source = resolved_source(source)

    assert {:ok, {:cache_entry, ^entry, %ImagePipe.Plan.Response{}}} =
             Runner.run(
               conn,
               plan,
               resolved_source,
               cache: {CacheHitProbe, entry: entry, test_pid: self()},
               sources: %{path: {SourceShouldNotFetch, []}}
             )

    assert_received {:cache_get, key}
    assert key.data[:source_identity] == source_identity(source)
  end

  test "1. request-level resize:auto from 300x200 to 100x50 returns 100x50" do
    assert_auto_resize_dimensions({300, 200}, {100, 50}, {100, 50})
  end

  test "2. request-level resize:auto from 300x200 to 50x100 returns 50x33" do
    assert_auto_resize_dimensions({300, 200}, {50, 100}, {50, 33})
  end

  test "3. request-level resize:auto from 100x100 to 50x50 returns 50x50" do
    assert_auto_resize_dimensions({100, 100}, {50, 50}, {50, 50})
  end

  test "4. request-level resize:auto from 100x100 to 50x80 returns 50x50" do
    assert_auto_resize_dimensions({100, 100}, {50, 80}, {50, 50})
  end
end
