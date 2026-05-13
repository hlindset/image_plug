defmodule ImagePlug.Runtime.RequestRunnerTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.Output.Resolved
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Response
  alias ImagePlug.Runtime.RequestRunner
  alias ImagePlug.Transform.State

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

  defmodule CacheHitWriteProbe do
    def get(key, opts) do
      send(self(), {:cache_lookup, key})
      Keyword.fetch!(opts, :entry) |> then(&{:hit, &1})
    end

    def put(key, entry, opts) do
      send(self(), {:cache_put, key, entry, opts})
      :ok
    end
  end

  defmodule CacheMissWriteProbe do
    def get(key, opts) do
      emit(opts, {:cache_lookup, key})
      send(self(), {:cache_lookup, key})
      :miss
    end

    def put(key, entry, opts) do
      emit(opts, {:cache_put, key})
      send(self(), {:cache_put, key, entry, opts})
      :ok
    end

    defp emit(opts, event) do
      case Keyword.fetch(opts, :test_pid) do
        {:ok, pid} -> send(pid, {:runner_event, Keyword.fetch!(opts, :test_ref), event})
        :error -> :ok
      end
    end
  end

  defmodule OriginImage do
    def init(opts), do: opts

    def call(%Plug.Conn{request_path: "/images/cat-300.jpg"} = conn, opts) do
      emit(opts)

      body = File.read!("priv/static/images/cat-300.jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end

    defp emit(opts) do
      case Keyword.fetch(opts, :test_pid) do
        {:ok, pid} -> send(pid, {:runner_event, Keyword.fetch!(opts, :test_ref), :origin_fetch})
        :error -> :ok
      end
    end
  end

  defmodule OriginShouldNotFetch do
    def call(_conn, _opts), do: raise("origin should not fetch on cache hit")
  end

  defmodule Materializer do
    alias ImagePlug.Transform.Materializer

    def materialize(%State{} = state, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:pipeline_event, Keyword.fetch!(opts, :test_ref), :materialized_between_pipelines}
      )

      Materializer.materialize(state, opts)
    end
  end

  defp plan(overrides \\ []) do
    struct!(
      Plan,
      Keyword.merge(
        [
          source: {:plain, ["images", "cat-300.jpg"]},
          pipelines: [%Pipeline{operations: []}],
          output: %Output{mode: {:explicit, :jpeg}}
        ],
        overrides
      )
    )
  end

  defp resize_fit_operation(width, height) do
    assert {:ok, operation} =
             Operation.resize(
               :fit,
               tagged_resize_dimension(width),
               tagged_resize_dimension(height),
               enlargement: :deny
             )

    operation
  end

  defp resize_cover_operation(width, height, guide) do
    assert {:ok, operation} =
             Operation.resize(
               :cover,
               tagged_resize_dimension(width),
               tagged_resize_dimension(height),
               enlargement: :deny,
               guide: guide
             )

    operation
  end

  defp tagged_resize_dimension(:auto), do: :auto
  defp tagged_resize_dimension(pixels), do: {:px, pixels}

  test "explicit cache hit returns a cache-entry delivery without processing origin" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    assert {:ok, {:cache_entry, ^entry, %Response{}}} =
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

    assert {:ok, {:cache_entry, ^entry, %ImagePlug.Plan.Response{}}} =
             RequestRunner.run(
               conn,
               plan(output: %Output{mode: :automatic}),
               "http://origin.test/images/cat-300.jpg",
               cache: {CacheHit, entry: entry}
             )
  end

  test "semantic resize auto cache hit does not fetch source or resolve operations" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    assert {:ok, operation} =
             Operation.resize(:auto, {:px, 100}, {:px, 100},
               dpr: 1.0,
               enlargement: :deny
             )

    assert {:ok, {:cache_entry, ^entry, %ImagePlug.Plan.Response{}}} =
             RequestRunner.run(
               conn(:get, "/_/rt:auto/w:100/h:100/f:jpeg/plain/images/cat-300.jpg"),
               plan(pipelines: [%Pipeline{operations: [operation]}]),
               "origin-version-1",
               cache: {CacheReadProbe, entry: entry},
               origin_req_options: [plug: OriginShouldNotFetch]
             )

    assert_received {:cache_lookup, key}
    assert key.data[:origin_identity] == "origin-version-1"
    assert [[operation_data]] = key.data[:pipelines]
    assert operation_data[:op] == :resize
    assert operation_data[:mode] == :auto
    serialized_data = Key.serialize_key_data(key.data)
    refute serialized_data =~ "selected_branch"
    refute serialized_data =~ "source_width"
    refute serialized_data =~ "source_height"
  end

  test "cache miss executes semantic plan after fetch and stores under original key" do
    ref = make_ref()

    assert {:ok, operation} =
             Operation.resize(:auto, {:px, 100}, {:px, 100},
               dpr: 1.0,
               enlargement: :deny
             )

    assert {:ok, {:cache_entry, %Entry{content_type: "image/jpeg"}, %ImagePlug.Plan.Response{}}} =
             RequestRunner.run(
               conn(:get, "/_/rt:auto/w:100/h:100/f:jpeg/plain/images/cat-300.jpg"),
               plan(pipelines: [%Pipeline{operations: [operation]}]),
               "http://origin.test/images/cat-300.jpg",
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
               origin_req_options: [plug: {OriginImage, test_pid: self(), test_ref: ref}]
             )

    assert_receive {:runner_event, ^ref, first_event}
    assert {:cache_lookup, key} = first_event
    assert_receive {:runner_event, ^ref, second_event}
    assert second_event == :origin_fetch
    assert_receive {:runner_event, ^ref, third_event}
    assert {:cache_put, ^key} = third_event

    assert_received {:cache_lookup, key}
    assert_received {:cache_put, ^key, %Entry{}, _opts}
    refute_received {:cache_lookup, _second_key}
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

  test "multiple pipelines reach processing and materialize between pipelines" do
    test_pid = self()
    ref = make_ref()

    plan =
      plan(
        pipelines: [
          %Pipeline{operations: [resize_fit_operation(100, :auto)]},
          %Pipeline{operations: [resize_fit_operation(80, :auto)]}
        ]
      )

    opts = [
      image_materializer: Materializer,
      origin_req_options: [plug: OriginImage],
      test_pid: test_pid,
      test_ref: ref
    ]

    assert {:ok,
            {:image, %State{} = state,
             %Resolved{format: :jpeg, quality: :default, representation_headers: []},
             %ImagePlug.Plan.Response{}}} =
             RequestRunner.run(
               conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
               plan,
               "http://origin.test/images/cat-300.jpg",
               opts
             )

    assert state.image
    assert_receive first_message
    assert first_message == {:pipeline_event, ref, :materialized_between_pipelines}
  end

  test "resolved output carries effective explicit quality" do
    plan =
      plan(
        output: %Output{
          mode: {:explicit, :webp},
          quality: :default,
          format_qualities: %{webp: {:quality, 70}}
        }
      )

    assert {:ok,
            {:image, %State{},
             %Resolved{format: :webp, quality: {:quality, 70}, representation_headers: []},
             %ImagePlug.Plan.Response{}}} =
             RequestRunner.run(
               conn(:get, "/_/f:webp/fq:webp:70/plain/images/cat-300.jpg"),
               plan,
               "http://origin.test/images/cat-300.jpg",
               origin_req_options: [plug: OriginImage]
             )
  end

  test "known plan operations are included in cache lookup key data" do
    operations = [resize_cover_operation(100, 100, {:anchor, :left, :top})]

    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    plan = plan(pipelines: [%Pipeline{operations: operations}])

    assert {:ok, {:cache_entry, ^entry, %ImagePlug.Plan.Response{}}} =
             RequestRunner.run(
               conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
               plan,
               "http://origin.test/images/cat-300.jpg",
               cache: {CacheReadProbe, entry: entry}
             )

    assert_received {:cache_lookup, key}

    assert key.data[:pipelines] == [
             [
               [
                 op: :resize,
                 mode: :cover,
                 width: [unit: :logical_px, value: 100],
                 height: [unit: :logical_px, value: 100],
                 dpr: [unit: :ratio, numerator: 1, denominator: 1],
                 enlargement: :deny,
                 guide: [type: :anchor, x: :left, y: :top],
                 x_offset: {:pixels, 0.0},
                 y_offset: {:pixels, 0.0},
                 min_width: nil,
                 min_height: nil,
                 zoom_x: 1.0,
                 zoom_y: 1.0
               ]
             ]
           ]
  end

  test "cache hits and misses carry plan response delivery metadata" do
    response = %ImagePlug.Plan.Response{
      disposition: :attachment,
      filename: %ImagePlug.Plan.Response.Filename{stem: "carried"}
    }

    assert {:ok, {:image, %State{}, %ImagePlug.Output.Resolved{}, ^response}} =
             RequestRunner.run(
               conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
               plan(response: response),
               "http://origin.test/images/cat-300.jpg",
               origin_req_options: [plug: OriginImage]
             )

    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    assert {:ok, {:cache_entry, ^entry, ^response}} =
             RequestRunner.run(
               conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
               plan(response: response),
               "http://origin.test/images/cat-300.jpg",
               cache: {CacheHit, entry: entry}
             )
  end

  test "unsupported cached delivery content type fails open by default and fails closed when configured" do
    invalid_entry = %Entry{
      body: "cached gif",
      content_type: "image/gif",
      headers: [],
      created_at: DateTime.utc_now()
    }

    response = %ImagePlug.Plan.Response{
      disposition: :inline,
      filename: %ImagePlug.Plan.Response.Filename{stem: "report"}
    }

    assert {:ok, {:cache_entry, %Entry{content_type: "image/jpeg"}, ^response}} =
             RequestRunner.run(
               conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
               plan(response: response),
               "http://origin.test/images/cat-300.jpg",
               cache: {CacheHitWriteProbe, entry: invalid_entry},
               origin_req_options: [plug: OriginImage]
             )

    assert_received {:cache_lookup, key}
    assert_received {:cache_put, ^key, %Entry{content_type: "image/jpeg"}, _opts}
    refute_received {:cache_lookup, _another_key}

    assert {:error, {:cache, {:unsupported_delivery_content_type, "image/gif"}}} =
             RequestRunner.run(
               conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
               plan(response: response),
               "http://origin.test/images/cat-300.jpg",
               cache: {CacheHit, entry: invalid_entry, fail_on_cache_error: true}
             )
  end

  test "output policy uses output plans without a processing request bridge" do
    request_runner_source =
      __DIR__
      |> Path.join("../../lib/image_plug/runtime/request_runner.ex")
      |> Path.expand()
      |> File.read!()

    refute request_runner_source =~ "Processing" <> "Request"
    refute request_runner_source =~ "from_request"
    refute request_runner_source =~ "request.format"
    assert request_runner_source =~ "Policy.from_output_plan(conn, plan.output, opts)"
  end
end
