defmodule ImagePlug.ParamParser.NativePropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Plug.Test

  alias ImagePlug.ParamParser.Native

  property "option order does not affect parsed request" do
    check all options <- unique_valid_options(),
              source_path <- valid_source_path(),
              max_runs: 100 do
      parsed_requests =
        options
        |> permutations()
        |> Enum.map(fn permutation ->
          permutation
          |> native_path(source_path)
          |> parse_path()
        end)

      assert Enum.uniq(parsed_requests) == [hd(parsed_requests)]
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

  defp parse_path(path), do: conn(:get, path) |> Native.parse()

  defp native_path(options, source_path) do
    source_path = Enum.join(source_path, "/")

    case Enum.join(options, "/") do
      "" -> "/_/plain/#{source_path}"
      option_path -> "/_/#{option_path}/plain/#{source_path}"
    end
  end

  defp unique_valid_options do
    [:width, :height, :fit, :focus, :format]
    |> option_subsets()
    |> bind(fn fields ->
      fields
      |> Enum.map(&valid_option/1)
      |> fixed_list()
    end)
  end

  defp option_subsets([]), do: constant([])

  defp option_subsets([field | fields]) do
    bind(boolean(), fn include? ->
      map(option_subsets(fields), fn subset ->
        if include?, do: [field | subset], else: subset
      end)
    end)
  end

  defp valid_option(:width), do: map(integer(1..10_000), &"w:#{&1}")
  defp valid_option(:height), do: map(integer(1..10_000), &"h:#{&1}")
  defp valid_option(:fit), do: member_of(~w(fit:cover fit:contain fit:fill fit:inside))

  defp valid_option(:format),
    do: member_of(~w(format:auto format:webp format:avif format:jpeg format:png))

  defp valid_option(:focus) do
    one_of([
      member_of(~w(focus:center focus:top focus:bottom focus:left focus:right)),
      map({integer(0..10_000), integer(0..10_000)}, fn {x, y} -> "focus:#{x}:#{y}" end),
      map({integer(0..100), integer(0..100)}, fn {x, y} -> "focus:#{x}p:#{y}p" end)
    ])
  end

  defp valid_source_path do
    list_of(path_segment(), min_length: 1, max_length: 6)
  end

  defp valid_source_path_with_option_like_segments do
    list_of(one_of([path_segment(), option_like_path_segment()]), min_length: 1, max_length: 6)
  end

  defp path_segment do
    string(:alphanumeric, min_length: 1, max_length: 20)
  end

  defp option_like_path_segment do
    one_of([
      map(integer(1..10_000), &"w:#{&1}"),
      map(integer(1..10_000), &"h:#{&1}"),
      member_of(~w(format:webp format:png fit:cover focus:center a:b c:d))
    ])
  end

  defp permutations([]), do: [[]]

  defp permutations(list) do
    for item <- list,
        rest <- permutations(list -- [item]) do
      [item | rest]
    end
  end
end
