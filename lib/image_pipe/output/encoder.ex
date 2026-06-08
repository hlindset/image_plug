defmodule ImagePipe.Output.Encoder do
  @moduledoc false

  alias ImagePipe.Format
  alias ImagePipe.Output.Resolved
  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.MutableImage, as: VixMutableImage

  @doc """
  The output encoder's hard per-dimension limit for `format`, used by
  `ImagePipe.Output.Clamp` to keep encoding from failing. `:infinity` means no
  practical limit. Sourced from libvips encoder constraints (cf. imgproxy
  `processing/fix_size.go`). #150 uses only `:max_dimension`; #165 will extend
  the returned map with a `:max_pixels` budget when its caller makes that live.
  """
  @spec encoder_limit(Format.output_format()) :: %{max_dimension: pos_integer() | :infinity}
  def encoder_limit(:webp), do: %{max_dimension: 16_383}
  def encoder_limit(:avif), do: %{max_dimension: 16_384}
  def encoder_limit(:jpeg), do: %{max_dimension: 65_535}
  def encoder_limit(:png), do: %{max_dimension: :infinity}

  @spec stream_output(VixImage.t(), Resolved.t(), keyword()) ::
          {:ok, Enumerable.t(), String.t()}
          | {:error, {:encode, Exception.t(), list()}}
          | {:error, {:decode, term()}}
  def stream_output(%VixImage{} = image, %Resolved{} = resolved_output, opts) do
    with {:ok, mime_type, suffix} <- output_format(resolved_output),
         {:ok, finalized} <- finalize(image, resolved_output) do
      image_module = Keyword.get(opts, :image_module, Image)
      stream = image_module.stream!(finalized, output_options(suffix, resolved_output))
      {:ok, stream, mime_type}
    end
  rescue
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  end

  # Metadata removal requires realizing pixels (Vix `mutate` -> `copy_memory`).
  # We realize ONCE via copy_memory here, in the producer's own call stack, so a
  # corrupt-source failure is a returnable {:error, ...} (mapped to a 415 decode
  # error) instead of the uncatchable producer crash that an in-`mutate`
  # copy_memory (linked MutableImage GenServer) would cause. Subsequent mutates
  # run on the in-memory image and cannot fail that way. Stay lazy when there is
  # nothing to strip.
  defp finalize(image, %Resolved{strip_metadata: false, strip_color_profile: false}),
    do: {:ok, image}

  defp finalize(image, %Resolved{} = resolved) do
    case VixImage.copy_memory(image) do
      {:ok, mem} -> {:ok, strip(mem, resolved)}
      {:error, reason} -> {:error, {:decode, reason}}
    end
  end

  # scp only (strip_metadata is false here, so we reached finalize via scp): drop
  # just the ICC profile, keep exif/xmp/iptc.
  defp strip(image, %Resolved{strip_metadata: false}),
    do: remove_fields(image, ["icc-profile-data"])

  # strip_metadata true: remove EXIF/XMP/IPTC, keeping copyright/artist iff kcr.
  # `minimize_metadata` enumerates and removes ALL metadata header fields — crucially
  # the individual `exif-ifd0-*`/`exif-gps-*` entries, which survive removing just the
  # serialized "exif-data" blob and would otherwise be re-serialized into EXIF on
  # encode (leaking GPS/copyright). It also removes the ICC profile, so restore the
  # profile when scp is off. If minimize_metadata fails (malformed/absent EXIF), fall
  # back to blob removal — there is no valid copyright to preserve in that case.
  defp strip(image, %Resolved{} = resolved) do
    keep = if resolved.keep_copyright, do: [:copyright, :artist], else: []
    icc = if resolved.strip_color_profile, do: nil, else: header_value(image, "icc-profile-data")

    minimized =
      case Image.minimize_metadata(image, keep: keep) do
        {:ok, stripped} ->
          stripped

        {:error, _} ->
          remove_fields(image, ["exif-data", "xmp-data", "iptc-data"] ++ icc_fields(resolved))
      end

    restore_icc(minimized, icc)
  end

  defp icc_fields(%Resolved{strip_color_profile: true}), do: ["icc-profile-data"]
  defp icc_fields(%Resolved{}), do: []

  # Explicit string field names via Vix mutate. We deliberately avoid:
  #   * the libvips `strip` write flag (it also removes the ICC profile);
  #   * `Image.remove_metadata(_, :xmp)` — `image` v0.67 maps :xmp -> "xmp-dataa"
  #     (a typo), silently retaining XMP;
  #   * default `remove_metadata`/`minimize_metadata` field-enumeration on the
  #     non-kcr paths — they over-strip the ICC profile.
  defp remove_fields(image, fields) do
    {:ok, image} =
      VixImage.mutate(image, fn mut ->
        Enum.each(fields, &VixMutableImage.remove(mut, &1))
        :ok
      end)

    image
  end

  defp header_value(image, field) do
    case VixImage.header_value(image, field) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp restore_icc(image, nil), do: image

  defp restore_icc(image, icc) do
    {:ok, image} =
      VixImage.mutate(image, fn mut ->
        VixMutableImage.set(mut, "icc-profile-data", :VipsBlob, icc)
        :ok
      end)

    image
  end

  defp output_format(%Resolved{format: format}) when is_atom(format) do
    case Format.mime_type(format) do
      {:ok, mime_type} -> {:ok, mime_type, Format.suffix!(mime_type)}
      :error -> {:error, {:encode, unsupported_output_format_error(format), []}}
    end
  end

  defp unsupported_output_format_error(format) do
    ArgumentError.exception("unsupported output format: #{inspect(format)}")
  end

  defp output_options(suffix, %Resolved{quality: {:quality, value}}),
    do: [suffix: suffix, quality: value]

  defp output_options(suffix, %Resolved{quality: :default}), do: [suffix: suffix]
end
