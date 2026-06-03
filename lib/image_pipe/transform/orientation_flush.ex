defmodule ImagePipe.Transform.OrientationFlush do
  @moduledoc false
  # Applies pending orientation pixels late (EXIF ∘ user rotate ∘ user flip),
  # then copy_memory, then clears pending. The single place orientation pixels are
  # written. EXIF is replayed via Image.autorotate ONLY when auto_rotate? is true:
  # autorotate reads the live EXIF tag, so calling it for an ar:0 source that still
  # carries a tag would wrongly apply suppressed EXIF rotation.

  alias ImagePipe.Transform.{PendingOrientation, State}
  alias Vix.Vips.Image, as: VipsImage

  @spec flush(State.t()) :: {:ok, State.t()} | {:error, term()}
  def flush(%State{pending_orientation: nil} = state), do: materialize(state)

  def flush(%State{pending_orientation: %PendingOrientation{} = po} = state) do
    with {:ok, image} <- prepare_random_access(state.image, po),
         {:ok, image} <- apply_orientation(image, po),
         {:ok, image} <- VipsImage.copy_memory(image) do
      {:ok, %State{state | image: image, materialized?: true, pending_orientation: nil}}
    end
  end

  # A quarter-turn rotate (90°/270°) or a vertical flip reads its source out of
  # row order, which the lazy `access: :sequential` decode (DecodePlanner) cannot
  # satisfy: applying the orientation to a streamed source and then `copy_memory`
  # trips the sequential-access wall ("Failed to memory copy image") once the
  # image is large enough that libvips can't silently buffer it. So when the
  # pending orientation needs arbitrary pixel access, materialize the *un-rotated*
  # image to RAM first (mirroring the old eager AutoOrient), giving the rotate a
  # random-access source. A plain sequential read into RAM always succeeds; the
  # rotate then runs over the buffer and the trailing copy_memory holds.
  #
  # Identity (combined angle 0, no vertical flip) and a pure horizontal flip are
  # sequential-safe — they read rows in order — so they skip the pre-copy and
  # preserve the streaming fast path. This mirrors #143's classification (only
  # EXIF orientations 1/2 stream; 3-8 materialize).
  defp prepare_random_access(image, %PendingOrientation{} = po) do
    if needs_random_access?(po) do
      VipsImage.copy_memory(image)
    else
      {:ok, image}
    end
  end

  defp needs_random_access?(%PendingOrientation{} = po) do
    rem(po.exif_angle + po.user_angle, 360) != 0 or po.user_flip_y
  end

  defp materialize(%State{} = state) do
    case VipsImage.copy_memory(state.image) do
      {:ok, image} -> {:ok, %State{state | image: image, materialized?: true}}
      {:error, _} = error -> error
    end
  end

  defp apply_orientation(image, %PendingOrientation{} = po) do
    with {:ok, image} <- maybe_autorotate(image, po),
         {:ok, image} <- maybe_rotate(image, po.user_angle),
         {:ok, image} <- maybe_flip(image, :horizontal, po.user_flip_x) do
      maybe_flip(image, :vertical, po.user_flip_y)
    end
  end

  defp maybe_autorotate(image, %PendingOrientation{auto_rotate?: true}) do
    case Image.autorotate(image) do
      {:ok, {image, _flags}} -> {:ok, image}
      {:error, _} = error -> error
    end
  end

  defp maybe_autorotate(image, %PendingOrientation{auto_rotate?: false}), do: {:ok, image}

  defp maybe_rotate(image, 0), do: {:ok, image}
  defp maybe_rotate(image, angle), do: Image.rotate(image, angle)

  defp maybe_flip(image, _axis, false), do: {:ok, image}
  defp maybe_flip(image, axis, true), do: Image.flip(image, axis)
end
