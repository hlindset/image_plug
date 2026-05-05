defmodule ImagePlug.Parser.NativePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Plug.Test

  alias ImagePlug.Parser.Native
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Pipeline
  alias ImagePlug.Plan.Source.Plain
  alias ImagePlug.Transform

  property "parser returns tagged results for arbitrary processing segments" do
    check all segments <- list_of(processing_segment(), max_length: 5),
              max_runs: 300 do
      result = safe_parse(segments)

      assert match?({tag, _reason_or_request} when tag in [:ok, :error], result),
             "parser raised or threw instead of returning tagged result: #{inspect(result)}"
    end
  end

  property "segments after plain are preserved as source path" do
    check all source_path <- valid_source_path_with_option_like_segments(),
              max_runs: 100 do
      assert {:ok, %Plan{source: %Plain{path: ^source_path}}} =
               ["w:300"]
               |> native_path(source_path)
               |> parse_path()
    end
  end

  property "later width assignments overwrite earlier width assignments" do
    check all first <- integer(0..10_000),
              second <- integer(1..10_000),
              max_runs: 100 do
      assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
               ["w:#{first}", "w:#{second}"]
               |> native_path(["images", "cat.jpg"])
               |> parse_path()

      assert [%Transform.Resize{} = params] = operations
      assert params.rule.width == {:pixels, second}
    end
  end

  property "resize meta-option overwrites atomic width and height fields by position" do
    check all width <- integer(1..10_000),
              height <- integer(1..10_000),
              max_runs: 100 do
      assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
               ["w:999", "h:888", "rs:fill:#{width}:#{height}"]
               |> native_path(["images", "cat.jpg"])
               |> parse_path()

      assert [%Transform.Resize{} = params] = operations
      assert params.rule.mode == :fill
      assert params.rule.width == {:pixels, width}
      assert params.rule.height == {:pixels, height}
    end
  end

  property "alias-equivalent and order-equivalent dimensions produce the same plan" do
    check all width <- integer(1..2000),
              height <- integer(1..2000) do
      assert {:ok, plan_a} =
               Native.parse(conn(:get, "/_/w:#{width}/h:#{height}/plain/images/cat.jpg"), [])

      assert {:ok, plan_b} =
               Native.parse(
                 conn(:get, "/_/height:#{height}/width:#{width}/plain/images/cat.jpg"),
                 []
               )

      assert plan_a.pipelines == plan_b.pipelines
      assert plan_a.output == plan_b.output
      assert plan_a.cache == plan_b.cache
    end
  end

  property "zoom aliases parse to equivalent native pipeline IR" do
    check all x <- integer(1..2000),
              y <- integer(1..2000) do
      x = decimal_string(x)
      y = decimal_string(y)

      assert {:ok, zoom_request} =
               Native.parse_request(conn(:get, "/_/zoom:#{x}:#{y}/plain/images/cat.jpg"), [])

      assert {:ok, alias_request} =
               Native.parse_request(conn(:get, "/_/z:#{x}:#{y}/plain/images/cat.jpg"), [])

      [zoom_pipeline] = zoom_request.pipelines
      [alias_pipeline] = alias_request.pipelines
      assert zoom_pipeline.zoom_x == alias_pipeline.zoom_x
      assert zoom_pipeline.zoom_y == alias_pipeline.zoom_y
    end
  end

  defp parse_path(path), do: Native.parse(conn(:get, path), [])

  defp safe_parse(options) do
    options
    |> native_path(["images", "cat.jpg"])
    |> parse_path()
  rescue
    exception -> {:raised, exception}
  catch
    kind, reason -> {:caught, kind, reason}
  end

  defp native_path(options, source_path) do
    source_path = Enum.join(source_path, "/")

    case Enum.join(options, "/") do
      "" -> "/_/plain/#{source_path}"
      option_path -> "/_/#{option_path}/plain/#{source_path}"
    end
  end

  defp decimal_string(value), do: :erlang.float_to_binary(value / 10, decimals: 1)

  defp valid_source_path_with_option_like_segments do
    list_of(one_of([path_segment(), option_like_path_segment()]), min_length: 1, max_length: 6)
  end

  defp path_segment do
    string(:alphanumeric, min_length: 1, max_length: 20)
  end

  defp option_like_path_segment do
    one_of([
      map(integer(0..10_000), &"w:#{&1}"),
      map(integer(0..10_000), &"h:#{&1}"),
      member_of(~w(f:webp ext:png rs:fill:100:100 g:ce a:b c:d))
    ])
  end

  defp processing_segment do
    printable =
      ?!..?~
      |> Enum.reject(&(&1 in [?/, ??, ?#, ?%]))
      |> Enum.map(&<<&1>>)

    printable
    |> member_of()
    |> list_of(max_length: 40)
    |> map(&Enum.join/1)
  end
end
