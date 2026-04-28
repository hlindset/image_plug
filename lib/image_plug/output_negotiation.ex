defmodule ImagePlug.OutputNegotiation do
  @moduledoc false

  @alpha_format_priority ~w(image/avif image/webp image/png)
  @no_alpha_format_priority ~w(image/avif image/webp image/jpeg)
  @fallback_formats ~w(image/jpeg image/png)

  @spec negotiate(String.t() | nil, boolean()) :: {:ok, String.t()} | {:error, :not_acceptable}
  def negotiate(accept_header, has_alpha?) do
    priority =
      if has_alpha?,
        do: @alpha_format_priority,
        else: @no_alpha_format_priority

    entries = parse_accept(accept_header)

    mime_type =
      case entries do
        [] ->
          hd(priority)

        entries ->
          negotiate_from_entries(priority, entries)
      end

    case mime_type do
      nil -> {:error, :not_acceptable}
      mime_type -> {:ok, mime_type}
    end
  end

  def suffix!("image/avif"), do: ".avif"
  def suffix!("image/webp"), do: ".webp"
  def suffix!("image/jpeg"), do: ".jpg"
  def suffix!("image/png"), do: ".png"

  defp negotiate_from_entries(priority, entries) do
    priority
    |> Enum.with_index()
    |> Enum.map(fn {mime_type, index} -> {mime_type, quality_for(entries, mime_type), index} end)
    |> Enum.filter(fn {_mime_type, quality, _index} -> quality > 0 end)
    |> Enum.max_by(fn {_mime_type, quality, index} -> {quality, -index} end, fn ->
      fallback_format(priority, entries)
    end)
    |> case do
      {mime_type, _quality, _index} -> mime_type
      mime_type -> mime_type
    end
  end

  defp fallback_format(priority, entries) do
    Enum.find(priority, &fallback_allowed?(&1, entries)) ||
      Enum.find(priority, &(not excluded?(&1, entries)))
  end

  defp fallback_allowed?(mime_type, entries) when mime_type in @fallback_formats do
    !excluded?(mime_type, entries)
  end

  defp fallback_allowed?(_mime_type, _entries), do: false

  defp excluded?(mime_type, entries) do
    Enum.any?(entries, fn {accepted, quality} ->
      quality == 0 and matches?(accepted, mime_type)
    end)
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

    cond do
      media_range == "" ->
        nil

      true ->
        {media_range, quality_from_params(params)}
    end
  end

  defp quality_from_params(params) do
    params
    |> Enum.find_value(1.0, fn param ->
      case String.split(param, "=", parts: 2) do
        ["q", value] -> parse_quality(value)
        _ -> nil
      end
    end)
  end

  defp parse_quality(value) do
    case Float.parse(value) do
      {quality, ""} when quality >= 0.0 and quality <= 1.0 -> quality
      _ -> 0.0
    end
  end

  defp quality_for(entries, mime_type) do
    exact_qualities =
      entries
      |> Enum.filter(fn {accepted, _quality} -> accepted == mime_type end)
      |> Enum.map(fn {_accepted, quality} -> quality end)

    case exact_qualities do
      [] ->
        entries
        |> Enum.filter(fn {accepted, _quality} -> matches?(accepted, mime_type) end)
        |> Enum.map(fn {_accepted, quality} -> quality end)
        |> Enum.max(fn -> 0.0 end)

      qualities ->
        Enum.max(qualities)
    end
  end

  defp matches?(accepted, mime_type) do
    accepted == mime_type or accepted == "*/*" or image_wildcard?(accepted, mime_type)
  end

  defp image_wildcard?("image/*", "image/" <> _subtype), do: true
  defp image_wildcard?(_accepted, _mime_type), do: false
end
