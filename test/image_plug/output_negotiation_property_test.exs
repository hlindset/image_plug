defmodule ImagePlug.OutputNegotiationPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePlug.OutputNegotiation

  @modern_mime_types ~w(image/avif image/webp)

  property "negotiate follows media-range specificity and server candidate order" do
    check all accept_header <- accept_header(),
              opts <- negotiation_opts(),
              max_runs: 100 do
      assert OutputNegotiation.negotiate(accept_header, opts) ==
               expected_negotiation(accept_header, opts)
    end
  end

  property "disabled modern formats are not selected for jpeg/png/unknown sources" do
    check all accept_header <- accept_header(),
              source_format <- member_of([nil, :jpeg, :png]),
              max_runs: 100 do
      result =
        OutputNegotiation.negotiate(accept_header,
          auto_avif: false,
          auto_webp: false,
          source_format: source_format
        )

      case result do
        {:ok, mime_type} -> refute mime_type in @modern_mime_types
        {:error, :not_acceptable} -> assert true
      end
    end
  end

  property "unknown source format does not invent JPEG or PNG when modern formats are disabled" do
    check all accept_header <- accept_header(),
              max_runs: 100 do
      result =
        OutputNegotiation.negotiate(accept_header,
          auto_avif: false,
          auto_webp: false,
          source_format: nil
        )

      assert result == {:error, :not_acceptable}
    end
  end

  defp negotiation_opts do
    map(
      {boolean(), boolean(), member_of([nil, :avif, :webp, :jpeg, :png])},
      fn {auto_avif?, auto_webp?, source_format} ->
        [auto_avif: auto_avif?, auto_webp: auto_webp?, source_format: source_format]
      end
    )
  end

  defp expected_negotiation(accept_header, opts) do
    entries = parse_accept(accept_header)

    opts
    |> candidates()
    |> Enum.find(fn mime_type -> acceptable?(mime_type, entries) end)
    |> case do
      nil -> {:error, :not_acceptable}
      mime_type -> {:ok, mime_type}
    end
  end

  defp candidates(opts) do
    []
    |> maybe_append(Keyword.get(opts, :auto_avif, true), "image/avif")
    |> maybe_append(Keyword.get(opts, :auto_webp, true), "image/webp")
    |> maybe_append_source_format(Keyword.get(opts, :source_format))
    |> Enum.uniq()
  end

  defp maybe_append(candidates, true, mime_type), do: candidates ++ [mime_type]
  defp maybe_append(candidates, false, _mime_type), do: candidates

  defp maybe_append_source_format(candidates, source_format) do
    case source_format do
      :avif -> candidates ++ ["image/avif"]
      :webp -> candidates ++ ["image/webp"]
      :jpeg -> candidates ++ ["image/jpeg"]
      :png -> candidates ++ ["image/png"]
      nil -> candidates
    end
  end

  defp acceptable?(_mime_type, []), do: true

  defp acceptable?(mime_type, entries) do
    entries
    |> matching_qualities(mime_type)
    |> case do
      [] -> false
      qualities -> Enum.any?(qualities, &(&1 > 0)) and not Enum.any?(qualities, &(&1 == 0))
    end
  end

  defp matching_qualities(entries, mime_type) do
    entries
    |> Enum.group_by(fn {accepted, _quality} -> match_specificity(accepted, mime_type) end)
    |> then(fn qualities_by_specificity ->
      [:exact, :image, :global]
      |> Enum.find_value([], fn specificity ->
        qualities_by_specificity
        |> Map.get(specificity, [])
        |> Enum.map(fn {_accepted, quality} -> quality end)
        |> case do
          [] -> nil
          qualities -> qualities
        end
      end)
    end)
  end

  defp match_specificity(accepted, mime_type) do
    cond do
      canonical_mime_type(accepted) == mime_type -> :exact
      accepted == "image/*" -> :image
      accepted == "*/*" -> :global
      true -> :none
    end
  end

  defp parse_accept(""), do: []

  defp parse_accept(accept_header) do
    accept_header
    |> String.split(",")
    |> Enum.map(fn entry ->
      [media_range | params] = String.split(entry, ";")

      quality =
        Enum.find_value(params, 1.0, fn param ->
          case String.split(param, "=", parts: 2) do
            ["q", value] -> String.to_float(value)
            _other -> nil
          end
        end)

      {String.downcase(media_range), quality}
    end)
  end

  defp canonical_mime_type("image/jpg"), do: "image/jpeg"
  defp canonical_mime_type(mime_type), do: mime_type

  defp accept_header do
    one_of([
      constant(""),
      map(list_of(media_range_with_optional_quality(), min_length: 1, max_length: 5), fn ranges ->
        Enum.join(ranges, ",")
      end)
    ])
  end

  defp media_range_with_optional_quality do
    one_of([
      media_range(),
      map({media_range(), integer(0..10)}, fn {range, q} -> "#{range};q=#{q / 10}" end)
    ])
  end

  defp media_range do
    member_of([
      "image/avif",
      "image/webp",
      "image/jpeg",
      "image/png",
      "image/gif",
      "application/json",
      "image/*",
      "*/*"
    ])
  end
end
