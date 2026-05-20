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

  test "source-only opaque TIFF automatic output falls back to JPEG after transforms" do
    require_tiff_support!()

    assert {:ok,
            {:image, %State{}, %Resolved{format: :jpeg, response_headers: [{"vary", "Accept"}]},
             %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/plain/images/source.tiff"),
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               sources: %{path: {SourceBytes, body: tiff_body(:white)}}
             )
  end

  test "source-only alpha TIFF automatic output falls back to PNG after transforms" do
    require_tiff_support!()

    assert {:ok,
            {:image, %State{}, %Resolved{format: :png, response_headers: [{"vary", "Accept"}]},
             %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/plain/images/source.tiff"),
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               sources: %{path: {SourceBytes, body: tiff_body([255, 255, 255, 128])}}
             )
  end

  test "opaque background transform removes alpha before source-only fallback" do
    require_tiff_support!()

    plan =
      plan(
        pipelines: [%Pipeline{operations: [background_operation({:ratio, 1, 1})]}],
        output: %Output{mode: :automatic}
      )

    assert {:ok,
            {:image, %State{} = state,
             %Resolved{format: :jpeg, response_headers: [{"vary", "Accept"}]},
             %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/bg:fff/plain/images/source.tiff"),
               plan,
               resolved_source(),
               sources: %{path: {SourceBytes, body: tiff_body([255, 255, 255, 128])}}
             )

    refute Image.has_alpha?(state.image)
  end

  test "modern Accept candidate still wins for source-only input before final alpha fallback" do
    require_tiff_support!()

    conn =
      :get
      |> conn("/_/plain/images/source.tiff")
      |> Plug.Conn.put_req_header("accept", "image/webp")

    assert {:ok,
            {:image, %State{}, %Resolved{format: :webp, response_headers: [{"vary", "Accept"}]},
             %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn,
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               sources: %{path: {SourceBytes, body: tiff_body([255, 255, 255, 128])}}
             )
  end

  test "source-only automatic fallback cache miss writes JPEG entry with Vary" do
    require_tiff_support!()

    ref = make_ref()

    assert {:ok,
            {:cache_entry, %Entry{content_type: "image/jpeg", headers: [{"vary", "Accept"}]},
             %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/plain/images/source.tiff"),
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
               sources: %{
                 path: {SourceBytes, body: tiff_body(:white), test_pid: self(), test_ref: ref}
               }
             )

    assert_receive {:runner_event, ^ref, first_event}
    assert {:cache_lookup, key} = first_event
    assert_receive {:runner_event, ^ref, second_event}
    assert second_event == :source_fetch
    assert_receive {:runner_event, ^ref, third_event}
    assert {:cache_put, ^key} = third_event

    assert_received {:cache_lookup, ^key}

    assert_received {:cache_put, ^key,
                     %Entry{content_type: "image/jpeg", headers: [{"vary", "Accept"}]}, _opts}

    refute_received {:cache_lookup, _second_key}
  end

  test "source-only alpha fallback cache miss writes PNG entry with Vary" do
    require_tiff_support!()

    ref = make_ref()

    assert {:ok,
            {:cache_entry, %Entry{content_type: "image/png", headers: [{"vary", "Accept"}]},
             %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/plain/images/source.tiff"),
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
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
    assert_receive {:runner_event, ^ref, third_event}
    assert {:cache_put, ^key} = third_event

    assert_received {:cache_lookup, ^key}

    assert_received {:cache_put, ^key,
                     %Entry{content_type: "image/png", headers: [{"vary", "Accept"}]}, _opts}

    refute_received {:cache_lookup, _second_key}
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
    ref = make_ref()

    assert {:ok, operation} =
             Operation.resize(:auto, {:px, 100}, {:px, 100},
               dpr: 1.0,
               enlargement: :deny
             )

    assert {:ok, {:cache_entry, %Entry{content_type: "image/jpeg"}, %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/rt:auto/w:100/h:100/f:jpeg/plain/images/beach.jpg"),
               plan(pipelines: [%Pipeline{operations: [operation]}]),
               resolved_source(),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
               sources: %{path: {SourceImage, test_pid: self(), test_ref: ref}}
             )

    assert_receive {:runner_event, ^ref, first_event}
    assert {:cache_lookup, key} = first_event
    assert_receive {:runner_event, ^ref, second_event}
    assert second_event == :source_fetch
    assert_receive {:runner_event, ^ref, third_event}
    assert {:cache_put, ^key} = third_event

    assert_received {:cache_lookup, key}
    assert_received {:cache_put, ^key, %Entry{}, _opts}
    refute_received {:cache_lookup, _second_key}
  end

  test "invalid cache config returns cache errors before cache lookup" do
    assert {:error, {:cache, {:invalid_cache_config, {:fail_on_cache_error, "false"}}}} =
             Runner.run(
               conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
               plan(),
               resolved_source(),
               cache: {CacheReadProbe, entry: nil, fail_on_cache_error: "false"}
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
      sources: %{path: {SourceImage, test_pid: self(), test_ref: ref}},
      test_pid: test_pid,
      test_ref: ref
    ]

    assert {:ok,
            {:image, %State{} = state,
             %Resolved{format: :jpeg, quality: :default, response_headers: []},
             %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
               plan,
               resolved_source(),
               opts
             )

    assert state.image
    assert_receive {:pipeline_event, ^ref, :materialized_between_pipelines}
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
             %Resolved{format: :webp, quality: {:quality, 70}, response_headers: []},
             %ImagePlug.Plan.Response{}}} =
             Runner.run(
               conn(:get, "/_/f:webp/fq:webp:70/plain/images/beach.jpg"),
               plan,
               resolved_source(),
               sources: %{path: {SourceImage, []}}
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
    response = %ImagePlug.Plan.Response{
      disposition: :attachment,
      filename: "carried"
    }

    assert {:ok, {:image, %State{}, %ImagePlug.Output.Resolved{}, ^response}} =
             Runner.run(
               conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
               plan(response: response),
               resolved_source(),
               sources: %{path: {SourceImage, []}}
             )

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

  test "unsupported cached delivery content type fails open by default and fails closed when configured" do
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

    assert {:ok, {:cache_entry, %Entry{content_type: "image/jpeg"}, ^response}} =
             Runner.run(
               conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
               plan(response: response),
               resolved_source(),
               cache: {CacheHitWriteProbe, entry: invalid_entry},
               sources: %{path: {SourceImage, []}}
             )

    assert_received {:cache_lookup, key}
    assert_received {:cache_put, ^key, %Entry{content_type: "image/jpeg"}, _opts}
    refute_received {:cache_lookup, _another_key}

    assert {:error, {:cache, {:unsupported_delivery_content_type, "image/gif"}}} =
             Runner.run(
               conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
               plan(response: response),
               resolved_source(),
               cache: {CacheHit, entry: invalid_entry, fail_on_cache_error: true}
             )
  end

  test "output policy uses output plans without a processing request bridge" do
    request_runner_source =
      __DIR__
      |> Path.join("../../lib/image_plug/request/runner.ex")
      |> Path.expand()
      |> File.read!()

    refute request_runner_source =~ "Processing" <> "Request"
    refute request_runner_source =~ "from_request"
    refute request_runner_source =~ "request.format"
    assert request_runner_source =~ "Policy.from_output_plan(conn, plan.output, opts)"
  end
end
