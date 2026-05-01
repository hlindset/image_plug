defmodule ImagePlug.Cache.KeyPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Plug.Conn
  import Plug.Test

  alias ImagePlug.Cache.Key
  alias ImagePlug.ParamParser.Native
  alias ImagePlug.ProcessingRequest

  defp build_key!(conn, request, origin_identity, opts \\ []) do
    assert {:ok, key} = Key.build(conn, request, origin_identity, opts)
    key
  end

  property "cache key serialization is deterministic for canonical material" do
    check all material <- key_material(),
              max_runs: 100 do
      assert Key.serialize_material(material) == Key.serialize_material(material)
    end
  end

  property "nested map and keyword ordering does not affect serialized key material" do
    check all origin <- origin_identity(),
              source_path <- source_path(),
              width <- maybe_dimension(),
              height <- maybe_dimension(),
              max_runs: 100 do
      material_one = [
        schema_version: 1,
        origin_identity: origin,
        operations: [
          source_kind: :plain,
          source_path: source_path,
          width: width,
          height: height,
          nested: [
            map: %{b: 2, a: 1},
            keyword: [b: 2, a: 1]
          ]
        ],
        output: [format: :webp, automatic: false],
        selected_headers: [],
        selected_cookies: []
      ]

      material_two = [
        selected_cookies: [],
        selected_headers: [],
        output: [automatic: false, format: :webp],
        operations: [
          nested: [
            keyword: [a: 1, b: 2],
            map: %{a: 1, b: 2}
          ],
          height: height,
          width: width,
          source_path: source_path,
          source_kind: :plain
        ],
        origin_identity: origin,
        schema_version: 1
      ]

      assert Key.serialize_material(material_one) == Key.serialize_material(material_two)
    end
  end

  property "excluded request fields do not affect the cache key" do
    check all request <- cacheable_request(),
              signature <- string(:alphanumeric, min_length: 1, max_length: 24),
              query <- string(:alphanumeric, max_length: 24),
              ignored_header_value <- string(:alphanumeric, max_length: 24),
              ignored_cookie_value <- string(:alphanumeric, max_length: 24),
              max_runs: 100 do
      origin = "https://origin.test/images/cat.jpg"

      conn_one = conn(:get, "/_/plain/images/cat.jpg")

      conn_two =
        :get
        |> conn("/#{signature}/plain/changed/path.jpg?#{query}")
        |> put_req_header("x-ignored", ignored_header_value)
        |> put_req_header("cookie", "ignored=#{ignored_cookie_value}")

      request_two = %{request | signature: signature}

      assert build_key!(conn_one, request, origin).hash ==
               build_key!(conn_two, request_two, origin).hash
    end
  end

  property "included origin identity and output format change the cache key" do
    check all request <- cacheable_request(format: :webp),
              origin_a <- origin_identity(),
              origin_b <- origin_identity(),
              origin_a != origin_b,
              max_runs: 100 do
      conn = conn(:get, "/_/f:webp/plain/images/cat.jpg")

      origin_key_a = build_key!(conn, request, origin_a)
      origin_key_b = build_key!(conn, request, origin_b)
      png_key = build_key!(conn, %ProcessingRequest{request | format: :png}, origin_a)

      refute origin_key_a.hash == origin_key_b.hash
      refute origin_key_a.hash == png_key.hash
    end
  end

  property "selected headers affect the cache key when configured" do
    check all header_value_a <- string(:alphanumeric, min_length: 1, max_length: 24),
              header_value_b <- string(:alphanumeric, min_length: 1, max_length: 24),
              header_value_a != header_value_b,
              cookie_value <- string(:alphanumeric, min_length: 1, max_length: 24),
              max_runs: 100 do
      request = request(format: :webp)
      origin = "https://origin.test/images/cat.jpg"

      conn_a =
        :get
        |> conn("/_/f:webp/plain/images/cat.jpg")
        |> put_req_header("accept-language", header_value_a)
        |> put_req_header("cookie", "tenant=#{cookie_value}")

      conn_b =
        :get
        |> conn("/_/f:webp/plain/images/cat.jpg")
        |> put_req_header("accept-language", header_value_b)
        |> put_req_header("cookie", "tenant=#{cookie_value}")

      opts = [key_headers: ["accept-language"], key_cookies: ["tenant"]]

      refute build_key!(conn_a, request, origin, opts).hash ==
               build_key!(conn_b, request, origin, opts).hash
    end
  end

  property "selected cookies affect the cache key when configured" do
    check all cookie_value_a <- string(:alphanumeric, min_length: 1, max_length: 24),
              cookie_value_b <- string(:alphanumeric, min_length: 1, max_length: 24),
              cookie_value_a != cookie_value_b,
              header_value <- string(:alphanumeric, min_length: 1, max_length: 24),
              max_runs: 100 do
      request = request(format: :webp)
      origin = "https://origin.test/images/cat.jpg"

      conn_a =
        :get
        |> conn("/_/f:webp/plain/images/cat.jpg")
        |> put_req_header("accept-language", header_value)
        |> put_req_header("cookie", "tenant=#{cookie_value_a}")

      conn_b =
        :get
        |> conn("/_/f:webp/plain/images/cat.jpg")
        |> put_req_header("accept-language", header_value)
        |> put_req_header("cookie", "tenant=#{cookie_value_b}")

      opts = [key_headers: ["accept-language"], key_cookies: ["tenant"]]

      refute build_key!(conn_a, request, origin, opts).hash ==
               build_key!(conn_b, request, origin, opts).hash
    end
  end

  property "raw Accept headers do not affect automatic cache key when selected output is same" do
    check all accept_a <- accept_header(),
              accept_b <- accept_header(),
              selected_output <- member_of([:avif, :webp, :jpeg, :png]),
              max_runs: 100 do
      request = request(format: nil)
      origin = "https://origin.test/images/cat.jpg"

      key_a =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", accept_a)
        |> build_key!(request, origin,
          selected_output_format: selected_output,
          selected_output_reason: :auto
        )

      key_b =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", accept_b)
        |> build_key!(request, origin,
          selected_output_format: selected_output,
          selected_output_reason: :auto
        )

      assert key_a.hash == key_b.hash
    end
  end

  property "selected automatic output changes automatic cache key" do
    check all accept <- accept_header(),
              selected_output_a <- member_of([:avif, :webp, :jpeg, :png]),
              selected_output_b <- member_of([:avif, :webp, :jpeg, :png]),
              selected_output_a != selected_output_b,
              max_runs: 100 do
      request = request(format: nil)
      origin = "https://origin.test/images/cat.jpg"

      key_a =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", accept)
        |> build_key!(request, origin,
          selected_output_format: selected_output_a,
          selected_output_reason: :auto
        )

      key_b =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", accept)
        |> build_key!(request, origin,
          selected_output_format: selected_output_b,
          selected_output_reason: :auto
        )

      refute key_a.hash == key_b.hash
    end
  end

  property "automatic output selection reason changes automatic cache key" do
    check all accept <- accept_header(),
              selected_output <- member_of([:avif, :webp, :jpeg, :png]),
              reason_a <- member_of([:auto, :source, :fallback]),
              reason_b <- member_of([:auto, :source, :fallback]),
              reason_a != reason_b,
              max_runs: 100 do
      request = request(format: nil)
      origin = "https://origin.test/images/cat.jpg"

      key_a =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", accept)
        |> build_key!(request, origin,
          selected_output_format: selected_output,
          selected_output_reason: reason_a
        )

      key_b =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", accept)
        |> build_key!(request, origin,
          selected_output_format: selected_output,
          selected_output_reason: reason_b
        )

      refute key_a.hash == key_b.hash
    end
  end

  property "semantically equivalent option aliases produce equivalent requests and cache keys" do
    check all {option_a, option_b} <- equivalent_option_pair(),
              max_runs: 100 do
      origin = "https://origin.test/images/cat.jpg"
      conn_a = conn(:get, "/_/#{option_a}/plain/images/cat.jpg")
      conn_b = conn(:get, "/_/#{option_b}/plain/images/cat.jpg")

      assert {:ok, request_a} = Native.parse(conn_a)
      assert {:ok, request_b} = Native.parse(conn_b)
      assert request_a == request_b

      key_opts = [selected_output_format: :webp, selected_output_reason: :auto]

      assert build_key!(conn_a, request_a, origin, key_opts).hash ==
               build_key!(conn_b, request_b, origin, key_opts).hash
    end
  end

  defp key_material do
    map(
      {origin_identity(), cacheable_request(), member_of([nil, :webp, :avif, :jpeg, :png]),
       boolean()},
      fn
        {origin, request, format, automatic} ->
          [
            schema_version: 1,
            origin_identity: origin,
            operations: [
              source_kind: request.source_kind,
              source_path: request.source_path,
              width: request.width,
              height: request.height,
              resizing_type: request.resizing_type,
              enlarge: request.enlarge,
              extend: request.extend,
              extend_gravity: request.extend_gravity,
              extend_x_offset: request.extend_x_offset,
              extend_y_offset: request.extend_y_offset,
              gravity: request.gravity,
              gravity_x_offset: request.gravity_x_offset,
              gravity_y_offset: request.gravity_y_offset
            ],
            output: [format: format, automatic: automatic],
            selected_headers: [],
            selected_cookies: []
          ]
      end
    )
  end

  defp cacheable_request(overrides \\ []) do
    map(
      {source_path(), maybe_dimension(), maybe_dimension(),
       member_of([:fit, :fill, :fill_down, :force, :auto])},
      fn {source_path, width, height, resizing_type} ->
        request(
          Keyword.merge(
            [
              source_path: source_path,
              width: width,
              height: height,
              resizing_type: resizing_type
            ],
            overrides
          )
        )
      end
    )
  end

  defp request(attrs) do
    struct!(
      ProcessingRequest,
      Keyword.merge(
        [
          signature: "_",
          source_kind: :plain,
          source_path: ["images", "cat.jpg"],
          format: :webp
        ],
        attrs
      )
    )
  end

  defp origin_identity do
    map(source_path(), fn path -> "https://origin.test/#{Enum.join(path, "/")}" end)
  end

  defp source_path, do: list_of(path_segment(), min_length: 1, max_length: 4)
  defp path_segment, do: string(:alphanumeric, min_length: 1, max_length: 16)
  defp maybe_dimension, do: one_of([constant(nil), pixel_dimension()])
  defp pixel_dimension, do: map(integer(1..10_000), &{:pixels, &1})

  defp accept_header do
    map(list_of(media_range_with_optional_quality(), max_length: 5), &Enum.join(&1, ","))
  end

  defp media_range_with_optional_quality do
    one_of([
      media_range(),
      map({media_range(), integer(0..10)}, fn {range, q} -> "#{range}; q=#{q / 10}" end)
    ])
  end

  defp media_range do
    member_of(["image/avif", "image/webp", "image/jpeg", "image/png", "image/*", "*/*"])
  end

  defp equivalent_option_pair do
    one_of([
      map(integer(0..10_000), &{"w:#{&1}", "width:#{&1}"}),
      map(integer(0..10_000), &{"h:#{&1}", "height:#{&1}"}),
      map(member_of(~w(webp avif jpeg jpg png)), &{"f:#{&1}", "format:#{&1}"}),
      map(member_of(~w(webp avif jpeg jpg png)), &{"ext:#{&1}", "format:#{&1}"}),
      map(member_of(~w(fit fill fill-down force auto)), &{"rt:#{&1}", "resizing_type:#{&1}"})
    ])
  end
end
