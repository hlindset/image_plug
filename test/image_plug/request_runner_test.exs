defmodule ImagePlug.RequestRunnerTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePlug.Cache.Entry
  alias ImagePlug.ProcessingRequest
  alias ImagePlug.RequestRunner
  alias ImagePlug.Transform.Output

  defmodule CacheHit do
    def get(_key, opts), do: Keyword.fetch!(opts, :entry) |> then(&{:hit, &1})
    def put(_key, _entry, _opts), do: raise("cache hit test should not write")
  end

  defp request(overrides \\ []) do
    struct!(
      ProcessingRequest,
      Keyword.merge(
        [
          signature: "_",
          source_kind: :plain,
          source_path: ["images", "cat-300.jpg"],
          format: :jpeg
        ],
        overrides
      )
    )
  end

  test "explicit cache hit returns a cache-entry delivery without processing origin" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    assert {:ok, {:cache_entry, ^entry}} =
             RequestRunner.run(
               conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
               request(),
               [{Output, %Output.OutputParams{format: :jpeg}}],
               "http://origin.test/images/cat-300.jpg",
               cache: {CacheHit, entry: entry}
             )
  end

  test "automatic unacceptable output returns processing error with Vary header" do
    conn =
      :get
      |> conn("/_/plain/images/cat-300.jpg")
      |> Plug.Conn.put_req_header("accept", "image/*;q=0")

    assert RequestRunner.run(
             conn,
             request(format: nil),
             [],
             "http://origin.test/images/cat-300.jpg",
             []
           ) == {:error, {:processing, :not_acceptable, [{"vary", "Accept"}]}}
  end
end
