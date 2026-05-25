defmodule ImagePlug.Output.NegotiationTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Format
  alias ImagePlug.Output.Negotiation

  describe "modern_candidates/2" do
    test "detects enabled modern formats from Accept" do
      assert Negotiation.modern_candidates("image/webp;q=1,image/avif;q=0.1", []) == [
               :avif,
               :webp
             ]

      assert Negotiation.modern_candidates("image/avif;q=0,image/*;q=1", []) == [:webp]
      assert Negotiation.modern_candidates("image/jpeg", []) == []
      assert Negotiation.modern_candidates(nil, []) == []
    end

    test "respects automatic format feature flags" do
      assert Negotiation.modern_candidates("image/avif,image/webp", auto_avif: false) == [
               :webp
             ]

      assert Negotiation.modern_candidates("image/avif,image/webp",
               auto_avif: false,
               auto_webp: false
             ) == []
    end

    test "uses server preference before relative q-values" do
      assert Negotiation.modern_candidates("image/webp;q=1,image/avif;q=0.1", []) == [
               :avif,
               :webp
             ]
    end

    test "matches image and global wildcards" do
      assert Negotiation.modern_candidates("image/*", []) == [:avif, :webp]
      assert Negotiation.modern_candidates("*/*", []) == [:avif, :webp]
    end

    test "exact q zero excludes a modern format even when wildcard matches" do
      assert Negotiation.modern_candidates("image/avif;q=0,image/*;q=1", []) == [:webp]

      assert Negotiation.modern_candidates("image/avif;q=0,image/avif;q=1,*/*;q=1", []) == [
               :webp
             ]
    end

    test "image wildcard exclusion wins over global wildcard allowance" do
      assert Negotiation.modern_candidates("image/*;q=0,*/*;q=1", []) == []
    end
  end

  describe "suffix!/1" do
    test "maps output MIME types to encoder suffixes" do
      assert Format.suffix!("image/avif") == ".avif"
      assert Format.suffix!("image/webp") == ".webp"
      assert Format.suffix!("image/jpeg") == ".jpg"
      assert Format.suffix!("image/png") == ".png"
    end

    test "returns tagged suffix results without raising" do
      assert Format.suffix("image/jpeg") == {:ok, ".jpg"}

      assert Format.suffix("image/gif") ==
               {:error, {:unsupported_output_format, "image/gif"}}
    end
  end

  describe "format conversion" do
    test "maps negotiated MIME types to format atoms" do
      assert Format.format_from_mime_type("image/avif") == {:ok, :avif}
      assert Format.format_from_mime_type("image/webp") == {:ok, :webp}
      assert Format.format_from_mime_type("image/jpeg") == {:ok, :jpeg}
      assert Format.format_from_mime_type("image/jpg") == {:ok, :jpeg}
      assert Format.format_from_mime_type("image/png") == {:ok, :png}
      assert Format.format_from_mime_type("IMAGE/PNG; charset=binary") == {:ok, :png}

      assert Format.format_from_mime_type("image/gif") ==
               {:error, {:unsupported_output_format, "image/gif"}}
    end

    test "maps format atoms to output MIME types" do
      assert Format.mime_type(:avif) == {:ok, "image/avif"}
      assert Format.mime_type(:webp) == {:ok, "image/webp"}
      assert Format.mime_type(:jpeg) == {:ok, "image/jpeg"}
      assert Format.mime_type(:png) == {:ok, "image/png"}
      assert Format.mime_type(:gif) == :error
    end
  end
end
