defmodule ImagePlug.Transform.SourceMetadata do
  @moduledoc """
  Source properties available after origin fetch/open that are not available
  from the current image.
  """

  @orientations [:normal, :unknown]
  @source_types [:raster, :animated_raster, :vector]
  @keys [:orientation, :has_alpha?, :format, :source_type]

  defstruct orientation: :unknown,
            has_alpha?: false,
            format: nil,
            source_type: :raster

  @type orientation :: :normal | :unknown | {:exif, 1..8}
  @type source_type :: :raster | :animated_raster | :vector

  @type t :: %__MODULE__{
          orientation: orientation(),
          has_alpha?: boolean(),
          format: atom() | nil,
          source_type: source_type()
        }

  @type error :: {:invalid_source_metadata, term()} | {:unknown_source_metadata_options, [atom()]}

  @spec new(keyword()) :: {:ok, t()} | {:error, error()}
  def new(attrs) when is_list(attrs) do
    with :ok <- validate_known_options(attrs) do
      attrs
      |> then(&struct!(__MODULE__, &1))
      |> validate_new()
    end
  end

  @spec validate(t()) :: :ok | {:error, error()}
  def validate(%__MODULE__{} = metadata) do
    with :ok <- validate_orientation(metadata.orientation),
         :ok <- validate_has_alpha(metadata.has_alpha?),
         :ok <- validate_format(metadata.format) do
      validate_source_type(metadata.source_type)
    end
  end

  defp validate_orientation(orientation) when orientation in @orientations, do: :ok
  defp validate_orientation({:exif, value}) when is_integer(value) and value in 1..8, do: :ok

  defp validate_orientation(orientation),
    do: {:error, {:invalid_source_metadata, {:orientation, orientation}}}

  defp validate_has_alpha(value) when is_boolean(value), do: :ok

  defp validate_has_alpha(value),
    do: {:error, {:invalid_source_metadata, {:has_alpha?, value}}}

  defp validate_format(nil), do: :ok
  defp validate_format(format) when is_atom(format), do: :ok
  defp validate_format(format), do: {:error, {:invalid_source_metadata, {:format, format}}}

  defp validate_source_type(source_type) when source_type in @source_types, do: :ok

  defp validate_source_type(source_type),
    do: {:error, {:invalid_source_metadata, {:source_type, source_type}}}

  defp validate_known_options(attrs) do
    case Keyword.keys(attrs) -- @keys do
      [] -> :ok
      unknown_keys -> {:error, {:unknown_source_metadata_options, Enum.uniq(unknown_keys)}}
    end
  end

  defp validate_new(%__MODULE__{} = metadata) do
    case validate(metadata) do
      :ok -> {:ok, metadata}
      {:error, reason} -> {:error, reason}
    end
  end
end
