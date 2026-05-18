defmodule ImagePlug.SourceTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan.Source.Path
  alias ImagePlug.Plan.Source.URL
  alias ImagePlug.Source
  alias ImagePlug.Source.HTTP
  alias ImagePlug.Source.Resolved
  alias ImagePlug.Source.Response
  alias ImagePlug.SourceTest.AdapterMismatchAdapter
  alias ImagePlug.SourceTest.CustomAdapter
  alias ImagePlug.SourceTest.InvalidAdapter
  alias ImagePlug.SourceTest.InvalidIdentityAdapter
  alias ImagePlug.SourceTest.RaisingAdapter
  alias ImagePlug.SourceTest.StreamWithCleanup

  test "validate_config calls adapter validation during init-time option normalization" do
    assert {:ok, opts} =
             Source.validate_config(
               sources: [
                 path: {CustomAdapter, adapter: :path, label: "root"}
               ]
             )

    assert_receive {:validate_options, [adapter: :path, label: "root"]}

    assert opts[:sources][:path] ==
             {CustomAdapter, [adapter: :path, label: "root", validated: true]}
  end

  test "resolve dispatches by source shape and configured adapter key" do
    assert {:ok, opts} =
             Source.validate_config(
               sources: [
                 path: {CustomAdapter, adapter: :path}
               ]
             )

    source = %Path{segments: ["images", "cat.jpg"]}

    assert {:ok, %Resolved{} = resolved} = Source.resolve(source, opts, request_id: "r1")
    assert resolved.adapter == :path
    assert resolved.source_kind == :path
    assert resolved.identity == [kind: :path, root: "test", path: ["images", "cat.jpg"]]
    assert resolved.cache == :normal

    assert_receive {:resolve, ^source, adapter_opts, [request_id: "r1"]}
    assert adapter_opts[:validated]
  end

  test "missing configured adapter fails before cache or fetch" do
    assert {:ok, opts} = Source.validate_config(sources: [])

    assert Source.resolve(%Path{segments: ["images", "cat.jpg"]}, opts, []) ==
             {:error, {:source, :missing_adapter}}
  end

  test "url source config enables both HTTP and HTTPS adapters" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 200, "image bytes") end

    assert {:ok, opts} =
             Source.validate_config(
               sources: [
                 url: {HTTP, allowed_hosts: ["assets.example.com"], req_options: [plug: plug]}
               ]
             )

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["images", "cat.jpg"],
      query: nil
    }

    assert {:ok, %Resolved{} = resolved} = Source.resolve(source, opts, [])
    assert resolved.adapter == :https
    assert resolved.identity[:adapter] == :https

    assert {:ok, %Response{} = response} = Source.fetch(resolved, opts, max_body_bytes: 20)
    assert Enum.join(response.stream) == "image bytes"

    assert Map.has_key?(opts[:sources], :http)
    assert Map.has_key?(opts[:sources], :https)
    refute Map.has_key?(opts[:sources], :url)
  end

  test "scheme-specific source config overrides url source config" do
    assert {:ok, opts} =
             Source.validate_config(
               sources: [
                 url: {HTTP, allowed_hosts: ["assets.example.com"]},
                 https: {HTTP, allowed_hosts: ["assets.example.com"], cache: :skip}
               ]
             )

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["images", "cat.jpg"],
      query: nil
    }

    assert {:ok, %Resolved{} = resolved} = Source.resolve(source, opts, [])
    assert resolved.cache == :skip
  end

  test "malformed adapter callback results become source errors" do
    assert {:ok, opts} = Source.validate_config(sources: [path: {InvalidAdapter, []}])

    assert Source.resolve(%Path{segments: ["images", "cat.jpg"]}, opts, []) ==
             {:error, {:source, :invalid_adapter_result}}
  end

  test "malformed fetch callback results become source errors" do
    assert {:ok, opts} = Source.validate_config(sources: [path: {InvalidAdapter, []}])

    resolved = %Resolved{
      adapter: :path,
      source_kind: :path,
      identity: [kind: :path, root: "test", path: ["images", "cat.jpg"]],
      cache: :normal,
      fetch: :invalid_fetch
    }

    assert Source.fetch(resolved, opts, []) == {:error, {:source, :invalid_adapter_result}}
  end

  test "resolved identity must be cache identity material before cache or fetch can see it" do
    for identity <- [
          "https://origin.test/images/cat.jpg",
          [kind: :path, adapter_module: ImagePlug.Source.File],
          [kind: :path, lookup: %{root: "test"}],
          [kind: :path, lookup: {:root, "test"}],
          [kind: :path, client: self()]
        ] do
      assert {:ok, opts} =
               Source.validate_config(
                 sources: [path: {InvalidIdentityAdapter, identity: identity}]
               )

      assert Source.resolve(%Path{segments: ["images", "cat.jpg"]}, opts, []) ==
               {:error, {:source, :invalid_adapter_result}}
    end
  end

  test "resolved adapter must match the adapter key selected during resolution" do
    assert {:ok, opts} = Source.validate_config(sources: [foobar: {AdapterMismatchAdapter, []}])

    source = %ImagePlug.Plan.Source.Object{adapter: :foobar, scope: "scope", key: "cat.jpg"}

    assert Source.resolve(source, opts, []) ==
             {:error, {:source, :invalid_adapter_result}}
  end

  test "fetch dispatches through resolved adapter and wraps binary stream chunks" do
    assert {:ok, opts} = Source.validate_config(sources: [path: {CustomAdapter, adapter: :path}])
    assert {:ok, resolved} = Source.resolve(%Path{segments: ["images", "cat.jpg"]}, opts, [])
    assert {:ok, %Response{} = response} = Source.fetch(resolved, opts, max_body_bytes: 20)

    assert Enum.to_list(response.stream) == ["image", " bytes"]
    assert_receive {:fetch, ^resolved, adapter_opts, [max_body_bytes: 20]}
    assert adapter_opts[:validated]
  end

  test "wrapped streams reject non-binary chunks" do
    response = %Response{stream: ["ok", :bad]}

    assert {:ok, %Response{} = wrapped} = Source.wrap_response(response, max_body_bytes: 20)
    error = assert_raise Source.StreamError, fn -> Enum.to_list(wrapped.stream) end
    assert error.reason == :invalid_stream_chunk
  end

  test "wrapped streams enforce max body bytes" do
    response = %Response{stream: ["123", "456"]}

    assert {:ok, %Response{} = wrapped} = Source.wrap_response(response, max_body_bytes: 5)
    error = assert_raise Source.StreamError, fn -> Enum.to_list(wrapped.stream) end
    assert error.reason == :body_too_large
  end

  test "wrapped streams keep adapter cleanup in enumerable termination path" do
    response = %Response{stream: StreamWithCleanup.stream(self(), ["123", "456"])}

    assert {:ok, %Response{} = wrapped} = Source.wrap_response(response, max_body_bytes: 20)
    assert Enum.take(wrapped.stream, 1) == ["123"]
    assert_receive :stream_closed
  end

  test "wrapped streams sanitize upstream enumerable exceptions" do
    response = %Response{stream: StreamWithCleanup.raising_stream()}

    assert {:ok, %Response{} = wrapped} = Source.wrap_response(response, max_body_bytes: 20)
    error = assert_raise Source.StreamError, fn -> Enum.to_list(wrapped.stream) end
    assert error.reason == :stream_exception
  end

  test "wrapped streams preserve safe deferred source errors" do
    response = %Response{
      stream: Stream.map([:error], fn _ -> raise Source.StreamError, reason: :bad_status end)
    }

    assert {:ok, %Response{} = wrapped} = Source.wrap_response(response, max_body_bytes: 20)
    error = assert_raise Source.StreamError, fn -> Enum.to_list(wrapped.stream) end
    assert error.reason == :bad_status
  end

  test "resolve and fetch catch adapter exceptions as sanitized source errors" do
    assert {:ok, opts} = Source.validate_config(sources: [path: {RaisingAdapter, []}])

    assert Source.resolve(%Path{segments: ["images", "cat.jpg"]}, opts, []) ==
             {:error, {:source, :adapter_exception}}

    resolved = %Resolved{
      adapter: :path,
      source_kind: :path,
      identity: [kind: :path, root: "test", path: ["images", "cat.jpg"]],
      cache: :normal,
      fetch: :raise
    }

    assert Source.fetch(resolved, opts, []) == {:error, {:source, :adapter_exception}}
  end

  test "validate_config! raises for invalid source adapter config" do
    assert_raise ArgumentError, fn ->
      Source.validate_config!(sources: [path: {CustomAdapter, :not_options}])
    end
  end
end
