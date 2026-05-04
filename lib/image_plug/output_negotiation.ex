defmodule ImagePlug.OutputNegotiation do
  @moduledoc false

  alias ImagePlug.ImageFormat

  @modern_formats [avif: "image/avif", webp: "image/webp"]

  @spec modern_candidates(String.t() | nil, keyword()) :: [:avif | :webp]
  def modern_candidates(accept_header, opts \\ []) do
    case parse_accept(accept_header) do
      [] ->
        []

      entries ->
        opts
        |> enabled_modern_formats()
        |> Enum.filter(fn {_format, mime_type} -> acceptable?(mime_type, entries) end)
        |> Enum.map(fn {format, _mime_type} -> format end)
    end
  end

  defdelegate suffix!(mime_type), to: ImageFormat

  defdelegate format(mime_type), to: ImageFormat

  defdelegate mime_type(format), to: ImageFormat

  defdelegate mime_type!(format), to: ImageFormat

  defp enabled_modern_formats(opts) do
    @modern_formats
    |> Enum.reject(fn
      {:avif, _mime_type} -> Keyword.get(opts, :auto_avif, true) == false
      {:webp, _mime_type} -> Keyword.get(opts, :auto_webp, true) == false
    end)
  end

  defp acceptable?(mime_type, entries) do
    mime_type = ImageFormat.canonical_mime_type(mime_type)

    entries =
      Enum.map(entries, fn {accepted, quality} ->
        {ImageFormat.canonical_mime_type(accepted), quality}
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
    |> String.split(",")
    |> Enum.map(&parse_accept_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_accept_entry(entry) do
    [media_range | params] =
      entry
      |> String.split(";")
      |> Enum.map(&String.trim/1)

    media_range = String.downcase(media_range)

    if media_range == "", do: nil, else: {media_range, quality_from_params(params)}
  end

  defp quality_from_params(params) do
    Enum.find_value(params, 1.0, &quality_param/1)
  end

  defp quality_param(param) do
    case String.split(param, "=", parts: 2) do
      [name, value] -> maybe_parse_quality(name, value)
      _ -> nil
    end
  end

  defp maybe_parse_quality(name, value) do
    if String.downcase(String.trim(name)) == "q", do: parse_quality(value)
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
