defmodule ImagePlug.OutputNegotiationPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePlug.OutputNegotiation

  @modern_mime_types ~w(image/avif image/webp)
  @supported_mime_types ~w(image/avif image/webp image/jpeg image/png)

  property "negotiate returns only supported output MIME types" do
    check all accept_header <- accept_header(),
              opts <- negotiation_opts(),
              max_runs: 100 do
      case OutputNegotiation.negotiate(accept_header, opts) do
        {:ok, mime_type} -> assert mime_type in @supported_mime_types
        {:error, :not_acceptable} -> assert true
      end
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
