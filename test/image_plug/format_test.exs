defmodule ImagePlug.FormatTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Format

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
    assert ImagePlug.Output.Format.all() |> Keyword.keys() == Format.output_formats()
  end
end
