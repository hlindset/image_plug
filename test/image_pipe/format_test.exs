defmodule ImagePipe.FormatTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Format

  test "defines canonical source and output format families" do
    assert Format.output_formats() == [:avif, :webp, :jpeg, :png]
    assert Format.source_only_formats() == [:heif, :tiff, :jpeg2000, :jpeg_xl]

    assert Format.source_formats() == [
             :avif,
             :webp,
             :jpeg,
             :png,
             :heif,
             :tiff,
             :jpeg2000,
             :jpeg_xl
           ]
  end

  test "classifies format families" do
    assert Format.output_format?(:avif)
    assert Format.output_format?(:png)
    refute Format.output_format?(:heif)

    assert Format.source_only_format?(:heif)
    assert Format.source_only_format?(:jpeg_xl)
    refute Format.source_only_format?(:jpeg)

    assert Format.source_format?(:jpeg2000)
    refute Format.source_format?(:svg)
  end

  test "output MIME mapping covers the canonical output formats" do
    assert Format.output_mime_types() |> Keyword.keys() == Format.output_formats()

    assert Format.output_mime_type_values() == [
             "image/avif",
             "image/webp",
             "image/jpeg",
             "image/png"
           ]
  end

  test "maps output MIME types and suffixes" do
    assert Format.format_from_mime_type("image/jpeg") == {:ok, :jpeg}
    assert Format.format_from_mime_type("image/jpg") == {:ok, :jpeg}
    assert Format.format_from_mime_type(" image/WEBP; charset=utf-8") == {:ok, :webp}

    assert Format.format_from_mime_type("image/gif") ==
             {:error, {:unsupported_output_format, "image/gif"}}

    assert Format.mime_type(:png) == {:ok, "image/png"}
    assert Format.suffix!("image/png") == ".png"
  end
end
