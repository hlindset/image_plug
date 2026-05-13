defmodule ImagePlug.Cache.KeyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePlug.Cache.Key
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Output
  alias ImagePlug.Plan.Pipeline

  defp plan(overrides \\ []) do
    struct!(
      Plan,
      Keyword.merge(
        [
          source: {:plain, ["images", "cat.jpg"]},
          pipelines: [
            %Pipeline{
              operations: [resize_fit_operation(300, :auto)]
            },
            %Pipeline{
              operations: [crop_guided_operation(200, 100)]
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

  defp plan_with_resize_auto do
    plan(pipelines: [%Pipeline{operations: [resize_auto_operation(300, 200)]}])
  end

  defp resize_fit_operation(width, height, attrs \\ []) do
    operation_attrs =
      attrs
      |> Keyword.put_new(:enlargement, :deny)

    assert {:ok, operation} =
             Operation.resize(
               :fit,
               tagged_resize_dimension(width),
               tagged_resize_dimension(height),
               operation_attrs
             )

    operation
  end

  defp crop_guided_operation(width, height) do
    assert {:ok, operation} =
             Operation.crop_guided(tagged_dimension(width), tagged_dimension(height), :center)

    operation
  end

  defp resize_auto_operation(width, height) do
    assert {:ok, operation} =
             Operation.resize(
               :auto,
               tagged_resize_dimension(width),
               tagged_resize_dimension(height),
               dpr: 1.0,
               enlargement: :deny
             )

    operation
  end

  defp tagged_dimension(:auto), do: :full_axis
  defp tagged_dimension(pixels), do: {:px, pixels}
  defp tagged_resize_dimension(:auto), do: :auto
  defp tagged_resize_dimension(pixels), do: {:px, pixels}

  test "builds stable hash and key data from canonical plan fields and origin identity" do
    conn = conn(:get, "/sig-one/w:100/plain/images/cat.jpg?ignored=true")

    key = build_key!(conn, plan(), "https://origin-a.test/images/cat.jpg")
    same = build_key!(conn, plan(), "https://origin-a.test/images/cat.jpg")
    different_origin = build_key!(conn, plan(), "https://origin-b.test/images/cat.jpg")

    assert key.hash == same.hash
    assert key.hash =~ ~r/\A[0-9a-f]{64}\z/
    assert is_binary(key.serialized_data)

    assert key.data == [
             schema_version: 2,
             origin_identity: "https://origin-a.test/images/cat.jpg",
             source: [kind: :plain, path: ["images", "cat.jpg"]],
             pipelines: [
               [
                 [
                   op: :resize,
                   mode: :fit,
                   width: [unit: :logical_px, value: 300],
                   height: [unit: :auto],
                   dpr: [unit: :ratio, numerator: 1, denominator: 1],
                   enlargement: :deny,
                   guide: :center,
                   x_offset: {:pixels, 0.0},
                   y_offset: {:pixels, 0.0},
                   min_width: nil,
                   min_height: nil,
                   zoom_x: 1.0,
                   zoom_y: 1.0
                 ]
               ],
               [
                 [
                   op: :crop_guided,
                   width: [unit: :logical_px, value: 200],
                   height: [unit: :logical_px, value: 100],
                   guide: :center,
                   x_offset: {:pixels, 0.0},
                   y_offset: {:pixels, 0.0}
                 ]
               ]
             ],
             transform: [key_data_version: 1],
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

    assert key.serialized_data == Key.serialize_key_data(key.data)
    refute inspect(key.data) =~ "sig-one"
    refute inspect(key.data) =~ "ignored=true"
    refute key.hash == different_origin.hash
  end

  test "source key data is product-neutral and independent of request URL" do
    conn_one = conn(:get, "/sig-one/w:100/plain/images/cat.jpg")
    conn_two = conn(:get, "/sig-two/width:100/plain/ignored/path.jpg?ignored=true")

    key_one = build_key!(conn_one, plan(), "https://origin.test/images/cat.jpg")
    key_two = build_key!(conn_two, plan(), "https://origin.test/images/cat.jpg")

    assert key_one.data[:source] == [kind: :plain, path: ["images", "cat.jpg"]]
    assert key_one.hash == key_two.hash
  end

  test "pipelines key data preserves pipeline boundaries" do
    key =
      conn(:get, "/_/f:webp/plain/images/cat.jpg")
      |> build_key!(plan(), "https://origin.test/images/cat.jpg")

    assert key.data[:pipelines] == [
             [
               [
                 op: :resize,
                 mode: :fit,
                 width: [unit: :logical_px, value: 300],
                 height: [unit: :auto],
                 dpr: [unit: :ratio, numerator: 1, denominator: 1],
                 enlargement: :deny,
                 guide: :center,
                 x_offset: {:pixels, 0.0},
                 y_offset: {:pixels, 0.0},
                 min_width: nil,
                 min_height: nil,
                 zoom_x: 1.0,
                 zoom_y: 1.0
               ]
             ],
             [
               [
                 op: :crop_guided,
                 width: [unit: :logical_px, value: 200],
                 height: [unit: :logical_px, value: 100],
                 guide: :center,
                 x_offset: {:pixels, 0.0},
                 y_offset: {:pixels, 0.0}
               ]
             ]
           ]
  end

  test "pipelines key data uses canonical operations instead of raw transform tuples or structs" do
    key =
      conn(:get, "/_/f:webp/plain/images/cat.jpg")
      |> build_key!(plan(), "https://origin.test/images/cat.jpg")

    refute inspect(key.data[:pipelines]) =~ "ImagePlug.Transform"

    assert key.data[:pipelines]
           |> Enum.flat_map(& &1)
           |> Enum.all?(&Keyword.keyword?/1)
  end

  test "unified resize operation contributes prefetch-safe cache key data" do
    assert {:ok, operation} =
             Operation.resize(:auto, {:px, 300}, {:px, 200},
               dpr: "1.00",
               enlargement: :deny
             )

    key =
      conn(:get, "/_/rt:auto/w:300/h:200/f:webp/plain/images/cat.jpg")
      |> build_key!(
        plan(pipelines: [%Pipeline{operations: [operation]}]),
        "https://origin.test/images/cat.jpg"
      )

    assert key.data[:pipelines] == [
             [
               [
                 op: :resize,
                 mode: :auto,
                 width: [unit: :logical_px, value: 300],
                 height: [unit: :logical_px, value: 200],
                 dpr: [unit: :ratio, numerator: 1, denominator: 1],
                 enlargement: :deny,
                 guide: :center,
                 x_offset: {:pixels, 0.0},
                 y_offset: {:pixels, 0.0},
                 min_width: nil,
                 min_height: nil,
                 zoom_x: 1.0,
                 zoom_y: 1.0,
                 rule: :imgproxy_orientation_match_v1
               ]
             ]
           ]

    refute inspect(key.data[:pipelines]) =~ "selected_branch"
    refute inspect(key.data[:pipelines]) =~ "resize_auto"
  end

  test "crop operations contribute prefetch-safe cache key data" do
    assert {:ok, guided} =
             Operation.crop_guided({:px, 120}, :full_axis, :bottom_right, x_offset: {:pixels, 3})

    assert {:ok, region} =
             Operation.crop_region({:px, 0}, {:ratio, 0, 1}, {:ratio, 1, 2}, {:px, 80})

    key =
      conn(:get, "/_/plain/images/cat.jpg")
      |> build_key!(
        plan(pipelines: [%Pipeline{operations: [guided, region]}]),
        "https://origin.test/images/cat.jpg"
      )

    assert key.data[:pipelines] == [
             [
               [
                 op: :crop_guided,
                 width: [unit: :logical_px, value: 120],
                 height: [unit: :full_axis],
                 guide: :bottom_right,
                 x_offset: {:pixels, 3},
                 y_offset: {:pixels, 0.0}
               ],
               [
                 op: :crop_region,
                 x: [unit: :logical_px, value: 0],
                 y: [unit: :ratio, numerator: 0, denominator: 1],
                 width: [unit: :ratio, numerator: 1, denominator: 2],
                 height: [unit: :logical_px, value: 80]
               ]
             ]
           ]
  end

  test "resize key data includes requested zoom and dpr rule inputs" do
    operation = resize_fit_operation(100, :auto, dpr: 2.0, zoom_x: 2.0, zoom_y: 1.5)

    key =
      conn(:get, "/_/plain/images/cat.jpg")
      |> build_key!(
        plan(pipelines: [%Pipeline{operations: [operation]}]),
        "https://origin.test/images/cat.jpg"
      )

    assert [[resize_data]] = key.data[:pipelines]
    assert resize_data[:op] == :resize
    assert resize_data[:mode] == :fit
    assert resize_data[:dpr] == [unit: :ratio, numerator: 2, denominator: 1]
    assert resize_data[:zoom_x] == 2.0
    assert resize_data[:zoom_y] == 1.5
  end

  test "resize auto cache key data stays unresolved and source-metadata-free" do
    operation = resize_auto_operation(300, 200)

    semantic_plan = plan(pipelines: [%Pipeline{operations: [operation]}])
    conn = conn(:get, "/_/rt:auto/w:300/h:200/f:jpeg/plain/images/cat.jpg")

    key_a = build_key!(conn, semantic_plan, "origin-version-a")
    key_b = build_key!(conn, semantic_plan, "origin-version-b")

    assert [[key_data]] = key_a.data[:pipelines]

    assert key_data == [
             op: :resize,
             mode: :auto,
             width: [unit: :logical_px, value: 300],
             height: [unit: :logical_px, value: 200],
             dpr: [unit: :ratio, numerator: 1, denominator: 1],
             enlargement: :deny,
             guide: :center,
             x_offset: {:pixels, 0.0},
             y_offset: {:pixels, 0.0},
             min_width: nil,
             min_height: nil,
             zoom_x: 1.0,
             zoom_y: 1.0,
             rule: :imgproxy_orientation_match_v1
           ]

    serialized = Key.serialize_key_data(key_a.data)
    refute Keyword.has_key?(key_data, :selected_branch)
    refute serialized =~ "source_width"
    refute serialized =~ "source_height"
    refute serialized =~ "selected_branch"
    refute key_a.hash == key_b.hash
  end

  test "unified resize offsets participate in cache key data" do
    assert {:ok, no_offset} = Operation.resize(:cover, {:px, 300}, {:px, 200})

    assert {:ok, with_offset} =
             Operation.resize(:cover, {:px, 300}, {:px, 200},
               x_offset: {:pixels, 12.0},
               y_offset: {:scale, -0.25}
             )

    conn = conn(:get, "/_/rs:fill:300:200/f:jpeg/plain/images/cat.jpg")

    no_offset_key =
      build_key!(
        conn,
        plan(pipelines: [%Pipeline{operations: [no_offset]}]),
        "https://origin.test/images/cat.jpg"
      )

    with_offset_key =
      build_key!(
        conn,
        plan(pipelines: [%Pipeline{operations: [with_offset]}]),
        "https://origin.test/images/cat.jpg"
      )

    assert [[resize_data]] = with_offset_key.data[:pipelines]
    assert resize_data[:x_offset] == {:pixels, 12.0}
    assert resize_data[:y_offset] == {:scale, -0.25}
    refute no_offset_key.data[:pipelines] == with_offset_key.data[:pipelines]
  end

  test "post-fetch resize auto branch is not accepted as final output cache key input" do
    conn = conn(:get, "/_/rt:auto/w:300/h:200/plain/images/cat.jpg")
    key_before = build_key!(conn, plan_with_resize_auto(), "origin-version-1")

    key_after_resolve = build_key!(conn, plan_with_resize_auto(), "origin-version-1")
    serialized = Key.serialize_key_data(key_before.data)

    assert key_before == key_after_resolve
    assert [[key_data]] = key_before.data[:pipelines]
    assert key_data[:op] == :resize
    assert key_data[:mode] == :auto
    refute Keyword.has_key?(key_data, :selected_branch)
    refute Keyword.has_key?(key_data, :branch)
    refute serialized =~ "resize_auto_branch"
    refute serialized =~ "selected_branch"
    refute Keyword.has_key?(key_before.data, :derivations)
  end

  test "cache key builder accepts semantic plans" do
    assert {:ok, key} =
             Key.build(
               conn(:get, "/_/rt:auto/w:300/h:200/plain/images/cat.jpg"),
               plan_with_resize_auto(),
               "origin-version-1"
             )

    assert key.data[:pipelines]
  end

  test "source freshness identity changes cache key without changing semantic key data" do
    conn = conn(:get, "/_/rt:auto/w:300/h:200/plain/images/cat.jpg")
    semantic_plan = plan_with_resize_auto()

    key_a = build_key!(conn, semantic_plan, "asset:cat:v1")
    key_a_same = build_key!(conn, semantic_plan, "asset:cat:v1")
    key_b = build_key!(conn, semantic_plan, "asset:cat:v2")

    assert key_a.hash == key_a_same.hash
    assert key_a.data[:pipelines] == key_b.data[:pipelines]
    refute key_a.hash == key_b.hash
  end

  test "transform key data version participates in the cache key" do
    conn = conn(:get, "/_/plain/images/cat.jpg")
    key = build_key!(conn, plan(), "https://origin.test/images/cat.jpg")
    changed_data = Keyword.put(key.data, :transform, key_data_version: 2)
    changed_serialized_data = Key.serialize_key_data(changed_data)

    assert key.data[:transform] == [key_data_version: 1]
    refute key.serialized_data == changed_serialized_data

    refute key.hash ==
             Base.encode16(:crypto.hash(:sha256, changed_serialized_data), case: :lower)
  end

  test "cache key construction does not reference source-aware resolution" do
    source =
      __DIR__
      |> Path.join("../../../lib/image_plug/cache/key.ex")
      |> Path.expand()
      |> File.read!()

    refute source =~ "Transform.resolve"
    refute source =~ "SourceMetadata"
    refute source =~ "source_width"
    refute source =~ "source_height"
  end

  test "cachebuster changes cache keys without changing pipeline key data" do
    base_plan = plan()
    busted_plan = plan(cachebuster: "v2")

    conn = conn(:get, "/_/plain/images/cat.jpg")
    base = build_key!(conn, base_plan, "https://origin.test/images/cat.jpg")
    busted = build_key!(conn, busted_plan, "https://origin.test/images/cat.jpg")

    assert base.data[:pipelines] == busted.data[:pipelines]
    assert busted.data[:cache] == [cachebuster: "v2"]
    refute base.hash == busted.hash
  end

  test "response delivery metadata is excluded from cache key data" do
    one = plan(response: %ImagePlug.Plan.Response{disposition: :attachment})
    two = plan(response: %ImagePlug.Plan.Response{disposition: :inline})

    conn = conn(:get, "/_/plain/images/cat.jpg")

    assert build_key!(conn, one, "https://origin.test/images/cat.jpg").hash ==
             build_key!(conn, two, "https://origin.test/images/cat.jpg").hash
  end

  test "requests differing only by filename share cache key data" do
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

  test "output key data includes normalized quality rules" do
    output = %Output{
      mode: :automatic,
      quality: :default,
      format_qualities: %{webp: {:quality, 70}}
    }

    key =
      conn(:get, "/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/webp")
      |> build_key!(plan(output: output), "https://origin.test/images/cat.jpg")

    assert key.data[:output][:quality] == :default
    assert key.data[:output][:format_qualities] == %{webp: {:quality, 70}}
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

    assert key_one.data[:output] == [
             mode: :automatic,
             modern_candidates: [:avif, :webp],
             auto: [avif: true, webp: true],
             quality: :default,
             format_qualities: %{}
           ]

    refute inspect(key_one.data) =~ "image/webp"
    refute inspect(key_one.data) =~ "image/avif"
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

    assert webp_only_key.data[:output] == [
             mode: :automatic,
             modern_candidates: [:webp],
             auto: [avif: false, webp: true],
             quality: :default,
             format_qualities: %{}
           ]
  end

  test "explicit formats do not include Accept key data or automatic marker" do
    conn =
      :get
      |> conn("/_/f:webp/plain/images/cat.jpg")
      |> put_req_header("accept", "image/jpeg")

    key = build_key!(conn, plan(), "https://origin.test/images/cat.jpg")

    assert key.data[:output] == [
             mode: :explicit,
             format: :webp,
             quality: :default,
             format_qualities: %{}
           ]

    refute inspect(key.data) =~ "image/jpeg"
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

    assert key.data[:selected_headers] == [{"accept-language", ["en-US"]}]
    assert key.data[:selected_cookies] == [{"tenant", "acme"}]
    refute inspect(key.data) =~ "x-ignored"
    refute inspect(key.data) =~ "ignored_cookie"
  end
end
