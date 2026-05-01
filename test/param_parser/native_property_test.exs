defmodule ImagePlug.ParamParser.NativePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Plug.Test

  alias ImagePlug.ParamParser.Native

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
      assert {:ok, request} =
               ["w:300"]
               |> native_path(source_path)
               |> parse_path()

      assert request.source_path == source_path
    end
  end

  property "later width assignments overwrite earlier width assignments" do
    check all first <- integer(0..10_000),
              second <- integer(0..10_000),
              max_runs: 100 do
      assert {:ok, request} =
               ["w:#{first}", "w:#{second}"]
               |> native_path(["images", "cat.jpg"])
               |> parse_path()

      assert request.width == {:pixels, second}
    end
  end

  property "resize meta-option overwrites atomic width and height fields by position" do
    check all width <- integer(0..10_000),
              height <- integer(0..10_000),
              max_runs: 100 do
      assert {:ok, request} =
               ["w:999", "h:888", "rs:fill:#{width}:#{height}"]
               |> native_path(["images", "cat.jpg"])
               |> parse_path()

      assert request.width == {:pixels, width}
      assert request.height == {:pixels, height}
      assert request.resizing_type == :fill
    end
  end

  defp parse_path(path), do: conn(:get, path) |> Native.parse()

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
