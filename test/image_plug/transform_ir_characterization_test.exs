defmodule ImagePlug.TransformIRCharacterizationTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Parser.Native
  alias ImagePlug.Runtime.RequestRunner
  alias ImagePlug.Transform.State

  defmodule CacheHitProbe do
    def get(key, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:cache_get, key})
      {:hit, Keyword.fetch!(opts, :entry)}
    end

    def put(_key, _entry, _opts), do: raise("cache hit must not write")
  end

  defmodule GeneratedOrigin do
    def call(%Plug.Conn{request_path: "/" <> basename} = conn, _opts) do
      {width, height} = dimensions_from_basename(basename)
      {:ok, image} = Image.new(width, height, color: :white)
      body = Image.write!(image, :memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end

    defp dimensions_from_basename(basename) do
      basename
      |> Path.basename()
      |> Path.rootname()
      |> String.split("x", parts: 2)
      |> case do
        [width, height] -> {String.to_integer(width), String.to_integer(height)}
      end
    end
  end

  defmodule OriginShouldNotFetch do
    def call(_conn, _opts), do: raise("origin should not fetch on cache hit")
  end

  defp parse_plan!(path) do
    conn = conn(:get, path)
    assert {:ok, plan} = Native.parse(conn, [])
    {conn, plan}
  end

  defp final_dimensions_for_auto_resize(source, target) do
    {target_width, target_height} = target
    source_basename = source_basename(source)

    path =
      "/_/rt:auto/w:#{target_width}/h:#{target_height}/f:jpeg/plain/generated/#{source_basename}"

    {conn, plan} = parse_plan!(path)

    assert {:ok, {:image, %State{image: image}, _resolved_output, _response}} =
             RequestRunner.run(
               conn,
               plan,
               "http://origin.test/#{source_basename}",
               origin_req_options: [plug: GeneratedOrigin]
             )

    {Image.width(image), Image.height(image)}
  end

  defp source_basename({width, height}), do: "#{width}x#{height}.png"

  test "cache hit returns before origin fetch for auto resize requests" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    path = "/_/rt:auto/w:100/h:100/f:jpeg/plain/images/cat-300.jpg"
    {conn, plan} = parse_plan!(path)

    assert {:ok, {:cache_entry, ^entry, %ImagePlug.Plan.Response{}}} =
             RequestRunner.run(
               conn,
               plan,
               "http://origin.test/images/cat-300.jpg",
               cache: {CacheHitProbe, entry: entry, test_pid: self()},
               origin_req_options: [plug: OriginShouldNotFetch]
             )

    assert_received {:cache_get, key}
    assert key.material[:origin_identity] == "http://origin.test/images/cat-300.jpg"
  end

  test "parser/request-level resize:auto preserves visible current dimensions" do
    # Current parser/request behavior emits AdaptiveResize plus a result Crop for
    # rt:auto. That result crop is required for visible cover output: executable
    # AdaptiveResize alone produces {100, 67} for 300x200 -> 100x50, while the
    # parsed request path below produces the final visible {100, 50}.
    cases = [
      %{source: {300, 200}, target: {100, 50}, expected: {100, 50}},
      %{source: {300, 200}, target: {50, 100}, expected: {50, 33}},
      %{source: {100, 100}, target: {50, 50}, expected: {50, 50}},
      %{source: {100, 100}, target: {50, 80}, expected: {50, 50}}
    ]

    for %{source: source, target: target, expected: expected} <- cases do
      assert final_dimensions_for_auto_resize(source, target) == expected
    end
  end
end
