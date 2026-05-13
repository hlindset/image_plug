defmodule ImagePlug.Plan.Response do
  @moduledoc false

  alias ImagePlug.Plan.Response.Filename

  @delivery_content_types ["image/jpeg", "image/png", "image/webp", "image/avif"]

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
    if content_type in @delivery_content_types do
      content_type
      |> MIME.extensions()
      |> delivery_extension(content_type)
    else
      {:error, {:unsupported_delivery_content_type, content_type}}
    end
  end

  defp delivery_extension([extension | _rest], _content_type), do: {:ok, extension}

  defp delivery_extension([], content_type),
    do: {:error, {:unsupported_delivery_content_type, content_type}}

  defp render_disposition(%__MODULE__{filename: nil} = response, _extension) do
    disposition(response.disposition)
  end

  defp render_disposition(%__MODULE__{filename: %Filename{stem: stem}} = response, extension) do
    filename = stem <> "." <> extension
    encoded_filename = URI.encode(filename, &URI.char_unreserved?/1)

    disposition =
      ~s(#{disposition(response.disposition)}; filename="#{encoded_filename}")

    if encoded_filename == filename do
      disposition
    else
      disposition <> "; filename*=utf-8''#{encoded_filename}"
    end
  end

  defp disposition(:attachment), do: "attachment"
  defp disposition(:inline), do: "inline"
  defp disposition(:default), do: "inline"
end
