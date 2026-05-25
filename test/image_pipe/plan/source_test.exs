defmodule ImagePipe.Plan.SourceTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source

  test "path source accepts normalized relative segments" do
    source = %Source.Path{segments: ["images", "cat.jpg"]}

    assert {:ok, %Plan{source: ^source}} = Plan.validate_shape(plan(source))
  end

  test "path source rejects traversal and absolute-looking segments" do
    for segments <- [
          [".", "cat.jpg"],
          ["..", "cat.jpg"],
          ["images", ".."],
          ["/images", "cat.jpg"],
          ["images/cat.jpg"],
          ["images\\..\\secret.jpg"]
        ] do
      source = %Source.Path{segments: segments}

      assert Plan.validate_shape(plan(source)) == {:error, {:unsupported_source, source}}
    end
  end

  test "url source accepts http and https with primitive path and query fields" do
    https = %Source.URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["images", "cat.jpg"],
      query: "v=1"
    }

    http = %Source.URL{
      scheme: :http,
      host: "assets.example.com",
      port: 8080,
      path: [],
      query: nil
    }

    assert {:ok, %Plan{source: ^https}} = Plan.validate_shape(plan(https))
    assert {:ok, %Plan{source: ^http}} = Plan.validate_shape(plan(http))
  end

  test "url source rejects unsupported schemes and malformed hosts" do
    for source <- [
          %Source.URL{scheme: :ftp, host: "assets.example.com", path: [], query: nil},
          %Source.URL{scheme: :https, host: "", path: [], query: nil},
          %Source.URL{scheme: :https, host: nil, path: [], query: nil},
          %Source.URL{scheme: :https, host: "assets.example.com", port: 0, path: [], query: nil},
          %Source.URL{
            scheme: :https,
            host: "assets.example.com",
            path: ["images/cat.jpg"],
            query: nil
          }
        ] do
      assert Plan.validate_shape(plan(source)) == {:error, {:unsupported_source, source}}
    end
  end

  test "object source accepts product-neutral object identity fields" do
    source = %Source.Object{
      adapter: :s3,
      scope: "bucket",
      key: "images/cat.jpg",
      revision: "abc"
    }

    assert {:ok, %Plan{source: ^source}} = Plan.validate_shape(plan(source))
  end

  test "object source rejects malformed adapter scope key and revision fields" do
    for source <- [
          %Source.Object{adapter: "s3", scope: "bucket", key: "images/cat.jpg"},
          %Source.Object{adapter: :s3, scope: "", key: "images/cat.jpg"},
          %Source.Object{adapter: :s3, scope: "bucket", key: ""},
          %Source.Object{adapter: :s3, scope: "bucket", key: "images/cat.jpg", revision: :abc}
        ] do
      assert Plan.validate_shape(plan(source)) == {:error, {:unsupported_source, source}}
    end
  end

  test "reference source validates immutable identifier shape but fetch support is deferred" do
    source = %Source.Reference{
      adapter: :catalog,
      id: "asset_123",
      revision: "sha256",
      metadata: [variant: "original"]
    }

    assert {:ok, %Plan{source: ^source}} = Plan.validate_shape(plan(source))
  end

  defp plan(source) do
    %Plan{
      source: source,
      pipelines: [%Pipeline{operations: []}],
      output: %Output{mode: :automatic}
    }
  end
end
