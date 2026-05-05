defmodule ImagePlug.Cache.KeyPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Plug.Conn
  import Plug.Test

  alias ImagePlug.Cache.Key
  alias ImagePlug.OutputPlan
  alias ImagePlug.Pipeline
  alias ImagePlug.Plan
  alias ImagePlug.Source.Plain
  alias ImagePlug.Transform

  defp build_key!(conn, plan, origin_identity, opts \\ []) do
    assert {:ok, key} = Key.build(conn, plan, origin_identity, opts)
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
        schema_version: 2,
        origin_identity: origin,
        source: [
          kind: :plain,
          path: source_path,
          nested: [
            map: %{b: 2, a: 1},
            keyword: [b: 2, a: 1]
          ]
        ],
        pipelines: [
          [
            [
              op: :contain,
              width: width,
              height: height,
              constraint: :max,
              letterbox: false
            ]
          ]
        ],
        output: [mode: :explicit, format: :webp],
        selected_headers: [],
        selected_cookies: []
      ]

      material_two = [
        selected_cookies: [],
        selected_headers: [],
        output: [format: :webp, mode: :explicit],
        pipelines: [
          [
            [
              letterbox: false,
              constraint: :max,
              height: height,
              width: width,
              op: :contain
            ]
          ]
        ],
        source: [
          nested: [
            keyword: [a: 1, b: 2],
            map: %{a: 1, b: 2}
          ],
          path: source_path,
          kind: :plain
        ],
        origin_identity: origin,
        schema_version: 2
      ]

      assert Key.serialize_material(material_one) == Key.serialize_material(material_two)
    end
  end

  property "request URL, ignored headers, and ignored cookies do not affect plan cache keys" do
    check all plan <- cacheable_plan(),
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

      assert build_key!(conn_one, plan, origin).hash ==
               build_key!(conn_two, plan, origin).hash
    end
  end

  property "included origin identity and output format change the cache key" do
    check all plan <- cacheable_plan(output: %OutputPlan{mode: {:explicit, :webp}}),
              origin_a <- origin_identity(),
              origin_b <- origin_identity(),
              origin_a != origin_b,
              max_runs: 100 do
      conn = conn(:get, "/_/f:webp/plain/images/cat.jpg")

      origin_key_a = build_key!(conn, plan, origin_a)
      origin_key_b = build_key!(conn, plan, origin_b)
      png_key = build_key!(conn, %{plan | output: %OutputPlan{mode: {:explicit, :png}}}, origin_a)

      refute origin_key_a.hash == origin_key_b.hash
      refute origin_key_a.hash == png_key.hash
    end
  end

  property "pipeline boundaries affect the cache key" do
    check all operation_a <- operation(),
              operation_b <- operation(),
              max_runs: 100 do
      one_pipeline =
        plan(pipelines: [%Pipeline{operations: [operation_a, operation_b]}])

      two_pipelines =
        plan(
          pipelines: [%Pipeline{operations: [operation_a]}, %Pipeline{operations: [operation_b]}]
        )

      conn = conn(:get, "/_/f:webp/plain/images/cat.jpg")
      origin = "https://origin.test/images/cat.jpg"

      refute build_key!(conn, one_pipeline, origin).hash ==
               build_key!(conn, two_pipelines, origin).hash
    end
  end

  property "selected headers affect the cache key when configured" do
    check all header_value_a <- string(:alphanumeric, min_length: 1, max_length: 24),
              header_value_b <- string(:alphanumeric, min_length: 1, max_length: 24),
              header_value_a != header_value_b,
              cookie_value <- string(:alphanumeric, min_length: 1, max_length: 24),
              max_runs: 100 do
      plan = plan()
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

      refute build_key!(conn_a, plan, origin, opts).hash ==
               build_key!(conn_b, plan, origin, opts).hash
    end
  end

  property "selected cookies affect the cache key when configured" do
    check all cookie_value_a <- string(:alphanumeric, min_length: 1, max_length: 24),
              cookie_value_b <- string(:alphanumeric, min_length: 1, max_length: 24),
              cookie_value_a != cookie_value_b,
              header_value <- string(:alphanumeric, min_length: 1, max_length: 24),
              max_runs: 100 do
      plan = plan()
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

      refute build_key!(conn_a, plan, origin, opts).hash ==
               build_key!(conn_b, plan, origin, opts).hash
    end
  end

  property "raw Accept headers with the same normalized class produce the same automatic key" do
    check all {accept_a, accept_b} <-
                member_of([
                  {"image/avif,image/webp", "image/webp;q=1,image/avif;q=0.1"},
                  {"image/jpeg", "image/jpg"},
                  {"image/*", "*/*"},
                  {"image/avif;q=0,image/*", "image/*,image/avif;q=0"}
                ]),
              max_runs: 100 do
      plan = plan(output: %OutputPlan{mode: :automatic})
      origin = "https://origin.test/images/cat.jpg"

      key_a =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", accept_a)
        |> build_key!(plan, origin)

      key_b =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", accept_b)
        |> build_key!(plan, origin)

      assert key_a.hash == key_b.hash
    end
  end

  property "different normalized Accept classes change automatic cache key" do
    check all {accept_a, accept_b} <-
                member_of([
                  {"image/avif", "image/webp"},
                  {"image/avif", "image/jpeg"},
                  {"image/webp", "image/jpeg"},
                  {"image/avif;q=0,image/*", "image/*"}
                ]),
              max_runs: 100 do
      plan = plan(output: %OutputPlan{mode: :automatic})
      origin = "https://origin.test/images/cat.jpg"

      key_a =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", accept_a)
        |> build_key!(plan, origin)

      key_b =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", accept_b)
        |> build_key!(plan, origin)

      refute key_a.hash == key_b.hash
    end
  end

  property "automatic cache key does not depend on runtime-selected source fallback format" do
    check all accept <- accept_header(),
              max_runs: 100 do
      plan = plan(output: %OutputPlan{mode: :automatic})
      origin = "https://origin.test/images/cat.jpg"

      key_a =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", accept)
        |> build_key!(plan, origin)

      key_b =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", accept)
        |> build_key!(plan, origin)

      assert key_a.hash == key_b.hash
    end
  end

  defp key_material do
    map(
      {origin_identity(), source_path(), pipelines(),
       member_of([:automatic, :webp, :avif, :jpeg, :png])},
      fn {origin, source_path, pipelines, output} ->
        [
          schema_version: 2,
          origin_identity: origin,
          source: [kind: :plain, path: source_path],
          pipelines: pipelines,
          output:
            if(output == :automatic,
              do: [
                mode: :automatic,
                modern_candidates: [:avif, :webp],
                auto: [avif: true, webp: true]
              ],
              else: [mode: :explicit, format: output]
            ),
          selected_headers: [],
          selected_cookies: []
        ]
      end
    )
  end

  defp cacheable_plan(overrides \\ []) do
    map({source_path(), pipeline_structs()}, fn {source_path, pipelines} ->
      plan(
        Keyword.merge(
          [
            source: %Plain{path: source_path},
            pipelines: pipelines
          ],
          overrides
        )
      )
    end)
  end

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
            }
          ],
          output: %OutputPlan{mode: {:explicit, :webp}}
        ],
        overrides
      )
    )
  end

  defp pipeline_structs do
    list_of(map(list_of(operation(), min_length: 0, max_length: 3), &%Pipeline{operations: &1}),
      min_length: 1,
      max_length: 3
    )
  end

  defp pipelines do
    list_of(list_of(operation_material(), min_length: 0, max_length: 3),
      min_length: 1,
      max_length: 3
    )
  end

  defp operation do
    one_of([
      map({maybe_dimension(), maybe_dimension()}, fn {width, height} ->
        {Transform.Contain,
         %Transform.Contain.ContainParams{
           type: :dimensions,
           width: width || {:pixels, 100},
           height: height || :auto,
           constraint: :max,
           letterbox: false
         }}
      end),
      map({pixel_dimension(), pixel_dimension()}, fn {width, height} ->
        {Transform.Crop,
         %Transform.Crop.CropParams{
           width: width,
           height: height,
           crop_from: :focus
         }}
      end)
    ])
  end

  defp operation_material do
    one_of([
      map({maybe_dimension(), maybe_dimension()}, fn {width, height} ->
        [
          op: :contain,
          type: :dimensions,
          width: width || {:pixels, 100},
          height: height || :auto,
          constraint: :max,
          letterbox: false
        ]
      end),
      map({pixel_dimension(), pixel_dimension()}, fn {width, height} ->
        [
          op: :crop,
          width: width,
          height: height,
          crop_from: :focus
        ]
      end)
    ])
  end

  defp origin_identity do
    map(source_path(), fn path -> "https://origin.test/#{Enum.join(path, "/")}" end)
  end

  defp source_path, do: list_of(path_segment(), min_length: 1, max_length: 4)
  defp path_segment, do: string(:alphanumeric, min_length: 1, max_length: 16)
  defp maybe_dimension, do: one_of([constant(nil), constant(:auto), pixel_dimension()])
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
end
