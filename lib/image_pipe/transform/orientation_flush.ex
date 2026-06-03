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
    with {:ok, image} <- apply_orientation(state.image, po),
         {:ok, image} <- VipsImage.copy_memory(image) do
      {:ok, %State{state | image: image, materialized?: true, pending_orientation: nil}}
    end
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
