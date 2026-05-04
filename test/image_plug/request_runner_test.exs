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
    def get(_key, opts) do
      send(self(), :cache_lookup)
      Keyword.fetch!(opts, :entry) |> then(&{:hit, &1})
    end

    def put(_key, _entry, _opts), do: raise("unprojectable operation test should not write")
  end

  defmodule UnprojectableTransform do
    def execute(state, _params), do: state
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

  test "unprojectable operations fail before cache lookup" do
    operation = {UnprojectableTransform, :params}

    assert_unprojectable_operation_fails_before_cache_lookup(operation)
  end

  test "known contain operations with letterboxing fail before cache lookup" do
    operation =
      {Transform.Contain,
       %Transform.Contain.ContainParams{
         type: :dimensions,
         width: {:pixels, 100},
         height: {:pixels, 100},
         constraint: :max,
         letterbox: true
       }}

    assert_unprojectable_operation_fails_before_cache_lookup(operation)
  end

  test "known contain operations with min constraint fail before cache lookup" do
    operation =
      {Transform.Contain,
       %Transform.Contain.ContainParams{
         type: :dimensions,
         width: {:pixels, 100},
         height: {:pixels, 100},
         constraint: :min,
         letterbox: false
       }}

    assert_unprojectable_operation_fails_before_cache_lookup(operation)
  end

  test "known cover operations with min constraint fail before cache lookup" do
    operation =
      {Transform.Cover,
       %Transform.Cover.CoverParams{
         type: :dimensions,
         width: {:pixels, 100},
         height: {:pixels, 100},
         constraint: :min
       }}

    assert_unprojectable_operation_fails_before_cache_lookup(operation)
  end

  test "two known geometry operations fail before cache lookup" do
    operations = [
      {Transform.Scale,
       %Transform.Scale.ScaleParams{
         type: :dimensions,
         width: {:pixels, 100},
         height: {:pixels, 100}
       }},
      {Transform.Scale,
       %Transform.Scale.ScaleParams{
         type: :dimensions,
         width: {:pixels, 200},
         height: {:pixels, 200}
       }}
    ]

    assert_unprojectable_operations_fail_before_cache_lookup(operations)
  end

  test "cover before focus fails before cache lookup" do
    operations = [
      {Transform.Cover,
       %Transform.Cover.CoverParams{
         type: :dimensions,
         width: {:pixels, 100},
         height: {:pixels, 100},
         constraint: :max
       }},
      {Transform.Focus,
       %Transform.Focus.FocusParams{
         type: {:anchor, :left, :top}
       }}
    ]

    assert_unprojectable_operations_fail_before_cache_lookup(operations)
  end

  defp assert_unprojectable_operation_fails_before_cache_lookup(operation) do
    assert_unprojectable_operations_fail_before_cache_lookup([operation], operation)
  end

  defp assert_unprojectable_operations_fail_before_cache_lookup(operations) do
    assert_unprojectable_operations_fail_before_cache_lookup(operations, operations)
  end

  defp assert_unprojectable_operations_fail_before_cache_lookup(operations, reason) do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    plan = plan(pipelines: [%Pipeline{operations: operations}])

    assert {:error, {:processing, {:unprojectable_operation_for_cache_adapter, ^reason}, []}} =
             RequestRunner.run(
               conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
               plan,
               "http://origin.test/images/cat-300.jpg",
               cache: {CacheReadProbe, entry: entry}
             )

    refute_received :cache_lookup
  end
end
