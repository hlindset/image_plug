defmodule ImagePipe.Request.HTTPCacheTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.Request.HTTPCache
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Resolved

  defp plan(output \\ %Output{mode: {:explicit, :webp}}) do
    %Plan{
      source: %SourcePath{segments: ["cat.jpg"]},
      pipelines: [%Pipeline{operations: []}],
      output: output
    }
  end

  defp resolved(overrides \\ []) do
    struct!(
      %Resolved{
        adapter: :path,
        source_kind: :path,
        identity: [kind: :path, adapter: :path, root: "test", path: ["cat.jpg"]],
        internal_cache: :enabled,
        http_cache: :inherit,
        cache_semantics: %CacheSemantics{
          byte_identity: {:strong, [kind: :path, root: "test", path: ["cat.jpg"]]},
          stable?: true
        },
        fetch: [path: "/tmp/cat.jpg"]
      },
      overrides
    )
  end

  defp opts(overrides \\ []) do
    Keyword.merge(
      [
        http_cache: [mode: :enabled],
        telemetry_prefix: [:image_pipe]
      ],
      overrides
    )
  end

  test "enabled mode with strong byte identity emits cache-control and strong etag" do
    prepared = HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(), opts())

    assert %ImagePipe.Response.CacheHeaders{
             representation_headers: [],
             headers: headers,
             etag: etag
           } = prepared

    assert {"cache-control", "public, max-age=31536000, immutable"} in headers
    assert {"etag", etag} in headers
    assert etag =~ ~r/^"ip1-[A-Za-z0-9_-]+"$/
  end

  test "disabled mode emits no generated cache headers" do
    prepared =
      HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(), http_cache: [mode: :disabled])

    assert prepared.headers == []
    assert prepared.etag == nil
  end

  test "missing byte identity emits no-store fallback without generated etag" do
    prepared =
      HTTPCache.prepare(
        conn(:get, "/image"),
        plan(),
        resolved(
          cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false}
        ),
        opts()
      )

    assert prepared.headers == [{"cache-control", "no-store"}]
    assert prepared.etag == nil
  end

  test "host cache-control suppresses generated cache-control and no-store fallback" do
    conn = put_resp_header(conn(:get, "/image"), "cache-control", "public, max-age=60")

    prepared =
      HTTPCache.prepare(
        conn,
        plan(),
        resolved(
          cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false}
        ),
        opts()
      )

    assert prepared.headers == []
    assert prepared.etag == nil
  end

  test "host etag suppresses generated etag" do
    conn = put_resp_header(conn(:get, "/image"), "etag", ~s("host"))

    prepared = HTTPCache.prepare(conn, plan(), resolved(), opts())

    refute Enum.any?(prepared.headers, fn {name, _value} -> name == "etag" end)
    assert {"cache-control", "public, max-age=31536000, immutable"} in prepared.headers
    assert prepared.etag == nil
  end

  test "automatic output emits representation Vary Accept" do
    prepared =
      HTTPCache.prepare(
        conn(:get, "/image") |> put_req_header("accept", "image/avif,image/webp"),
        plan(%Output{mode: :automatic}),
        resolved(),
        opts()
      )

    assert prepared.representation_headers == [{"vary", "Accept"}]
  end

  test "existing vary merges accept without duplicates" do
    conn =
      conn(:get, "/image")
      |> put_resp_header("vary", "Accept-Encoding, Accept")

    prepared =
      HTTPCache.prepare(
        conn,
        plan(%Output{mode: :automatic}),
        resolved(),
        opts()
      )

    assert prepared.representation_headers == [{"vary", "Accept-Encoding, Accept"}]
  end

  test "existing vary star suppresses generated public cache headers but keeps representation headers" do
    conn =
      conn(:get, "/image")
      |> put_resp_header("vary", "*")

    prepared =
      HTTPCache.prepare(
        conn,
        plan(%Output{mode: :automatic}),
        resolved(),
        opts()
      )

    assert prepared.representation_headers == [{"vary", "*"}]
    assert prepared.headers == []
    assert prepared.etag == nil
  end

  describe "evaluate_conditional/3" do
    test "weak request tag matches generated strong etag for GET" do
      prepared = %ImagePipe.Response.CacheHeaders{
        representation_headers: [],
        headers: [{"etag", ~s("ip1-abc")}],
        etag: ~s("ip1-abc")
      }

      conn =
        :get
        |> conn("/image")
        |> put_req_header("if-none-match", ~s(W/"ip1-abc"))

      assert {:not_modified, headers} = HTTPCache.evaluate_conditional(conn, prepared, [])
      assert {"etag", ~s("ip1-abc")} in headers
    end

    test "wildcard form is ignored in v1" do
      prepared = %ImagePipe.Response.CacheHeaders{
        representation_headers: [],
        headers: [{"etag", ~s("ip1-abc")}],
        etag: ~s("ip1-abc")
      }

      conn =
        :get
        |> conn("/image")
        |> put_req_header("if-none-match", ~s("ip1-abc", *))

      assert :proceed = HTTPCache.evaluate_conditional(conn, prepared, [])
    end

    test "host etag isn't interpreted when prepared etag is nil" do
      prepared = %ImagePipe.Response.CacheHeaders{
        representation_headers: [],
        headers: [],
        etag: nil
      }

      conn =
        :get
        |> conn("/image")
        |> put_req_header("if-none-match", ~s("host"))

      assert :proceed = HTTPCache.evaluate_conditional(conn, prepared, [])
    end

    test "non-matching if-none-match proceeds" do
      prepared = %ImagePipe.Response.CacheHeaders{
        representation_headers: [],
        headers: [{"etag", ~s("ip1-abc")}],
        etag: ~s("ip1-abc")
      }

      conn =
        :get
        |> conn("/image")
        |> put_req_header("if-none-match", ~s("ip1-other"))

      assert :proceed = HTTPCache.evaluate_conditional(conn, prepared, [])
    end

    test "malformed if-none-match proceeds" do
      prepared = %ImagePipe.Response.CacheHeaders{
        representation_headers: [],
        headers: [{"etag", ~s("ip1-abc")}],
        etag: ~s("ip1-abc")
      }

      conn =
        :get
        |> conn("/image")
        |> put_req_header("if-none-match", "not-a-quoted-tag")

      assert :proceed = HTTPCache.evaluate_conditional(conn, prepared, [])
    end

    test "non-cacheable methods do not use conditional response handling" do
      prepared = %ImagePipe.Response.CacheHeaders{
        representation_headers: [],
        headers: [{"etag", ~s("ip1-abc")}],
        etag: ~s("ip1-abc")
      }

      conn =
        :post
        |> conn("/image")
        |> put_req_header("if-none-match", ~s("ip1-abc"))

      assert :proceed = HTTPCache.evaluate_conditional(conn, prepared, [])
    end
  end
end
