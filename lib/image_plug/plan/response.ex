defmodule ImagePlug.Plan.Response do
  @moduledoc false

  alias ImagePlug.Plan.Response.Filename

  @content_type_extensions %{
    "image/jpeg" => "jpg",
    "image/png" => "png",
    "image/webp" => "webp",
    "image/avif" => "avif"
  }

  defstruct disposition: :default, filename: nil

  @type t :: %__MODULE__{
          disposition: :default | :inline | :attachment,
          filename: Filename.t() | nil
        }

  @spec content_disposition(t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def content_disposition(%__MODULE__{} = response, content_type) when is_binary(content_type) do
    with {:ok, extension} <- delivery_extension(content_type) do
      {:ok, render_disposition(response, extension)}
    end
  end

  defp delivery_extension(content_type) do
    case Map.fetch(@content_type_extensions, content_type) do
      {:ok, extension} -> {:ok, extension}
      :error -> {:error, {:unsupported_delivery_content_type, content_type}}
    end
  end

  defp render_disposition(%__MODULE__{filename: nil} = response, _extension) do
    disposition(response.disposition)
  end

  defp render_disposition(%__MODULE__{filename: %Filename{stem: stem}} = response, extension) do
    filename = stem <> "." <> extension
    fallback = ascii_fallback(stem) <> "." <> extension

    [
      disposition(response.disposition),
      ~s(filename="#{quoted_string(fallback)}"),
      "filename*=UTF-8''#{rfc5987_encode(filename)}"
    ]
    |> Enum.join("; ")
  end

  defp disposition(:attachment), do: "attachment"
  defp disposition(:inline), do: "inline"
  defp disposition(:default), do: "inline"

  defp ascii_fallback(stem) do
    fallback = Enum.map_join(String.graphemes(stem), &ascii_fallback_character/1)

    if String.match?(fallback, ~r/[A-Za-z0-9]/), do: fallback, else: "download"
  end

  defp ascii_fallback_character(<<char>>) when char in 32..126, do: <<char>>
  defp ascii_fallback_character(_grapheme), do: "_"

  defp quoted_string(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end

  defp rfc5987_encode(value) do
    URI.encode(value, &rfc5987_attribute_character?/1)
  end

  defp rfc5987_attribute_character?(char)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9,
       do: true

  defp rfc5987_attribute_character?(char)
       when char in [?!, ?#, ?$, ?&, ?+, ?-, ?., ?^, ?_, ?`, ?|, ?~],
       do: true

  defp rfc5987_attribute_character?(_char), do: false
end
