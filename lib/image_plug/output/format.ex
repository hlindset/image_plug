defmodule ImagePlug.Output.Format do
  @moduledoc false

  @formats [avif: "image/avif", webp: "image/webp", jpeg: "image/jpeg", png: "image/png"]

  @spec all() :: keyword(String.t())
  def all, do: @formats

  @spec mime_types() :: [String.t()]
  def mime_types, do: Keyword.values(@formats)

  @spec suffix(String.t()) :: {:ok, String.t()} | {:error, term()}
  def suffix(mime_type) do
    case format(mime_type) do
      {:ok, format} -> {:ok, suffix_from_format(format)}
      {:error, _reason} = error -> error
    end
  end

  @spec suffix!(String.t()) :: String.t()
  def suffix!(mime_type) do
    case suffix(mime_type) do
      {:ok, suffix} -> suffix
      {:error, reason} -> raise ArgumentError, "unsupported output MIME type: #{inspect(reason)}"
    end
  end

  @spec format(term()) :: {:ok, :avif | :webp | :jpeg | :png} | {:error, term()}
  def format(mime_type) do
    case normalize_mime_type(mime_type) do
      "image/jpg" -> {:ok, :jpeg}
      mime_type -> format_from_normalized_mime_type(mime_type)
    end
  end

  @spec mime_type(atom()) :: {:ok, String.t()} | :error
  def mime_type(format), do: Keyword.fetch(@formats, format)

  @spec mime_type!(atom()) :: String.t()
  def mime_type!(format), do: Keyword.fetch!(@formats, format)

  @spec canonical_mime_type(term()) :: term()
  def canonical_mime_type(mime_type) do
    case format(mime_type) do
      {:ok, format} -> Keyword.fetch!(@formats, format)
      {:error, {:unsupported_output_format, _mime_type}} -> normalize_mime_type(mime_type)
    end
  end

  defp format_from_normalized_mime_type(mime_type) do
    case Enum.find(@formats, fn {_format, candidate_mime_type} ->
           candidate_mime_type == mime_type
         end) do
      {format, _mime_type} -> {:ok, format}
      nil -> {:error, {:unsupported_output_format, mime_type}}
    end
  end

  defp suffix_from_format(:avif), do: ".avif"
  defp suffix_from_format(:webp), do: ".webp"
  defp suffix_from_format(:jpeg), do: ".jpg"
  defp suffix_from_format(:png), do: ".png"

  defp normalize_mime_type(mime_type) when is_binary(mime_type) do
    mime_type
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_mime_type(mime_type), do: mime_type
end
