defmodule ImagePlug.Format do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: []

  @output_formats [:avif, :webp, :jpeg, :png]
  @source_only_formats [:heif, :tiff, :jpeg2000, :jpeg_xl]
  @source_formats @output_formats ++ @source_only_formats

  @type output_format() :: :avif | :webp | :jpeg | :png
  @type source_only_format() :: :heif | :tiff | :jpeg2000 | :jpeg_xl
  @type source_format() :: output_format() | source_only_format()

  @spec output_formats() :: [output_format()]
  def output_formats, do: @output_formats

  @spec source_formats() :: [source_format()]
  def source_formats, do: @source_formats

  @spec source_only_formats() :: [source_only_format()]
  def source_only_formats, do: @source_only_formats

  @spec output_format?(term()) :: boolean()
  def output_format?(format), do: format in @output_formats

  @spec source_format?(term()) :: boolean()
  def source_format?(format), do: format in @source_formats

  @spec source_only_format?(term()) :: boolean()
  def source_only_format?(format), do: format in @source_only_formats
end
