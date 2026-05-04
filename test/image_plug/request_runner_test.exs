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
  alias ImagePlug.TransformState

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

  defmodule OriginImage do
    def call(%Plug.Conn{request_path: "/images/cat-300.jpg"} = conn, _opts) do
      body = File.read!("priv/static/images/cat-300.jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule FirstTransform do
    defstruct []

    def execute(%TransformState{} = state, %__MODULE__{}) do
      %TransformState{state | debug: true}
    end
  end

  defmodule SecondTransform do
    defstruct [:test_pid, :ref]

    def execute(%TransformState{} = state, %__MODULE__{test_pid: test_pid, ref: ref}) do
      send(test_pid, {:pipeline_event, ref, :second_transform_ran})
      state
    end
  end

  defmodule Materializer do
    def materialize(%TransformState{} = state, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:pipeline_event, Keyword.fetch!(opts, :test_ref), :materialized_between_pipelines}
      )

      {:ok, state}
    end
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

  test "empty pipeline plans return processing errors before cache lookup" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    assert {:error, {:processing, :empty_pipeline_plan, []}} =
             RequestRunner.run(
               conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
               plan(pipelines: []),
               "http://origin.test/images/cat-300.jpg",
               cache: {CacheReadProbe, entry: entry}
             )

    refute_received {:cache_lookup, _key}
  end

  test "invalid pipeline plans return processing errors before cache lookup" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    assert {:error, {:processing, {:invalid_pipeline_plan, [:not_a_pipeline]}, []}} =
             RequestRunner.run(
               conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
               plan(pipelines: [:not_a_pipeline]),
               "http://origin.test/images/cat-300.jpg",
               cache: {CacheReadProbe, entry: entry}
             )

    refute_received {:cache_lookup, _key}
  end

  test "invalid pipeline operations return processing errors before cache lookup" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    assert {:error, {:processing, {:invalid_pipeline_operation, :not_operation}, []}} =
             RequestRunner.run(
               conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
               plan(pipelines: [%Pipeline{operations: [:not_operation]}]),
               "http://origin.test/images/cat-300.jpg",
               cache: {CacheReadProbe, entry: entry}
             )

    refute_received {:cache_lookup, _key}
  end

  test "operations without cache material return processing errors before cache lookup" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    assert {:error, {:processing, {:invalid_pipeline_operation, {String, %{}}}, []}} =
             RequestRunner.run(
               conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
               plan(pipelines: [%Pipeline{operations: [{String, %{}}]}]),
               "http://origin.test/images/cat-300.jpg",
               cache: {CacheReadProbe, entry: entry}
             )

    refute_received {:cache_lookup, _key}
  end

  test "multiple pipelines reach processing and materialize between pipelines" do
    test_pid = self()
    ref = make_ref()

    plan =
      plan(
        pipelines: [
          %Pipeline{operations: [{FirstTransform, %FirstTransform{}}]},
          %Pipeline{
            operations: [{SecondTransform, %SecondTransform{test_pid: test_pid, ref: ref}}]
          }
        ]
      )

    opts = [
      image_materializer: Materializer,
      origin_req_options: [plug: OriginImage],
      test_pid: test_pid,
      test_ref: ref
    ]

    assert {:ok, {:image, %TransformState{} = state, :jpeg, []}} =
             RequestRunner.run(
               conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
               plan,
               "http://origin.test/images/cat-300.jpg",
               opts
             )

    assert state.image
    assert state.debug
    assert_receive first_message
    assert first_message == {:pipeline_event, ref, :materialized_between_pipelines}
    assert_receive second_message
    assert second_message == {:pipeline_event, ref, :second_transform_ran}
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

  test "output policy uses output plans without a processing request bridge" do
    request_runner_source =
      __DIR__
      |> Path.join("../../lib/image_plug/request_runner.ex")
      |> Path.expand()
      |> File.read!()

    refute request_runner_source =~ "Processing" <> "Request"
    refute request_runner_source =~ "from_request"
    refute request_runner_source =~ "request.format"
    assert request_runner_source =~ "OutputPolicy.from_output_plan(conn, plan.output, opts)"
  end
end
