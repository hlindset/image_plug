defmodule ImagePlug.OutputNegotiation do
  @moduledoc false

  alias ImagePlug.ImageFormat

  @modern_formats [avif: "image/avif", webp: "image/webp"]
  @formats ImageFormat.all()
  @output_formats ImageFormat.mime_types()

  @spec accept_class(String.t() | nil) :: keyword(boolean())
  def accept_class(accept_header) do
    entries = parse_accept(accept_header)

    Enum.map(@formats, fn {format, mime_type} ->
      accepted? =
        case entries do
          [] -> true
          entries -> acceptable?(mime_type, entries)
        end

      {format, accepted?}
    end)
  end

  @spec negotiate(String.t() | nil, keyword()) :: {:ok, String.t()} | {:error, :not_acceptable}
  def negotiate(accept_header, opts \\ []) do
    case negotiate_selection(accept_header, opts) do
      {:ok, {mime_type, _reason}} -> {:ok, mime_type}
      {:error, :not_acceptable} -> {:error, :not_acceptable}
    end
  end

  @spec negotiate_selection(String.t() | nil, keyword()) ::
          {:ok, {String.t(), :auto | :source}} | {:error, :not_acceptable}
  def negotiate_selection(accept_header, opts \\ []) do
    candidates = negotiation_candidates(opts)
    entries = parse_accept(accept_header)

    case select_candidate(candidates, entries) do
      {_format, mime_type, reason} -> {:ok, {mime_type, reason}}
      nil -> {:error, :not_acceptable}
    end
  end

  @spec preselect(String.t() | nil, keyword()) ::
          {:ok, :avif | :webp} | :defer | {:error, :not_acceptable}
  def preselect(accept_header, opts) do
    accept_header
    |> parse_accept()
    |> preselect_from_entries(enabled_modern_formats(opts))
  end

  defdelegate suffix!(mime_type), to: ImageFormat

  defdelegate format(mime_type), to: ImageFormat

  defdelegate mime_type(format), to: ImageFormat

  defdelegate mime_type!(format), to: ImageFormat

  defp select_candidate(candidates, []), do: List.first(candidates)

  defp select_candidate(candidates, entries) do
    Enum.find(candidates, fn {_format, mime_type, _reason} ->
      acceptable?(mime_type, entries)
    end)
  end

  defp enabled_modern_formats(opts) do
    @modern_formats
    |> Enum.reject(fn
      {:avif, _mime_type} -> Keyword.get(opts, :auto_avif, true) == false
      {:webp, _mime_type} -> Keyword.get(opts, :auto_webp, true) == false
    end)
  end

  defp negotiation_candidates(opts) do
    modern_candidates =
      opts
      |> enabled_modern_formats()
      |> Enum.map(fn {format, mime_type} -> {format, mime_type, :auto} end)

    (modern_candidates ++ source_format_candidates(Keyword.get(opts, :source_format)))
    |> uniq_candidate_mime_types()
  end

  defp source_format_candidates(nil), do: []

  defp source_format_candidates(source_format) do
    case Keyword.fetch(@formats, source_format) do
      {:ok, mime_type} -> [{source_format, mime_type, :source}]
      :error -> []
    end
  end

  defp preselect_from_entries([], [{format, _mime_type} | _rest]), do: {:ok, format}
  defp preselect_from_entries([], []), do: :defer

  defp preselect_from_entries(entries, modern_formats) do
    case Enum.find(modern_formats, fn {_format, mime_type} -> acceptable?(mime_type, entries) end) do
      {format, _mime_type} -> {:ok, format}
      nil -> preselect_deferred(entries)
    end
  end

  defp preselect_deferred(entries) do
    if supported_output_acceptable?(entries), do: :defer, else: {:error, :not_acceptable}
  end

  defp uniq_candidate_mime_types(candidates),
    do: Enum.uniq_by(candidates, fn {_format, mime_type, _reason} -> mime_type end)

  defp supported_output_acceptable?(entries) do
    Enum.any?(@output_formats, &acceptable?(&1, entries))
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

  defp image_wildcard?("image/*", "image/" <> _subtype), do: true
  defp image_wildcard?(_accepted, _mime_type), do: false

end
