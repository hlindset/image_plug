defmodule ImagePlug.OutputNegotiation do
  @moduledoc false

  @modern_formats [avif: "image/avif", webp: "image/webp"]
  @formats [avif: "image/avif", webp: "image/webp", jpeg: "image/jpeg", png: "image/png"]
  @output_formats Keyword.values(@formats)

  @spec negotiate(String.t() | nil, boolean()) :: {:ok, String.t()} | {:error, :not_acceptable}
  def negotiate(accept_header, has_alpha?) do
    negotiate(accept_header, has_alpha?, [])
  end

  @spec negotiate(String.t() | nil, boolean(), keyword()) ::
          {:ok, String.t()} | {:error, :not_acceptable}
  def negotiate(accept_header, has_alpha?, opts) do
    candidates =
      Enum.uniq(
        enabled_modern_mime_types(opts) ++
          fallback_mime_types(has_alpha?, Keyword.get(opts, :source_format))
      )

    entries = parse_accept(accept_header)

    mime_type =
      case entries do
        [] ->
          hd(candidates)

        entries ->
          Enum.find(candidates, &acceptable?(&1, entries))
      end

    case mime_type do
      nil -> {:error, :not_acceptable}
      mime_type -> {:ok, mime_type}
    end
  end

  @spec preselect(String.t() | nil, keyword()) ::
          {:ok, :avif | :webp} | :defer | {:error, :not_acceptable}
  def preselect(accept_header, opts) do
    entries = parse_accept(accept_header)
    modern_formats = enabled_modern_formats(opts)

    case entries do
      [] ->
        case modern_formats do
          [{format, _mime_type} | _rest] -> {:ok, format}
          [] -> :defer
        end

      entries ->
        case Enum.find(modern_formats, fn {_format, mime_type} ->
               acceptable?(mime_type, entries)
             end) do
          {format, _mime_type} ->
            {:ok, format}

          nil ->
            if supported_output_acceptable?(entries) do
              :defer
            else
              {:error, :not_acceptable}
            end
        end
    end
  end

  @spec cache_probe_formats(String.t() | nil, keyword()) :: [:avif | :webp | :jpeg | :png]
  def cache_probe_formats(accept_header, opts \\ []) do
    entries = parse_accept(accept_header)
    formats = enabled_cache_probe_formats(opts)

    case entries do
      [] ->
        Keyword.keys(formats)

      entries ->
        formats
        |> Enum.filter(fn {_format, mime_type} -> acceptable?(mime_type, entries) end)
        |> Enum.map(fn {format, _mime_type} -> format end)
    end
  end

  def suffix!("image/avif"), do: ".avif"
  def suffix!("image/webp"), do: ".webp"
  def suffix!("image/jpeg"), do: ".jpg"
  def suffix!("image/png"), do: ".png"

  def format(mime_type) do
    case normalize_mime_type(mime_type) do
      "image/jpg" -> {:ok, :jpeg}
      mime_type -> format_from_normalized_mime_type(mime_type)
    end
  end

  defp format_from_normalized_mime_type(mime_type) do
    case Enum.find(@formats, fn {_format, candidate_mime_type} ->
           candidate_mime_type == mime_type
         end) do
      {format, _mime_type} -> {:ok, format}
      nil -> :error
    end
  end

  defp normalize_mime_type(mime_type) when is_binary(mime_type) do
    mime_type
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_mime_type(mime_type), do: mime_type

  def mime_type(format) do
    Keyword.fetch(@formats, format)
  end

  defp enabled_modern_mime_types(opts) do
    opts
    |> enabled_modern_formats()
    |> Enum.map(fn {_format, mime_type} -> mime_type end)
  end

  defp enabled_modern_formats(opts) do
    @modern_formats
    |> Enum.reject(fn
      {:avif, _mime_type} -> Keyword.get(opts, :auto_avif, true) == false
      {:webp, _mime_type} -> Keyword.get(opts, :auto_webp, true) == false
    end)
  end

  defp fallback_mime_types(has_alpha?, source_format) do
    [
      source_mime_type(source_format),
      alpha_fallback_mime_type(has_alpha?)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp alpha_fallback_mime_type(true), do: "image/png"
  defp alpha_fallback_mime_type(false), do: "image/jpeg"

  defp source_mime_type(source_format), do: Keyword.get(@formats, source_format)

  defp supported_output_acceptable?(entries) do
    Enum.any?(@output_formats, &acceptable?(&1, entries))
  end

  defp acceptable?(mime_type, entries) do
    mime_type = canonical_mime_type(mime_type)

    entries =
      Enum.map(entries, fn {accepted, quality} -> {canonical_mime_type(accepted), quality} end)

    # Exact q=0 is an explicit exclusion and wins over wildcard allowances
    # and duplicate positive exact entries.
    exact_qualities =
      entries
      |> Enum.filter(fn {accepted, _quality} -> accepted == mime_type end)
      |> Enum.map(fn {_accepted, quality} -> quality end)

    cond do
      Enum.any?(exact_qualities, &(&1 == 0)) ->
        false

      Enum.any?(exact_qualities, &(&1 > 0)) ->
        true

      true ->
        entries
        |> Enum.filter(fn {accepted, _quality} -> matches?(accepted, mime_type) end)
        |> Enum.any?(fn {_accepted, quality} -> quality > 0 end)
    end
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
        [name, value] ->
          if String.downcase(String.trim(name)) == "q", do: parse_quality(value)

        _ ->
          nil
      end
    end)
  end

  defp parse_quality(value) do
    case value |> String.trim() |> Float.parse() do
      {quality, ""} when quality >= 0.0 and quality <= 1.0 -> quality
      _ -> 0.0
    end
  end

  defp matches?(accepted, mime_type) do
    accepted == mime_type or accepted == "*/*" or image_wildcard?(accepted, mime_type)
  end

  defp image_wildcard?("image/*", "image/" <> _subtype), do: true
  defp image_wildcard?(_accepted, _mime_type), do: false

  defp canonical_mime_type(mime_type) do
    case format(mime_type) do
      {:ok, format} -> Keyword.fetch!(@formats, format)
      :error -> normalize_mime_type(mime_type)
    end
  end

  defp enabled_cache_probe_formats(opts) do
    @formats
    |> Enum.reject(fn
      {:avif, _mime_type} -> Keyword.get(opts, :auto_avif, true) == false
      {:webp, _mime_type} -> Keyword.get(opts, :auto_webp, true) == false
      {_format, _mime_type} -> false
    end)
  end
end
