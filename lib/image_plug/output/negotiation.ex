defmodule ImagePlug.Output.Negotiation do
  @moduledoc false

  alias ImagePlug.Output.Format

  @modern_formats [avif: "image/avif", webp: "image/webp"]

  @spec modern_candidates(String.t() | nil, keyword()) :: [:avif | :webp]
  def modern_candidates(accept_header, opts \\ []) do
    case parse_accept(accept_header) do
      [] ->
        []

      entries ->
        opts
        |> enabled_modern_formats()
        |> Enum.flat_map(&modern_candidate(&1, entries))
    end
  end

  defdelegate suffix(mime_type), to: Format

  defdelegate suffix!(mime_type), to: Format

  defdelegate format(mime_type), to: Format

  defdelegate mime_type(format), to: Format

  defdelegate mime_type!(format), to: Format

  defp enabled_modern_formats(opts) do
    enabled? = %{
      avif: Keyword.get(opts, :auto_avif, true),
      webp: Keyword.get(opts, :auto_webp, true)
    }

    Enum.reject(@modern_formats, fn {format, _mime_type} ->
      not Map.fetch!(enabled?, format)
    end)
  end

  defp modern_candidate({format, mime_type}, entries) do
    if acceptable?(mime_type, entries), do: [format], else: []
  end

  defp acceptable?(mime_type, entries) do
    mime_type = Format.canonical_mime_type(mime_type)

    entries =
      Enum.map(entries, fn {accepted, quality} ->
        {Format.canonical_mime_type(accepted), quality}
      end)

    entries
    |> matching_qualities(mime_type)
    |> acceptable_quality?()
  end

  defp matching_qualities(entries, mime_type) do
    entries
    |> Enum.group_by(fn {accepted, _quality} -> match_specificity(accepted, mime_type) end)
    |> qualities_for_best_specificity()
  end

  defp qualities_for_best_specificity(qualities_by_specificity) do
    Enum.find_value([:exact, :image, :global], [], fn specificity ->
      quality_values(qualities_by_specificity, specificity)
    end)
  end

  defp quality_values(qualities_by_specificity, specificity) do
    qualities =
      qualities_by_specificity
      |> Map.get(specificity, [])
      |> Enum.map(fn {_accepted, quality} -> quality end)

    if qualities == [], do: nil, else: qualities
  end

  defp match_specificity(accepted, mime_type) do
    cond do
      accepted == mime_type -> :exact
      image_wildcard?(accepted, mime_type) -> :image
      accepted == "*/*" -> :global
      true -> :none
    end
  end

  # q=0 at the selected specificity is an explicit exclusion and wins over
  # duplicate positive entries of the same specificity.
  defp acceptable_quality?(qualities) do
    Enum.any?(qualities, &(&1 > 0)) and not Enum.any?(qualities, &(&1 == 0))
  end

  defp parse_accept(nil), do: []

  defp parse_accept(accept_header) do
    accept_header
    |> Plug.Conn.Utils.list()
    |> Enum.map(&parse_accept_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_accept_entry(entry) do
    case Plug.Conn.Utils.media_type(entry) do
      {:ok, type, subtype, params} -> {type <> "/" <> subtype, quality_from_params(params)}
      :error -> nil
    end
  end

  defp quality_from_params(params) do
    params
    |> Map.get("q", "1.0")
    |> parse_quality()
  end

  defp parse_quality(value) do
    case value |> String.trim() |> Float.parse() do
      {quality, ""} when quality >= 0.0 and quality <= 1.0 -> quality
      _ -> 0.0
    end
  end

  defp image_wildcard?("image/*", "image/" <> _subtype), do: true
  defp image_wildcard?(_accepted, _mime_type), do: false
end
