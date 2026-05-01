defmodule ImagePlug.Cache.KeyTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePlug.Cache.Key
  alias ImagePlug.ProcessingRequest

  defp request(overrides \\ []) do
    struct!(
      ProcessingRequest,
      Keyword.merge(
        [
          signature: "sig-one",
          source_kind: :plain,
          source_path: ["images", "cat.jpg"],
          width: {:pixels, 100},
          height: {:pixels, 80},
          resizing_type: :fill,
          format: :webp
        ],
        overrides
      )
    )
  end

  defp build_key!(conn, request, origin_identity, opts \\ []) do
    assert {:ok, key} = Key.build(conn, request, origin_identity, opts)
    key
  end

  test "builds stable hash and material from canonical request fields and origin identity" do
    conn = conn(:get, "/sig-one/w:100/plain/images/cat.jpg?ignored=true")

    key = build_key!(conn, request(), "https://origin-a.test/images/cat.jpg")
    same = build_key!(conn, request(), "https://origin-a.test/images/cat.jpg")
    different_origin = build_key!(conn, request(), "https://origin-b.test/images/cat.jpg")

    assert key.hash == same.hash
    assert key.hash =~ ~r/\A[0-9a-f]{64}\z/
    assert is_binary(key.serialized_material)
    assert key.material[:schema_version] == 2
    assert key.material[:origin_identity] == "https://origin-a.test/images/cat.jpg"

    assert key.material[:operations] == [
             source_kind: :plain,
             source_path: ["images", "cat.jpg"],
             width: {:pixels, 100},
             height: {:pixels, 80},
             resizing_type: :fill,
             enlarge: false,
             extend: false,
             extend_gravity: nil,
             extend_x_offset: nil,
             extend_y_offset: nil,
             gravity: {:anchor, :center, :center},
             gravity_x_offset: 0.0,
             gravity_y_offset: 0.0
           ]

    assert key.material[:output] == [format: :webp, automatic: false]
    assert key.material[:selected_headers] == []
    assert key.material[:selected_cookies] == []
    assert key.serialized_material == Key.serialize_material(key.material)
    refute Keyword.has_key?(key.material, :signature)
    refute inspect(key.material) =~ "ignored=true"
    refute key.hash == different_origin.hash
  end

  test "operations include every response-affecting processing request field" do
    request_fields =
      ProcessingRequest.__struct__() |> Map.from_struct() |> Map.keys() |> Enum.sort()

    # Signature is authorization material; format and source extension are represented separately.
    expected_operation_fields =
      request_fields -- [:format, :output_extension_from_source, :signature]

    operation_fields =
      conn(:get, "/sig-one/w:100/plain/images/cat.jpg")
      |> build_key!(request(), "https://origin.test/images/cat.jpg")
      |> then(&Keyword.fetch!(&1.material, :operations))
      |> Keyword.keys()
      |> Enum.sort()

    assert operation_fields == expected_operation_fields
  end

  test "signature changes do not change the key" do
    conn = conn(:get, "/sig-one/plain/images/cat.jpg")

    key_one =
      build_key!(conn, request(signature: "sig-one"), "https://origin.test/images/cat.jpg")

    key_two =
      build_key!(conn, request(signature: "sig-two"), "https://origin.test/images/cat.jpg")

    assert key_one.hash == key_two.hash
  end

  test "only configured headers and cookies are included" do
    conn =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept-language", "en-US")
      |> put_req_header("x-ignored", "ignored")
      |> put_req_header("cookie", "tenant=acme; ignored_cookie=ignored")

    key =
      build_key!(conn, request(), "https://origin.test/images/cat.jpg",
        key_headers: ["Accept-Language"],
        key_cookies: ["tenant"]
      )

    assert key.material[:selected_headers] == [{"accept-language", ["en-US"]}]
    assert key.material[:selected_cookies] == [{"tenant", "acme"}]
    refute inspect(key.material) =~ "x-ignored"
    refute inspect(key.material) =~ "ignored_cookie"
  end

  test "automatic output includes selected format instead of raw Accept" do
    request = request(format: nil)

    conn_one =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/webp;q=1,image/avif;q=0.1")

    conn_two =
      :get
      |> conn("/_/plain/images/cat.jpg")
      |> put_req_header("accept", "image/avif,image/webp")

    key_one =
      build_key!(conn_one, request, "https://origin.test/images/cat.jpg",
        selected_output_format: :avif
      )

    key_two =
      build_key!(conn_two, request, "https://origin.test/images/cat.jpg",
        selected_output_format: :avif
      )

    assert key_one.material[:output] == [format: :avif, automatic: true]
    assert key_one.hash == key_two.hash
  end

  test "different selected automatic output changes cache key" do
    request = request(format: nil)
    conn = conn(:get, "/_/plain/images/cat.jpg")

    avif_key =
      build_key!(conn, request, "https://origin.test/images/cat.jpg",
        selected_output_format: :avif
      )

    webp_key =
      build_key!(conn, request, "https://origin.test/images/cat.jpg",
        selected_output_format: :webp
      )

    refute avif_key.hash == webp_key.hash
  end

  test "automatic output requires a selected output format" do
    assert Key.build(
             conn(:get, "/_/plain/images/cat.jpg"),
             request(format: nil),
             "https://origin.test/images/cat.jpg"
           ) == {:error, :missing_selected_output_format}
  end

  test "explicit formats do not include Accept material or automatic marker" do
    conn =
      :get
      |> conn("/_/f:webp/plain/images/cat.jpg")
      |> put_req_header("accept", "image/jpeg")

    key = build_key!(conn, request(format: :webp), "https://origin.test/images/cat.jpg")

    assert key.material[:output] == [format: :webp, automatic: false]
  end
end
