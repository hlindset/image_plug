defmodule ImagePlug.Parser.ImgproxyPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Plug.Test

  alias ImagePlug.Parser.Imgproxy
  alias ImagePlug.Plan
  alias ImagePlug.Plan.Operation
  alias ImagePlug.Plan.Pipeline

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
      assert {:ok, %Plan{source: {:plain, ^source_path}}} =
               ["w:300"]
               |> imgproxy_path(source_path)
               |> parse_path()
    end
  end

  property "later width assignments overwrite earlier width assignments" do
    check all first <- integer(0..10_000),
              second <- integer(1..10_000),
              max_runs: 100 do
      assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
               ["w:#{first}", "w:#{second}"]
               |> imgproxy_path(["images", "cat.jpg"])
               |> parse_path()

      assert [%Operation.Resize{mode: :fit} = params] = operations
      assert params.width == pixels(second)
    end
  end

  property "resize meta-option overwrites atomic width and height fields by position" do
    check all width <- integer(1..10_000),
              height <- integer(1..10_000),
              max_runs: 100 do
      assert {:ok, %Plan{pipelines: [%Pipeline{operations: operations}]}} =
               ["w:999", "h:888", "rs:fill:#{width}:#{height}"]
               |> imgproxy_path(["images", "cat.jpg"])
               |> parse_path()

      assert [%Operation.Resize{mode: :cover} = params] = operations
      assert params.width == pixels(width)
      assert params.height == pixels(height)
    end
  end

  property "alias-equivalent and order-equivalent dimensions produce the same plan" do
    check all width <- integer(1..2000),
              height <- integer(1..2000) do
      assert {:ok, plan_a} =
               Imgproxy.parse(conn(:get, "/_/w:#{width}/h:#{height}/plain/images/cat.jpg"), [])

      assert {:ok, plan_b} =
               Imgproxy.parse(
                 conn(:get, "/_/height:#{height}/width:#{width}/plain/images/cat.jpg"),
                 []
               )

      assert plan_a.pipelines == plan_b.pipelines
      assert plan_a.output == plan_b.output
      assert plan_a.cachebuster == plan_b.cachebuster
    end
  end

  property "imgproxy composition URL option order does not define operation order" do
    assert {:ok, plan_a} =
             Imgproxy.parse(conn(:get, "/_/bg:f00/pd:10/w:100/plain/images/cat.jpg"), [])

    [%ImagePlug.Plan.Pipeline{operations: operations_a}] = plan_a.pipelines

    check all option_segments <- member_of(permutations(["bg:f00", "pd:10", "w:100"])) do
      assert {:ok, plan_b} =
               option_segments
               |> imgproxy_path(["images", "cat.jpg"])
               |> parse_path()

      [%ImagePlug.Plan.Pipeline{operations: operations_b}] = plan_b.pipelines

      assert operations_a == operations_b
      assert plan_a.pipelines == plan_b.pipelines
    end
  end

  defp parse_path(path), do: Imgproxy.parse(conn(:get, path), [])

  defp pixels(value), do: {:px, value}

  defp safe_parse(options) do
    options
    |> imgproxy_path(["images", "cat.jpg"])
    |> parse_path()
  rescue
    exception -> {:raised, exception}
  catch
    kind, reason -> {:caught, kind, reason}
  end

  defp imgproxy_path(options, source_path) do
    source_path = Enum.join(source_path, "/")

    case Enum.join(options, "/") do
      "" -> "/_/plain/#{source_path}"
      option_path -> "/_/#{option_path}/plain/#{source_path}"
    end
  end

  defp permutations([]), do: [[]]

  defp permutations(values) do
    for value <- values,
        tail <- permutations(values -- [value]) do
      [value | tail]
    end
  end

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
