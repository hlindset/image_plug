defmodule ImagePlug.Runtime.RequestRunnerTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Output.Resolved
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.Runtime.RequestRunner
  alias ImagePlug.Runtime.ResponseSender
  alias ImagePlug.Transform
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

    def new(attrs), do: {:ok, new!(attrs)}
    def new!(%__MODULE__{} = operation), do: operation
    def new!(attrs), do: struct!(__MODULE__, attrs)

    def name(%__MODULE__{}), do: :first

    def metadata(%__MODULE__{}), do: %{access: :random}

    def execute(%__MODULE__{}, %State{} = state) do
      %State{state | debug: true}
    end
  end

  defmodule SecondTransform do
    defstruct [:test_pid, :ref]

    def new(attrs), do: {:ok, new!(attrs)}
    def new!(%__MODULE__{} = operation), do: operation
    def new!(attrs), do: struct!(__MODULE__, attrs)

    def name(%__MODULE__{}), do: :second

    def metadata(%__MODULE__{}), do: %{access: :random}

    def execute(%__MODULE__{test_pid: test_pid, ref: ref}, %State{} = state) do
      send(test_pid, {:pipeline_event, ref, :second_transform_ran})
      state
    end
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
          source: %Plain{path: ["images", "cat-300.jpg"]},
          pipelines: [%Pipeline{operations: []}],
          output: %Output{mode: {:explicit, :jpeg}}
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

    assert {:ok, {:cache_entry, ^entry, %ImagePlug.Plan.Response{}}} =
             RequestRunner.run(
               conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
               plan(),
               "http://origin.test/images/cat-300.jpg",
               cache: {CacheHit, entry: entry}
             )
  end

  test "response sender sends cache-entry deliveries from request runner results" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [{"Vary", "Accept"}, {"connection", "close"}],
      created_at: DateTime.utc_now()
    }

    response = %ImagePlug.Plan.Response{}

    conn =
      ResponseSender.send_result(conn(:get, "/image"), {:ok, {:cache_entry, entry, response}}, [])

    assert conn.status == 200
    assert conn.resp_body == "cached jpeg"
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["image/jpeg"]
    assert Plug.Conn.get_resp_header(conn, "vary") == ["Accept"]
    assert Plug.Conn.get_resp_header(conn, "connection") == []
  end

  test "response sender preserves response headers on origin processing errors" do
    conn =
      ResponseSender.send_result(
        conn(:get, "/image"),
        {:error, {:processing, {:origin, {:bad_status, 404}}, [{"vary", "Accept"}]}},
        []
      )

    assert conn.status == 404
    assert conn.resp_body == "origin image not found"
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    assert Plug.Conn.get_resp_header(conn, "vary") == ["Accept"]
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

  test "operations without cache material process uncached instead of rejecting the request" do
    test_pid = self()

    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    plan =
      plan(
        pipelines: [%Pipeline{operations: [%FirstTransform{}]}],
        output: %Output{mode: {:explicit, :jpeg}}
      )

    assert {:ok,
            {:image, %State{} = state,
             %Resolved{format: :jpeg, quality: :default, representation_headers: []},
             %ImagePlug.Plan.Response{}}} =
             RequestRunner.run(
               conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
               plan,
               "http://origin.test/images/cat-300.jpg",
               cache: {CacheReadProbe, entry: entry},
               origin_req_options: [plug: OriginImage],
               test_pid: test_pid
             )

    assert state.image
    assert state.debug
    refute_received {:cache_lookup, _key}
  end

  test "invalid source plans return processing errors before cache lookup" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    assert {:error, {:processing, {:unsupported_source, :not_a_source}, []}} =
             RequestRunner.run(
               conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
               plan(source: :not_a_source),
               "http://origin.test/images/cat-300.jpg",
               cache: {CacheReadProbe, entry: entry}
             )

    refute_received {:cache_lookup, _key}
  end

  test "invalid output plans return processing errors before cache lookup" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    assert {:error, {:processing, {:invalid_output_plan, :not_an_output_plan}, []}} =
             RequestRunner.run(
               conn(:get, "/_/f:jpeg/plain/images/cat-300.jpg"),
               plan(output: :not_an_output_plan),
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
          %Pipeline{operations: [%FirstTransform{}]},
          %Pipeline{
            operations: [%SecondTransform{test_pid: test_pid, ref: ref}]
          }
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
    assert state.debug
    assert_receive first_message
    assert first_message == {:pipeline_event, ref, :materialized_between_pipelines}
    assert_receive second_message
    assert second_message == {:pipeline_event, ref, :second_transform_ran}
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

  test "known plan operations are included in cache lookup material" do
    operations = [
      %Transform.Focus{
        type: {:anchor, :left, :top}
      },
      %Transform.Cover{
        type: :dimensions,
        width: {:pixels, 100},
        height: {:pixels, 100},
        constraint: :min
      }
    ]

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
