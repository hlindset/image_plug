defmodule ImagePlug.RequestRunnerTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePlug.Cache.Entry
  alias ImagePlug.OutputPlan
  alias ImagePlug.Pipeline
  alias ImagePlug.Plan
  alias ImagePlug.RequestRunner
  alias ImagePlug.Source.Plain
  alias ImagePlug.Transform

  defmodule CacheHit do
    def get(_key, opts), do: Keyword.fetch!(opts, :entry) |> then(&{:hit, &1})
    def put(_key, _entry, _opts), do: raise("cache hit test should not write")
  end

  defmodule CacheReadProbe do
    def get(key, opts) do
      send(self(), {:cache_lookup, key})
      Keyword.fetch!(opts, :entry) |> then(&{:hit, &1})
    end

    def put(_key, _entry, _opts), do: raise("cache lookup test should not write")
  end

  defp plan(overrides \\ []) do
    struct!(
      Plan,
      Keyword.merge(
        [
          source: %Plain{path: ["images", "cat-300.jpg"]},
          pipelines: [%Pipeline{operations: []}],
          output: %OutputPlan{mode: {:explicit, :jpeg}}
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
               plan(),
               "http://origin.test/images/cat-300.jpg",
               cache: {CacheHit, entry: entry}
             )
  end

  test "automatic cache hit returns without resolving source format" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [{"vary", "Accept"}],
      created_at: DateTime.utc_now()
    }

    conn =
      :get
      |> conn("/_/plain/images/cat-300.jpg")
      |> Plug.Conn.put_req_header("accept", "image/jpeg")

    assert {:ok, {:cache_entry, ^entry}} =
             RequestRunner.run(
               conn,
               plan(output: %OutputPlan{mode: :automatic}),
               "http://origin.test/images/cat-300.jpg",
               cache: {CacheHit, entry: entry}
             )
  end

  test "multiple pipelines fail with the transitional runner error before processing" do
    plan = plan(pipelines: [%Pipeline{operations: []}, %Pipeline{operations: []}])

    assert {:error, {:processing, :unsupported_multiple_pipelines_during_transition, []}} =
             RequestRunner.run(
               conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
               plan,
               "http://origin.test/images/cat-300.jpg",
               []
             )
  end

  test "known plan operations are included in cache lookup material" do
    operations = [
      {Transform.Focus,
       %Transform.Focus.FocusParams{
         type: {:anchor, :left, :top}
       }},
      {Transform.Cover,
       %Transform.Cover.CoverParams{
         type: :dimensions,
         width: {:pixels, 100},
         height: {:pixels, 100},
         constraint: :min
       }}
    ]

    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    plan = plan(pipelines: [%Pipeline{operations: operations}])

    assert {:ok, {:cache_entry, ^entry}} =
             RequestRunner.run(
               conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
               plan,
               "http://origin.test/images/cat-300.jpg",
               cache: {CacheReadProbe, entry: entry}
             )

    assert_received {:cache_lookup, key}

    assert key.material[:pipelines] == [
             [
               [op: :focus, type: {:anchor, :left, :top}],
               [
                 op: :cover,
                 type: :dimensions,
                 width: {:pixels, 100},
                 height: {:pixels, 100},
                 constraint: :min
               ]
             ]
           ]
  end

  test "legacy processing request bridge is isolated to automatic output policy" do
    request_runner_source =
      __DIR__
      |> Path.join("../../lib/image_plug/request_runner.ex")
      |> Path.expand()
      |> File.read!()

    refute request_runner_source =~ "legacy_request"
    refute request_runner_source =~ "request.format"
    assert request_runner_source =~ "OutputPolicy.from_request(conn, output_policy_request, opts)"
  end
end
