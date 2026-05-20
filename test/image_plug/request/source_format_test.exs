defmodule ImagePlug.Request.SourceFormatTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Request.SourceFormat

  test "maps standard raster loader prefixes" do
    assert SourceFormat.classify_loader("jpegload_buffer", &missing_metadata/1) == {:ok, :jpeg}
    assert SourceFormat.classify_loader("pngload_buffer", &missing_metadata/1) == {:ok, :png}
    assert SourceFormat.classify_loader("webpload_buffer", &missing_metadata/1) == {:ok, :webp}
    assert SourceFormat.classify_loader("tiffload_buffer", &missing_metadata/1) == {:ok, :tiff}

    assert SourceFormat.classify_loader("jp2kload_buffer", &missing_metadata/1) ==
             {:ok, :jpeg2000}

    assert SourceFormat.classify_loader("jxlload_buffer", &missing_metadata/1) == {:ok, :jpeg_xl}
  end

  test "distinguishes AVIF from other HEIF-family inputs" do
    assert SourceFormat.classify_loader(
             "heifload_buffer",
             &metadata(%{"heif-compression" => "av1"}, &1)
           ) ==
             {:ok, :avif}

    assert SourceFormat.classify_loader(
             "heifload_buffer",
             &metadata(%{"heif-compression" => "hevc"}, &1)
           ) ==
             {:ok, :heif}

    assert SourceFormat.classify_loader("heifload_buffer", &missing_metadata/1) == {:ok, :heif}
  end

  test "rejects SVG and unknown loader families" do
    assert SourceFormat.classify_loader("svgload_buffer", &missing_metadata/1) ==
             {:error, {:unsupported_source_format, :svg}}

    assert SourceFormat.classify_loader("magickload_buffer", &missing_metadata/1) ==
             {:error, {:unsupported_source_format, :unknown}}

    assert SourceFormat.classify_loader(nil, &missing_metadata/1) ==
             {:error, {:unsupported_source_format, :unknown}}
  end

  defp metadata(values, key), do: Map.fetch(values, key)

  defp missing_metadata(_key), do: :error
end
