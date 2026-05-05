defmodule ImagePlug.Cache.KeyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePlug.Cache.Key
  alias ImagePlug.OutputPlan
  alias ImagePlug.Pipeline
  alias ImagePlug.Plan
  alias ImagePlug.Source.Plain
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
                {Transform.Contain,
                 %Transform.Contain.ContainParams{
                   type: :dimensions,
                   width: {:pixels, 300},
                   height: :auto,
                   constraint: :max,
                   letterbox: false
                 }}
              ]
            },
            %Pipeline{
              operations: [
                {Transform.Crop,
                 %Transform.Crop.CropParams{
                   width: {:pixels, 200},
                   height: {:pixels, 100},
                   crop_from: :focus
                 }}
              ]
            }
          ],
          output: %OutputPlan{mode: {:explicit, :webp}}
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
             output: [mode: :explicit, format: :webp],
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

  test "automatic output includes modern candidates instead of selected output or raw Accept" do
    automatic_plan = plan(output: %OutputPlan{mode: :automatic})

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
             auto: [avif: true, webp: true]
           ]

    refute inspect(key_one.material) =~ "image/webp"
    refute inspect(key_one.material) =~ "image/avif"
    assert key_one.hash == key_two.hash
  end

  test "different automatic Accept capabilities change cache key" do
    automatic_plan = plan(output: %OutputPlan{mode: :automatic})

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
    automatic_plan = plan(output: %OutputPlan{mode: :automatic})

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
             auto: [avif: false, webp: true]
           ]
  end

  test "explicit formats do not include Accept material or automatic marker" do
    conn =
      :get
      |> conn("/_/f:webp/plain/images/cat.jpg")
      |> put_req_header("accept", "image/jpeg")

    key = build_key!(conn, plan(), "https://origin.test/images/cat.jpg")

    assert key.material[:output] == [mode: :explicit, format: :webp]
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
