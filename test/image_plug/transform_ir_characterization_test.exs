defmodule ImagePlug.TransformIRCharacterizationTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Parser.Imgproxy
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
    def call(%Plug.Conn{request_path: "/" <> path} = conn, _opts) do
      {width, height} = dimensions_from_path(path)
      {:ok, image} = Image.new(width, height, color: :white)
      body = Image.write!(image, :memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end

    defp dimensions_from_path(path) do
      path
      |> Path.basename()
      |> Path.rootname()
      |> String.split("x", parts: 2)
      |> then(fn [width, height] -> {String.to_integer(width), String.to_integer(height)} end)
    end
  end

  defmodule OriginShouldNotFetch do
    def call(_conn, _opts), do: raise("origin should not fetch on cache hit")
  end

  defp parse_plan!(path) do
    conn = conn(:get, path)
    assert {:ok, plan} = Imgproxy.parse(conn, [])
    {conn, plan}
  end

  defp assert_auto_resize_dimensions(source, target, expected) do
    path = auto_resize_path(source, target)
    {conn, plan} = parse_plan!(path)
    origin_identity = origin_identity(source)

    assert {:ok, {:image, %State{image: image}, _resolved_output, _response}} =
             RequestRunner.run(
               conn,
               plan,
               origin_identity,
               origin_req_options: [plug: GeneratedOrigin]
             )

    assert {Image.width(image), Image.height(image)} == expected
  end

  defp auto_resize_path(source, {target_width, target_height}) do
    "/_/rt:auto/w:#{target_width}/h:#{target_height}/f:jpeg/plain/generated/#{source_basename(source)}"
  end

  defp origin_identity(source), do: "http://origin.test/generated/#{source_basename(source)}"

  defp source_basename({width, height}), do: "#{width}x#{height}.png"

  test "cache hit returns before origin fetch for resize:auto requests" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    source = {300, 200}
    path = auto_resize_path(source, {100, 100})
    {conn, plan} = parse_plan!(path)
    origin_identity = origin_identity(source)

    assert {:ok, {:cache_entry, ^entry, %ImagePlug.Plan.Response{}}} =
             RequestRunner.run(
               conn,
               plan,
               origin_identity,
               cache: {CacheHitProbe, entry: entry, test_pid: self()},
               origin_req_options: [plug: OriginShouldNotFetch]
             )

    assert_received {:cache_get, key}
    assert key.data[:origin_identity] == origin_identity
  end

  test "1. request-level resize:auto from 300x200 to 100x50 returns 100x50" do
    assert_auto_resize_dimensions({300, 200}, {100, 50}, {100, 50})
  end

  test "2. request-level resize:auto from 300x200 to 50x100 returns 50x33" do
    assert_auto_resize_dimensions({300, 200}, {50, 100}, {50, 33})
  end

  test "3. request-level resize:auto from 100x100 to 50x50 returns 50x50" do
    assert_auto_resize_dimensions({100, 100}, {50, 50}, {50, 50})
  end

  test "4. request-level resize:auto from 100x100 to 50x80 returns 50x50" do
    assert_auto_resize_dimensions({100, 100}, {50, 80}, {50, 50})
  end
end
