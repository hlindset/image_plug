defmodule ImagePlug.Cache.KeyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePlug.Cache.Key
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Geometry.Dimension
  alias ImagePlug.Plan.Geometry.Size
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.Transform

  defp plan(overrides \\ []) do
    struct!(
      Plan,
      Keyword.merge(
        [
          source: %Plain{path: ["images", "cat.jpg"]},
          pipelines: [
            %Pipeline{
              operations: [
                %Transform.Operation.Contain{
                  type: :dimensions,
                  width: {:pixels, 300},
                  height: :auto,
                  constraint: :max,
                  letterbox: false
                }
              ]
            },
            %Pipeline{
              operations: [
                %Transform.Operation.Crop{
                  width: {:pixels, 200},
                  height: {:pixels, 100},
                  crop_from: :focus
                }
              ]
            }
          ],
          output: %Output{mode: {:explicit, :webp}}
        ],
        overrides
      )
    )
  end

  defp build_key!(conn, plan, origin_identity, opts \\ []) do
    assert {:ok, key} = Key.build(conn, plan, origin_identity, opts)
    key
  end

  test "builds stable hash and material from canonical plan fields and origin identity" do
    conn = conn(:get, "/sig-one/w:100/plain/images/cat.jpg?ignored=true")

    key = build_key!(conn, plan(), "https://origin-a.test/images/cat.jpg")
    same = build_key!(conn, plan(), "https://origin-a.test/images/cat.jpg")
    different_origin = build_key!(conn, plan(), "https://origin-b.test/images/cat.jpg")

    assert key.hash == same.hash
    assert key.hash =~ ~r/\A[0-9a-f]{64}\z/
    assert is_binary(key.serialized_material)

    assert key.material == [
             schema_version: 2,
             origin_identity: "https://origin-a.test/images/cat.jpg",
             source: [kind: :plain, path: ["images", "cat.jpg"]],
             pipelines: [
               [
                 [
                   op: :contain,
                   type: :dimensions,
                   width: {:pixels, 300},
                   height: :auto,
                   constraint: :max,
                   letterbox: false
                 ]
               ],
               [
                 [
                   op: :crop,
                   width: {:pixels, 200},
                   height: {:pixels, 100},
                   crop_from: :focus
                 ]
               ]
             ],
             backend: [
               backend: :vips,
               material_version: 1,
               geometry_rules_version: 1,
               orientation_policy_version: 1,
               dpr_policy_version: 1,
               smart_strategy_support: :none
             ],
             output: [
               mode: :explicit,
               format: :webp,
               quality: :default,
               format_qualities: %{}
             ],
             cache: [cachebuster: nil],
             selected_headers: [],
             selected_cookies: []
           ]

    assert key.serialized_material == Key.serialize_material(key.material)
    refute inspect(key.material) =~ "sig-one"
    refute inspect(key.material) =~ "ignored=true"
    refute key.hash == different_origin.hash
  end

  test "only accepts execution plans" do
    invalid_plan = :erlang.binary_to_term(:erlang.term_to_binary(%{}))

    assert_raise FunctionClauseError, fn ->
      Key.build(
        conn(:get, "/_/plain/images/cat.jpg"),
        invalid_plan,
        "https://origin.test/cat.jpg"
      )
    end
  end

  test "source material is product-neutral and independent of request URL" do
    conn_one = conn(:get, "/sig-one/w:100/plain/images/cat.jpg")
    conn_two = conn(:get, "/sig-two/width:100/plain/ignored/path.jpg?ignored=true")

    key_one = build_key!(conn_one, plan(), "https://origin.test/images/cat.jpg")
    key_two = build_key!(conn_two, plan(), "https://origin.test/images/cat.jpg")

    assert key_one.material[:source] == [kind: :plain, path: ["images", "cat.jpg"]]
    assert key_one.hash == key_two.hash
  end

  test "pipelines material preserves pipeline boundaries" do
    key =
      conn(:get, "/_/f:webp/plain/images/cat.jpg")
      |> build_key!(plan(), "https://origin.test/images/cat.jpg")

    assert key.material[:pipelines] == [
             [
               [
                 op: :contain,
                 type: :dimensions,
                 width: {:pixels, 300},
                 height: :auto,
                 constraint: :max,
                 letterbox: false
               ]
             ],
             [
               [
                 op: :crop,
                 width: {:pixels, 200},
                 height: {:pixels, 100},
                 crop_from: :focus
               ]
             ]
           ]
  end

  test "pipelines material uses canonical operations instead of raw transform tuples or structs" do
    key =
      conn(:get, "/_/f:webp/plain/images/cat.jpg")
      |> build_key!(plan(), "https://origin.test/images/cat.jpg")

    refute inspect(key.material[:pipelines]) =~ "ImagePlug.Transform"

    assert key.material[:pipelines]
           |> Enum.flat_map(& &1)
           |> Enum.all?(&Keyword.keyword?/1)
  end

  test "resize material includes requested zoom and dpr rule inputs" do
    operation = %ImagePlug.Transform.Operation.Resize{
      rule: %ImagePlug.Transform.Geometry.DimensionRule{
        mode: :fit,
        width: {:pixels, 100},
        height: :auto,
        zoom_x: 2.0,
        zoom_y: 1.5,
        dpr: 2.0,
        enlarge: false
      }
    }

    key =
      conn(:get, "/_/plain/images/cat.jpg")
      |> build_key!(
        plan(pipelines: [%Pipeline{operations: [operation]}]),
        "https://origin.test/images/cat.jpg"
      )

    assert [[resize_material]] = key.material[:pipelines]
    assert resize_material[:op] == :resize
    assert resize_material[:rule][:zoom_x] == 2.0
    assert resize_material[:rule][:zoom_y] == 1.5
    assert resize_material[:rule][:dpr] == 2.0
    assert resize_material[:rule][:effective_dpr] == :runtime_resolved
  end

  test "resize auto cache material stays unresolved and source-metadata-free" do
    assert {:ok, width} = Dimension.pixels(300)
    assert {:ok, height} = Dimension.pixels(200)
    assert {:ok, size} = Size.new(width: width, height: height, dpr: 1.0)
    assert {:ok, operation} = Operation.resize_auto(size: size, enlargement: :deny)

    semantic_plan = plan(pipelines: [%Pipeline{operations: [operation]}])
    conn = conn(:get, "/_/rt:auto/w:300/h:200/f:jpeg/plain/images/cat.jpg")

    key_a = build_key!(conn, semantic_plan, "origin-version-a")
    key_b = build_key!(conn, semantic_plan, "origin-version-b")

    assert [[material]] = key_a.material[:pipelines]

    assert material == [
             op: :resize_auto,
             size: [
               width: [unit: :logical_px, value: 300],
               height: [unit: :logical_px, value: 200],
               dpr: 1.0
             ],
             enlargement: :deny,
             guide: [type: :anchor, x: :center, y: :center, space: :current],
             min_width: nil,
             min_height: nil,
             zoom_x: 1.0,
             zoom_y: 1.0,
             x_offset: {:pixels, 0.0},
             y_offset: {:pixels, 0.0},
             rule: :imgproxy_orientation_match_v1
           ]

    serialized = Key.serialize_material(key_a.material)
    refute Keyword.has_key?(material, :selected_branch)
    refute serialized =~ "source_width"
    refute serialized =~ "source_height"
    refute serialized =~ "selected_branch"
    refute key_a.hash == key_b.hash
  end

  test "backend profile material participates in the cache key" do
    conn = conn(:get, "/_/plain/images/cat.jpg")
    default_key = build_key!(conn, plan(), "https://origin.test/images/cat.jpg")

    custom_backend = [
      backend: :vips,
      material_version: 2,
      geometry_rules_version: 1,
      orientation_policy_version: 1,
      dpr_policy_version: 1,
      smart_strategy_support: :none
    ]

    custom_key =
      build_key!(conn, plan(), "https://origin.test/images/cat.jpg",
        backend_profile: custom_backend
      )

    assert default_key.material[:pipelines] == custom_key.material[:pipelines]
    assert custom_key.material[:backend] == custom_backend
    refute default_key.hash == custom_key.hash
  end

  test "invalid backend profile material returns a tagged error" do
    assert Key.build(
             conn(:get, "/_/plain/images/cat.jpg"),
             plan(),
             "https://origin.test/images/cat.jpg",
             backend_profile: :not_a_profile
           ) == {:error, {:invalid_backend_profile, :not_a_profile}}

    invalid_profile = [{:bad, :ok} | :tail]

    assert Key.build(
             conn(:get, "/_/plain/images/cat.jpg"),
             plan(),
             "https://origin.test/images/cat.jpg",
             backend_profile: invalid_profile
           ) == {:error, {:invalid_backend_profile, invalid_profile}}
  end

  test "cache key construction does not reference source-aware resolution" do
    source =
      __DIR__
      |> Path.join("../../../lib/image_plug/cache/key.ex")
      |> Path.expand()
      |> File.read!()

    refute source =~ "Transform.resolve"
    refute source =~ "ImagePlug.Transform.Resolver"
    refute source =~ "SourceMetadata"
    refute source =~ "ResolvedPlan"
    refute source =~ "Derivation"
    refute source =~ "Resolver.Geometry"
    refute source =~ "source_width"
    refute source =~ "source_height"
  end

  test "cachebuster changes cache keys without changing pipeline material" do
    base_plan = plan()
    busted_plan = plan(cache: %ImagePlug.Plan.Cache{cachebuster: "v2"})

    conn = conn(:get, "/_/plain/images/cat.jpg")
    base = build_key!(conn, base_plan, "https://origin.test/images/cat.jpg")
    busted = build_key!(conn, busted_plan, "https://origin.test/images/cat.jpg")

    assert base.material[:pipelines] == busted.material[:pipelines]
    assert busted.material[:cache] == [cachebuster: "v2"]
    refute base.hash == busted.hash
  end

  test "response delivery metadata is excluded from cache key material" do
    one = plan(response: %ImagePlug.Plan.Response{disposition: :attachment})
    two = plan(response: %ImagePlug.Plan.Response{disposition: :inline})

    conn = conn(:get, "/_/plain/images/cat.jpg")

    assert build_key!(conn, one, "https://origin.test/images/cat.jpg").hash ==
             build_key!(conn, two, "https://origin.test/images/cat.jpg").hash
  end

  test "requests differing only by filename share cache key material" do
    one =
      plan(
        response: %ImagePlug.Plan.Response{
          disposition: :attachment,
          filename: %ImagePlug.Plan.Response.Filename{stem: "one"}
        }
      )

    two =
      plan(
        response: %ImagePlug.Plan.Response{
          disposition: :inline,
          filename: %ImagePlug.Plan.Response.Filename{stem: "two"}
        }
      )

    conn = conn(:get, "/_/plain/images/cat.jpg")

    assert build_key!(conn, one, "https://origin.test/images/cat.jpg").hash ==
             build_key!(conn, two, "https://origin.test/images/cat.jpg").hash
  end

  test "output material includes normalized quality rules" do
    output = %Output{
      mode: :automatic,
      quality: :default,
      format_qualities: %{webp: {:quality, 70}}
    }

    key =
      conn(:get, "/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/webp")
      |> build_key!(plan(output: output), "https://origin.test/images/cat.jpg")

    assert key.material[:output][:quality] == :default
    assert key.material[:output][:format_qualities] == %{webp: {:quality, 70}}
  end

  test "automatic output includes modern candidates instead of selected output or raw Accept" do
    automatic_plan = plan(output: %Output{mode: :automatic})

    conn_one =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/webp;q=1,image/avif;q=0.1")

    conn_two =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/avif,image/webp")

    key_one = build_key!(conn_one, automatic_plan, "https://origin.test/images/cat.jpg")
    key_two = build_key!(conn_two, automatic_plan, "https://origin.test/images/cat.jpg")

    assert key_one.material[:output] == [
             mode: :automatic,
             modern_candidates: [:avif, :webp],
             auto: [avif: true, webp: true],
             quality: :default,
             format_qualities: %{}
           ]

    refute inspect(key_one.material) =~ "image/webp"
    refute inspect(key_one.material) =~ "image/avif"
    assert key_one.hash == key_two.hash
  end

  test "different automatic Accept capabilities change cache key" do
    automatic_plan = plan(output: %Output{mode: :automatic})

    avif_key =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/avif")
      |> build_key!(automatic_plan, "https://origin.test/images/cat.jpg")

    webp_key =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/webp")
      |> build_key!(automatic_plan, "https://origin.test/images/cat.jpg")

    refute avif_key.hash == webp_key.hash
  end

  test "different automatic output feature flags change cache key" do
    automatic_plan = plan(output: %Output{mode: :automatic})

    conn =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/avif,image/webp")

    default_key = build_key!(conn, automatic_plan, "https://origin.test/images/cat.jpg")

    webp_only_key =
      build_key!(conn, automatic_plan, "https://origin.test/images/cat.jpg", auto_avif: false)

    refute default_key.hash == webp_only_key.hash

    assert webp_only_key.material[:output] == [
             mode: :automatic,
             modern_candidates: [:webp],
             auto: [avif: false, webp: true],
             quality: :default,
             format_qualities: %{}
           ]
  end

  test "explicit formats do not include Accept material or automatic marker" do
    conn =
      :get
      |> conn("/_/f:webp/plain/images/cat.jpg")
      |> put_req_header("accept", "image/jpeg")

    key = build_key!(conn, plan(), "https://origin.test/images/cat.jpg")

    assert key.material[:output] == [
             mode: :explicit,
             format: :webp,
             quality: :default,
             format_qualities: %{}
           ]

    refute inspect(key.material) =~ "image/jpeg"
  end

  test "only configured headers and cookies are included" do
    conn =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept-language", "en-US")
      |> put_req_header("x-ignored", "ignored")
      |> put_req_header("cookie", "tenant=acme; ignored_cookie=ignored")

    key =
      build_key!(conn, plan(), "https://origin.test/images/cat.jpg",
        key_headers: ["Accept-Language"],
        key_cookies: ["tenant"]
      )

    assert key.material[:selected_headers] == [{"accept-language", ["en-US"]}]
    assert key.material[:selected_cookies] == [{"tenant", "acme"}]
    refute inspect(key.material) =~ "x-ignored"
    refute inspect(key.material) =~ "ignored_cookie"
  end
end
