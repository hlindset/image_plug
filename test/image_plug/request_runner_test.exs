defmodule ImagePlug.Request.RunnerTest do
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
  alias ImagePlug.Plan.Source.Path, as: SourcePath
  alias ImagePlug.Request.Runner
  alias ImagePlug.Request.SourceSessionSupervisor
  alias ImagePlug.Response.PreparedStream
  alias ImagePlug.Source.Resolved, as: SourceResolved
  alias ImagePlug.Source.Response, as: SourceResponse
  alias ImagePlug.Transform.State
  alias Vix.Vips.Image, as: VipsImage

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
      send(Keyword.get(opts, :test_pid, self()), {:cache_put, key, entry, opts})
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
      emit(opts, {:cache_put, key, entry})
      send(Keyword.get(opts, :test_pid, self()), {:cache_put, key, entry, opts})
      :ok
    end

    defp emit(opts, event) do
      case Keyword.fetch(opts, :test_pid) do
        {:ok, pid} -> send(pid, {:runner_event, Keyword.fetch!(opts, :test_ref), event})
        :error -> :ok
      end
    end
  end

  defmodule CacheReadErrorWriteProbe do
    def get(key, opts) do
      emit(opts, {:cache_lookup, key})
      {:error, :read_failed}
    end

    def put(key, entry, opts) do
      emit(opts, {:cache_put, key, entry})
      send(Keyword.get(opts, :test_pid, self()), {:cache_put, key, entry, opts})
      :ok
    end

    defp emit(opts, event) do
      case Keyword.fetch(opts, :test_pid) do
        {:ok, pid} -> send(pid, {:runner_event, Keyword.fetch!(opts, :test_ref), event})
        :error -> :ok
      end
    end
  end

  defmodule CacheWriteErrorProbe do
    def get(key, opts) do
      emit(opts, {:cache_lookup, key})
      :miss
    end

    def put(_key, entry, opts) do
      emit(opts, {:cache_put_attempted, entry})
      {:error, :write_failed}
    end

    defp emit(opts, event) do
      case Keyword.fetch(opts, :test_pid) do
        {:ok, pid} -> send(pid, {:runner_event, Keyword.fetch!(opts, :test_ref), event})
        :error -> :ok
      end
    end
  end

  defmodule ClosingAfterFirstChunkAdapter do
    @behaviour Plug.Conn.Adapter

    @impl Plug.Conn.Adapter
    def send_resp(payload, _status, _headers, body), do: {:ok, IO.iodata_to_binary(body), payload}

    @impl Plug.Conn.Adapter
    def send_file(payload, _status, _headers, _path, _offset, _length), do: {:ok, "", payload}

    @impl Plug.Conn.Adapter
    def send_chunked(payload, _status, _headers), do: {:ok, "", %{payload | chunks: 0}}

    @impl Plug.Conn.Adapter
    def chunk(%{chunks: 0} = payload, body),
      do: {:ok, IO.iodata_to_binary(body), %{payload | chunks: 1}}

    def chunk(_payload, _body), do: {:error, :closed}

    @impl Plug.Conn.Adapter
    def read_req_body(payload, _opts), do: {:ok, "", payload}

    @impl Plug.Conn.Adapter
    def inform(payload, _status, _headers), do: {:ok, payload}

    @impl Plug.Conn.Adapter
    def push(payload, _path, _headers), do: {:ok, payload}

    @impl Plug.Conn.Adapter
    def get_peer_data(_payload), do: %Plug.Conn.Unfetched{aspect: :peer_data}

    @impl Plug.Conn.Adapter
    def get_http_protocol(_payload), do: :"HTTP/1.1"

    @impl Plug.Conn.Adapter
    def upgrade(payload, _protocol, _opts), do: {:ok, payload}
  end

  defmodule FailingChunkedAdapter do
    @behaviour Plug.Conn.Adapter

    @impl Plug.Conn.Adapter
    def send_resp(payload, _status, _headers, body), do: {:ok, IO.iodata_to_binary(body), payload}

    @impl Plug.Conn.Adapter
    def send_file(payload, _status, _headers, _path, _offset, _length), do: {:ok, "", payload}

    @impl Plug.Conn.Adapter
    def send_chunked(_payload, _status, _headers), do: raise("chunked open failed")

    @impl Plug.Conn.Adapter
    def chunk(payload, body), do: {:ok, IO.iodata_to_binary(body), payload}

    @impl Plug.Conn.Adapter
    def read_req_body(payload, _opts), do: {:ok, "", payload}

    @impl Plug.Conn.Adapter
    def inform(payload, _status, _headers), do: {:ok, payload}

    @impl Plug.Conn.Adapter
    def push(payload, _path, _headers), do: {:ok, payload}

    @impl Plug.Conn.Adapter
    def get_peer_data(_payload), do: %Plug.Conn.Unfetched{aspect: :peer_data}

    @impl Plug.Conn.Adapter
    def get_http_protocol(_payload), do: :"HTTP/1.1"

    @impl Plug.Conn.Adapter
    def upgrade(payload, _protocol, _opts), do: {:ok, payload}
  end

  defmodule FirstChunkClosedAdapter do
    @behaviour Plug.Conn.Adapter

    @impl Plug.Conn.Adapter
    def send_resp(payload, _status, _headers, body), do: {:ok, IO.iodata_to_binary(body), payload}

    @impl Plug.Conn.Adapter
    def send_file(payload, _status, _headers, _path, _offset, _length), do: {:ok, "", payload}

    @impl Plug.Conn.Adapter
    def send_chunked(payload, _status, _headers), do: {:ok, "", payload}

    @impl Plug.Conn.Adapter
    def chunk(_payload, _body), do: {:error, :closed}

    @impl Plug.Conn.Adapter
    def read_req_body(payload, _opts), do: {:ok, "", payload}

    @impl Plug.Conn.Adapter
    def inform(payload, _status, _headers), do: {:ok, payload}

    @impl Plug.Conn.Adapter
    def push(payload, _path, _headers), do: {:ok, payload}

    @impl Plug.Conn.Adapter
    def get_peer_data(_payload), do: %Plug.Conn.Unfetched{aspect: :peer_data}

    @impl Plug.Conn.Adapter
    def get_http_protocol(_payload), do: :"HTTP/1.1"

    @impl Plug.Conn.Adapter
    def upgrade(payload, _protocol, _opts), do: {:ok, payload}
  end

  defmodule SourceImage do
    @behaviour ImagePlug.Source

    @impl ImagePlug.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePlug.Source
    def resolve(_source, _opts, _runtime_opts), do: raise("runner tests pass resolved sources")

    @impl ImagePlug.Source
    def fetch(_resolved, opts, _runtime_opts) do
      emit(opts)
      body = File.read!("priv/static/images/beach.jpg")
      {:ok, %SourceResponse{stream: [body]}}
    end

    defp emit(opts) do
      case Keyword.fetch(opts, :test_pid) do
        {:ok, pid} -> send(pid, {:runner_event, Keyword.fetch!(opts, :test_ref), :source_fetch})
        :error -> :ok
      end
    end
  end

  defmodule SourceBytes do
    @behaviour ImagePlug.Source

    @impl ImagePlug.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePlug.Source
    def resolve(_source, _opts, _runtime_opts), do: raise("runner tests pass resolved sources")

    @impl ImagePlug.Source
    def fetch(_resolved, opts, _runtime_opts) do
      emit(opts)
      {:ok, %SourceResponse{stream: [Keyword.fetch!(opts, :body)]}}
    end

    defp emit(opts) do
      case Keyword.fetch(opts, :test_pid) do
        {:ok, pid} -> send(pid, {:runner_event, Keyword.fetch!(opts, :test_ref), :source_fetch})
        :error -> :ok
      end
    end
  end

  defmodule SourceShouldNotFetch do
    @behaviour ImagePlug.Source

    @impl ImagePlug.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePlug.Source
    def resolve(_source, _opts, _runtime_opts), do: raise("runner tests pass resolved sources")

    @impl ImagePlug.Source
    def fetch(_resolved, _opts, _runtime_opts), do: raise("source should not fetch on cache hit")
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
          source: %SourcePath{segments: ["images", "beach.jpg"]},
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

  defp require_tiff_support! do
    with {:ok, loader_suffixes} <- VipsImage.supported_loader_suffixes(),
         true <- ".tiff" in loader_suffixes,
         {:ok, saver_suffixes} <- VipsImage.supported_saver_suffixes(),
         true <- ".tiff" in saver_suffixes do
      :ok
    else
      _error -> raise ExUnit.AssertionError, message: "TIFF load/save support unavailable"
    end
  end

  defp tiff_body(color, opts \\ []) do
    Image.new!(20, 20, Keyword.merge([color: color], opts))
    |> Image.write!(:memory, suffix: ".tiff")
  end

  defp background_operation(alpha) do
    assert {:ok, color} = Operation.color(255, 255, 255, alpha)
    assert {:ok, operation} = Operation.background(color)
    operation
  end

  defp resolved_source(overrides \\ []) do
    struct!(
      SourceResolved,
      Keyword.merge(
        [
          adapter: :path,
          source_kind: :path,
          identity: [kind: :path, root: "test", path: ["images", "beach.jpg"]],
          cache: :normal,
          fetch: :fixture
        ],
        overrides
      )
    )
  end

  defp start_source_session_supervisor do
    start_supervised!({SourceSessionSupervisor, name: nil})
  end

  defp assert_cancelled(%PreparedStream{} = prepared, supervisor) do
    assert :ok = prepared.cancel.()
    assert_supervisor_empty(supervisor)
  end

  defp drain_prepared_stream(%PreparedStream{} = prepared) do
    case prepared.next.() do
      {:chunk, chunk} when is_binary(chunk) -> drain_prepared_stream(prepared)
      :done -> :ok
      {:error, reason} -> flunk("expected prepared stream to complete, got #{inspect(reason)}")
    end
  end

  defp assert_supervisor_active(supervisor) do
    _state = :sys.get_state(supervisor)
    assert %{active: 1, workers: 1} = DynamicSupervisor.count_children(supervisor)
  end

  defp assert_supervisor_empty(supervisor) do
    _state = :sys.get_state(supervisor)
    assert %{active: 0, workers: 0} = DynamicSupervisor.count_children(supervisor)
  end

  def handle_telemetry_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  defp attach_telemetry(events) do
    handler_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "source-only opaque TIFF automatic output falls back to JPEG after transforms" do
    require_tiff_support!()
    supervisor = start_source_session_supervisor()

    assert {:ok,
            {:prepared_stream,
             %PreparedStream{
               resolved_output: %Resolved{format: :jpeg, response_headers: [{"vary", "Accept"}]}
             } = prepared, %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/plain/images/source.tiff"),
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               source_session_supervisor: supervisor,
               sources: %{path: {SourceBytes, body: tiff_body(:white)}}
             )

    assert_cancelled(prepared, supervisor)
  end

  test "source-only alpha TIFF automatic output falls back to PNG after transforms" do
    require_tiff_support!()
    supervisor = start_source_session_supervisor()

    assert {:ok,
            {:prepared_stream,
             %PreparedStream{
               resolved_output: %Resolved{format: :png, response_headers: [{"vary", "Accept"}]}
             } = prepared, %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/plain/images/source.tiff"),
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               source_session_supervisor: supervisor,
               sources: %{path: {SourceBytes, body: tiff_body([255, 255, 255, 128])}}
             )

    assert_cancelled(prepared, supervisor)
  end

  test "opaque background transform removes alpha before source-only fallback" do
    require_tiff_support!()
    supervisor = start_source_session_supervisor()

    plan =
      plan(
        pipelines: [%Pipeline{operations: [background_operation({:ratio, 1, 1})]}],
        output: %Output{mode: :automatic}
      )

    assert {:ok,
            {:prepared_stream,
             %PreparedStream{
               resolved_output: %Resolved{format: :jpeg, response_headers: [{"vary", "Accept"}]}
             } = prepared, %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/bg:fff/plain/images/source.tiff"),
               plan,
               resolved_source(),
               source_session_supervisor: supervisor,
               sources: %{path: {SourceBytes, body: tiff_body([255, 255, 255, 128])}}
             )

    assert_cancelled(prepared, supervisor)
  end

  test "modern Accept candidate still wins for source-only input before final alpha fallback" do
    require_tiff_support!()
    supervisor = start_source_session_supervisor()

    conn =
      :get
      |> conn("/_/plain/images/source.tiff")
      |> Plug.Conn.put_req_header("accept", "image/webp")

    assert {:ok,
            {:prepared_stream,
             %PreparedStream{
               resolved_output: %Resolved{format: :webp, response_headers: [{"vary", "Accept"}]}
             } = prepared, %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn,
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               source_session_supervisor: supervisor,
               sources: %{path: {SourceBytes, body: tiff_body([255, 255, 255, 128])}}
             )

    assert_cancelled(prepared, supervisor)
  end

  test "source-only automatic fallback cache miss writes JPEG entry with Vary" do
    require_tiff_support!()

    supervisor = start_source_session_supervisor()
    ref = make_ref()

    assert {:ok,
            {:prepared_stream,
             %PreparedStream{
               resolved_output: %Resolved{format: :jpeg, response_headers: [{"vary", "Accept"}]}
             } = prepared, %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/plain/images/source.tiff"),
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
               source_session_supervisor: supervisor,
               sources: %{
                 path: {SourceBytes, body: tiff_body(:white), test_pid: self(), test_ref: ref}
               }
             )

    assert_receive {:runner_event, ^ref, first_event}
    assert {:cache_lookup, key} = first_event
    assert_receive {:runner_event, ^ref, second_event}
    assert second_event == :source_fetch
    refute_received {:runner_event, ^ref, {:cache_put, ^key, %Entry{}}}

    assert_received {:cache_lookup, ^key}
    assert :ok = drain_prepared_stream(prepared)

    assert_received {:cache_put, ^key,
                     %Entry{content_type: "image/jpeg", headers: [{"vary", "Accept"}]}, _opts}

    refute_received {:cache_lookup, _second_key}
    assert_supervisor_empty(supervisor)
  end

  test "source-only alpha fallback cache miss writes PNG entry with Vary" do
    require_tiff_support!()

    supervisor = start_source_session_supervisor()
    ref = make_ref()

    assert {:ok,
            {:prepared_stream,
             %PreparedStream{
               resolved_output: %Resolved{format: :png, response_headers: [{"vary", "Accept"}]}
             } = prepared, %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/plain/images/source.tiff"),
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
               source_session_supervisor: supervisor,
               sources: %{
                 path:
                   {SourceBytes,
                    body: tiff_body([255, 255, 255, 128]), test_pid: self(), test_ref: ref}
               }
             )

    assert_receive {:runner_event, ^ref, first_event}
    assert {:cache_lookup, key} = first_event
    assert_receive {:runner_event, ^ref, second_event}
    assert second_event == :source_fetch
    refute_received {:runner_event, ^ref, {:cache_put, ^key, %Entry{}}}

    assert_received {:cache_lookup, ^key}
    assert :ok = drain_prepared_stream(prepared)

    assert_received {:cache_put, ^key,
                     %Entry{content_type: "image/png", headers: [{"vary", "Accept"}]}, _opts}

    refute_received {:cache_lookup, _second_key}
    assert_supervisor_empty(supervisor)
  end

  test "source-only automatic cache hit returns cached entry without fetching source" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [{"vary", "Accept"}],
      created_at: DateTime.utc_now()
    }

    assert {:ok, {:cache_entry, ^entry, %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/plain/images/source.tiff"),
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               cache: {CacheHit, entry: entry},
               sources: %{path: {SourceShouldNotFetch, []}}
             )
  end

  test "source-only automatic cache lookup normalizes non-modern Accept headers" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [{"vary", "Accept"}],
      created_at: DateTime.utc_now()
    }

    png_conn =
      :get
      |> conn("/_/plain/images/source.tiff")
      |> Plug.Conn.put_req_header("accept", "image/png")

    jpeg_q0_conn =
      :get
      |> conn("/_/plain/images/source.tiff")
      |> Plug.Conn.put_req_header("accept", "image/jpeg;q=0")

    assert {:ok, {:cache_entry, ^entry, %ImagePlug.Plan.Response{}}} =
             Runner.run(
               png_conn,
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               cache: {CacheReadProbe, entry: entry},
               sources: %{path: {SourceShouldNotFetch, []}}
             )

    assert_received {:cache_lookup, png_key}

    assert {:ok, {:cache_entry, ^entry, %ImagePlug.Plan.Response{}}} =
             Runner.run(
               jpeg_q0_conn,
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               cache: {CacheReadProbe, entry: entry},
               sources: %{path: {SourceShouldNotFetch, []}}
             )

    assert_received {:cache_lookup, jpeg_q0_key}
    assert png_key == jpeg_q0_key
    assert png_key.data[:output][:modern_candidates] == []
  end

  test "explicit cache hit returns a cache-entry delivery without processing origin" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    assert {:ok, {:cache_entry, ^entry, %Response{}}} =
             Runner.run(
               conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
               plan(),
               resolved_source(),
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
      |> conn("/_/plain/images/beach.jpg")
      |> Plug.Conn.put_req_header("accept", "image/jpeg")

    assert {:ok, {:cache_entry, ^entry, %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn,
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
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
             Runner.run(
               conn(:get, "/_/rt:auto/w:100/h:100/f:jpeg/plain/images/beach.jpg"),
               plan(pipelines: [%Pipeline{operations: [operation]}]),
               resolved_source(
                 identity: [
                   kind: :path,
                   root: "test",
                   path: ["images", "beach.jpg"],
                   revision: "1"
                 ]
               ),
               cache: {CacheReadProbe, entry: entry},
               sources: %{path: {SourceShouldNotFetch, []}}
             )

    assert_received {:cache_lookup, key}

    assert key.data[:source_identity] == [
             kind: :path,
             root: "test",
             path: ["images", "beach.jpg"],
             revision: "1"
           ]

    assert [[operation_data]] = key.data[:pipelines]
    assert operation_data[:op] == :resize
    assert operation_data[:mode] == :auto
    serialized_data = Key.serialize_key_data(key.data)
    refute serialized_data =~ "selected_branch"
    refute serialized_data =~ "source_width"
    refute serialized_data =~ "source_height"
  end

  test "cache miss executes semantic plan after fetch and stores under original key" do
    supervisor = start_source_session_supervisor()
    ref = make_ref()

    assert {:ok, operation} =
             Operation.resize(:auto, {:px, 100}, {:px, 100},
               dpr: 1.0,
               enlargement: :deny
             )

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/rt:auto/w:100/h:100/f:jpeg/plain/images/beach.jpg"),
               plan(pipelines: [%Pipeline{operations: [operation]}]),
               resolved_source(),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
               source_session_supervisor: supervisor,
               sources: %{path: {SourceImage, test_pid: self(), test_ref: ref}}
             )

    assert_receive {:runner_event, ^ref, first_event}
    assert {:cache_lookup, key} = first_event
    assert_receive {:runner_event, ^ref, second_event}
    assert second_event == :source_fetch
    refute_received {:runner_event, ^ref, {:cache_put, ^key, %Entry{}}}

    assert_received {:cache_lookup, key}
    assert :ok = drain_prepared_stream(prepared)
    assert_received {:cache_put, ^key, %Entry{}, _opts}
    refute_received {:cache_lookup, _second_key}
    assert_supervisor_empty(supervisor)
  end

  test "no-cache explicit output returns a prepared stream delivery" do
    supervisor = start_source_session_supervisor()

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, %Response{}}} =
             Runner.run(
               conn(:get, "/_/plain/images/beach.jpg"),
               plan(),
               resolved_source(cache: :normal),
               source_session_supervisor: supervisor,
               sources: %{path: {SourceImage, []}}
             )

    assert is_binary(prepared.first_chunk)
    assert byte_size(prepared.first_chunk) > 0
    assert prepared.content_type == "image/jpeg"
    assert is_function(prepared.next, 0)
    assert is_function(prepared.cancel, 0)

    assert_supervisor_active(supervisor)
    assert_cancelled(prepared, supervisor)
  end

  test "cache-skip explicit output returns a prepared stream delivery even when cache is configured" do
    supervisor = start_source_session_supervisor()

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, %Response{}}} =
             Runner.run(
               conn(:get, "/_/plain/images/beach.jpg"),
               plan(),
               resolved_source(cache: :skip),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: make_ref()},
               source_session_supervisor: supervisor,
               sources: %{path: {SourceImage, []}}
             )

    refute_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry, _opts}

    assert_supervisor_active(supervisor)
    assert_cancelled(prepared, supervisor)
  end

  test "configured cache miss writes cache after successful prepared stream delivery" do
    supervisor = start_source_session_supervisor()
    ref = make_ref()

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, response}} =
             Runner.run(
               conn(:get, "/_/plain/images/beach.jpg"),
               plan(),
               resolved_source(cache: :normal),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
               source_session_supervisor: supervisor,
               sources: %{path: {SourceImage, []}}
             )

    assert_received {:cache_lookup, key}
    refute_received {:cache_put, _key, _entry, _opts}
    assert_supervisor_active(supervisor)

    conn =
      ImagePlug.Response.Sender.send_result(
        conn(:get, "/image"),
        {:ok, {:prepared_stream, prepared, response}},
        []
      )

    assert conn.status == 200
    assert is_binary(conn.resp_body)
    assert byte_size(conn.resp_body) > 0

    assert_received {:runner_event, ^ref,
                     {:cache_put, ^key, %Entry{content_type: "image/jpeg", body: body}}}

    assert is_binary(body)
    assert byte_size(body) > 0
    assert_supervisor_empty(supervisor)
  end

  test "cache read fail-open miss returns a prepared stream and writes cache after successful drain" do
    supervisor = start_source_session_supervisor()
    ref = make_ref()

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, %Response{}}} =
             Runner.run(
               conn(:get, "/_/plain/images/beach.jpg"),
               plan(),
               resolved_source(cache: :normal),
               cache: {CacheReadErrorWriteProbe, test_pid: self(), test_ref: ref},
               source_session_supervisor: supervisor,
               sources: %{path: {SourceImage, []}}
             )

    assert_received {:runner_event, ^ref, {:cache_lookup, key}}
    refute_received {:runner_event, ^ref, {:cache_put, _key, %Entry{}}}
    assert_supervisor_active(supervisor)

    assert :ok = drain_prepared_stream(prepared)

    assert_received {:runner_event, ^ref, {:cache_put, ^key, %Entry{content_type: "image/jpeg"}}}
    assert_supervisor_empty(supervisor)
  end

  test "configured cache miss with fail_on_cache_error supplied streams through source session" do
    supervisor = start_source_session_supervisor()
    ref = make_ref()

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, %Response{}}} =
             Runner.run(
               conn(:get, "/_/plain/images/beach.jpg"),
               plan(),
               resolved_source(cache: :normal),
               cache:
                 {CacheMissWriteProbe, test_pid: self(), test_ref: ref, fail_on_cache_error: true},
               source_session_supervisor: supervisor,
               sources: %{path: {SourceImage, []}}
             )

    assert_received {:cache_lookup, key}
    refute_received {:cache_put, _key, %Entry{}, _opts}
    assert_supervisor_active(supervisor)

    assert :ok = drain_prepared_stream(prepared)

    assert_received {:cache_put, ^key, %Entry{content_type: "image/jpeg"}, _opts}
    assert_supervisor_empty(supervisor)
  end

  test "streamed cache miss does not write cache when the client closes before done" do
    supervisor = start_source_session_supervisor()
    ref = make_ref()

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, response}} =
             Runner.run(
               conn(:get, "/_/plain/images/beach.jpg"),
               plan(),
               resolved_source(cache: :normal),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
               source_session_supervisor: supervisor,
               sources: %{path: {SourceImage, []}}
             )

    conn =
      :get
      |> conn("/image")
      |> Map.put(:adapter, {ClosingAfterFirstChunkAdapter, %{chunks: nil}})
      |> ImagePlug.Response.Sender.send_result({:ok, {:prepared_stream, prepared, response}}, [])

    assert conn.private.image_plug_send_result == :processing_error
    assert_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry, _opts}
    assert_supervisor_empty(supervisor)
  end

  test "streamed cache miss does not write cache when send_chunked fails" do
    supervisor = start_source_session_supervisor()
    ref = make_ref()

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, response}} =
             Runner.run(
               conn(:get, "/_/plain/images/beach.jpg"),
               plan(),
               resolved_source(cache: :normal),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
               source_session_supervisor: supervisor,
               sources: %{path: {SourceImage, []}}
             )

    conn =
      :get
      |> conn("/image")
      |> Map.put(:adapter, {FailingChunkedAdapter, %{}})
      |> ImagePlug.Response.Sender.send_result({:ok, {:prepared_stream, prepared, response}}, [])

    assert conn.private.image_plug_send_result == :processing_error
    assert_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry, _opts}
    assert_supervisor_empty(supervisor)
  end

  test "streamed cache miss does not write cache when the first chunk fails" do
    supervisor = start_source_session_supervisor()
    ref = make_ref()

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, response}} =
             Runner.run(
               conn(:get, "/_/plain/images/beach.jpg"),
               plan(),
               resolved_source(cache: :normal),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
               source_session_supervisor: supervisor,
               sources: %{path: {SourceImage, []}}
             )

    conn =
      :get
      |> conn("/image")
      |> Map.put(:adapter, {FirstChunkClosedAdapter, %{}})
      |> ImagePlug.Response.Sender.send_result({:ok, {:prepared_stream, prepared, response}}, [])

    assert conn.private.image_plug_send_result == :processing_error
    assert_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry, _opts}
    assert_supervisor_empty(supervisor)
  end

  test "streamed cache miss cache write errors fail open after successful delivery" do
    attach_telemetry([[:image_plug, :cache, :write, :stop]])

    supervisor = start_source_session_supervisor()
    ref = make_ref()

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, response}} =
             Runner.run(
               conn(:get, "/_/plain/images/beach.jpg"),
               plan(),
               resolved_source(cache: :normal),
               cache: {CacheWriteErrorProbe, test_pid: self(), test_ref: ref},
               source_session_supervisor: supervisor,
               sources: %{path: {SourceImage, []}}
             )

    conn =
      ImagePlug.Response.Sender.send_result(
        conn(:get, "/image"),
        {:ok, {:prepared_stream, prepared, response}},
        []
      )

    assert conn.status == 200
    refute Map.get(conn.private, :image_plug_send_result) == :processing_error
    assert_received {:runner_event, ^ref, {:cache_put_attempted, %Entry{}}}
    assert_supervisor_empty(supervisor)

    assert_receive {:telemetry_event, [:image_plug, :cache, :write, :stop], _measurements,
                    %{result: :cache_error, cache: :write_error, error: :write_failed}}
  end

  test "streamed automatic cache miss writes negotiated entry with Vary" do
    supervisor = start_source_session_supervisor()
    ref = make_ref()

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/f:auto/plain/images/beach.jpg", "")
               |> Plug.Conn.put_req_header("accept", "image/webp,image/jpeg;q=0.8"),
               plan(output: %Output{mode: :automatic}),
               resolved_source(cache: :normal),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
               source_session_supervisor: supervisor,
               sources: %{path: {SourceImage, []}}
             )

    assert_received {:cache_lookup, key}
    assert :ok = drain_prepared_stream(prepared)

    assert_received {:runner_event, ^ref,
                     {:cache_put, ^key,
                      %Entry{
                        body: body,
                        content_type: content_type,
                        headers: [{"vary", "Accept"}]
                      }}}

    assert is_binary(body)
    assert content_type in ["image/webp", "image/jpeg"]
    assert_supervisor_empty(supervisor)
  end

  test "no-cache decode failure returns a pre-response processing error and removes the session" do
    supervisor = start_source_session_supervisor()

    assert {:error, {:processing, {:decode, _reason}, _headers}} =
             Runner.run(
               conn(:get, "/_/plain/images/not-image.jpg"),
               plan(),
               resolved_source(cache: :normal),
               body: "not an image",
               source_session_supervisor: supervisor,
               sources: %{path: {SourceBytes, body: "not an image"}}
             )

    assert_supervisor_empty(supervisor)
  end

  test "invalid cache config returns cache errors before cache lookup" do
    assert {:error, {:cache, {:invalid_cache_config, {:max_body_bytes, "10MB"}}}} =
             Runner.run(
               conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
               plan(),
               resolved_source(),
               cache: {CacheReadProbe, entry: nil, max_body_bytes: "10MB"}
             )

    refute_received {:cache_lookup, _key}
  end

  test "multiple pipelines reach processing and materialize between pipelines" do
    test_pid = self()
    ref = make_ref()
    supervisor = start_source_session_supervisor()

    plan =
      plan(
        pipelines: [
          %Pipeline{operations: [resize_fit_operation(100, :auto)]},
          %Pipeline{operations: [resize_fit_operation(80, :auto)]}
        ]
      )

    opts = [
      image_materializer: Materializer,
      sources: %{path: {SourceImage, test_pid: self(), test_ref: ref}},
      test_pid: test_pid,
      test_ref: ref
    ]

    assert {:ok,
            {:prepared_stream,
             %PreparedStream{
               resolved_output: %Resolved{format: :jpeg, quality: :default, response_headers: []}
             } = prepared, %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
               plan,
               resolved_source(),
               Keyword.put(opts, :source_session_supervisor, supervisor)
             )

    assert_receive {:pipeline_event, ^ref, :materialized_between_pipelines}
    assert_cancelled(prepared, supervisor)
  end

  test "resolved output carries effective explicit quality" do
    supervisor = start_source_session_supervisor()

    plan =
      plan(
        output: %Output{
          mode: {:explicit, :webp},
          quality: :default,
          format_qualities: %{webp: {:quality, 70}}
        }
      )

    assert {:ok,
            {:prepared_stream,
             %PreparedStream{
               resolved_output: %Resolved{
                 format: :webp,
                 quality: {:quality, 70},
                 response_headers: []
               }
             } = prepared, %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/f:webp/fq:webp:70/plain/images/beach.jpg"),
               plan,
               resolved_source(),
               source_session_supervisor: supervisor,
               sources: %{path: {SourceImage, []}}
             )

    assert_cancelled(prepared, supervisor)
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
             Runner.run(
               conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
               plan,
               resolved_source(),
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
    supervisor = start_source_session_supervisor()

    response = %ImagePlug.Plan.Response{
      disposition: :attachment,
      filename: "carried"
    }

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, ^response}} =
             Runner.run(
               conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
               plan(response: response),
               resolved_source(),
               source_session_supervisor: supervisor,
               sources: %{path: {SourceImage, []}}
             )

    assert_cancelled(prepared, supervisor)

    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    assert {:ok, {:cache_entry, ^entry, ^response}} =
             Runner.run(
               conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
               plan(response: response),
               resolved_source(),
               cache: {CacheHit, entry: entry}
             )
  end

  test "invalid cache hit content type fails open when fail_on_cache_error is supplied" do
    invalid_entry = %Entry{
      body: "cached gif",
      content_type: "image/gif",
      headers: [],
      created_at: DateTime.utc_now()
    }

    response = %ImagePlug.Plan.Response{
      disposition: :inline,
      filename: "report"
    }

    supervisor = start_source_session_supervisor()

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, ^response}} =
             Runner.run(
               conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
               plan(response: response),
               resolved_source(),
               cache: {CacheHitWriteProbe, entry: invalid_entry, test_pid: self()},
               source_session_supervisor: supervisor,
               sources: %{path: {SourceImage, []}}
             )

    assert_received {:cache_lookup, key}
    refute_received {:cache_put, _key, _entry, _opts}

    assert :ok = drain_prepared_stream(prepared)
    assert_received {:cache_put, ^key, %Entry{content_type: "image/jpeg"}, _opts}
    refute_received {:cache_lookup, _another_key}
    assert_supervisor_empty(supervisor)

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared_with_ignored_option, ^response}} =
             Runner.run(
               conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
               plan(response: response),
               resolved_source(),
               cache:
                 {CacheHitWriteProbe,
                  entry: invalid_entry, test_pid: self(), fail_on_cache_error: true},
               source_session_supervisor: supervisor,
               sources: %{path: {SourceImage, []}}
             )

    assert :ok = drain_prepared_stream(prepared_with_ignored_option)
    assert_received {:cache_put, _key, %Entry{content_type: "image/jpeg"}, _opts}
    assert_supervisor_empty(supervisor)
  end
end
