defmodule ImagePlug.OutputNegotiationTest do
  use ExUnit.Case, async: true

  alias ImagePlug.OutputNegotiation

  describe "modern_candidates/2" do
    test "detects enabled modern formats from Accept" do
      assert OutputNegotiation.modern_candidates("image/webp;q=1,image/avif;q=0.1", []) == [
               :avif,
               :webp
             ]

      assert OutputNegotiation.modern_candidates("image/avif;q=0,image/*;q=1", []) == [:webp]
      assert OutputNegotiation.modern_candidates("image/jpeg", []) == []
      assert OutputNegotiation.modern_candidates(nil, []) == []
    end

    test "respects automatic format feature flags" do
      assert OutputNegotiation.modern_candidates("image/avif,image/webp", auto_avif: false) == [
               :webp
             ]

      assert OutputNegotiation.modern_candidates("image/avif,image/webp",
               auto_avif: false,
               auto_webp: false
             ) == []
    end

    test "uses server preference before relative q-values" do
      assert OutputNegotiation.modern_candidates("image/webp;q=1,image/avif;q=0.1", []) == [
               :avif,
               :webp
             ]
    end

    test "matches image and global wildcards" do
      assert OutputNegotiation.modern_candidates("image/*", []) == [:avif, :webp]
      assert OutputNegotiation.modern_candidates("*/*", []) == [:avif, :webp]
    end

    test "exact q zero excludes a modern format even when wildcard matches" do
      assert OutputNegotiation.modern_candidates("image/avif;q=0,image/*;q=1", []) == [:webp]

      assert OutputNegotiation.modern_candidates("image/avif;q=0,image/avif;q=1,*/*;q=1", []) == [
               :webp
             ]
    end

    test "image wildcard exclusion wins over global wildcard allowance" do
      assert OutputNegotiation.modern_candidates("image/*;q=0,*/*;q=1", []) == []
    end
  end

  describe "suffix!/1" do
    test "maps output MIME types to encoder suffixes" do
      assert OutputNegotiation.suffix!("image/avif") == ".avif"
      assert OutputNegotiation.suffix!("image/webp") == ".webp"
      assert OutputNegotiation.suffix!("image/jpeg") == ".jpg"
      assert OutputNegotiation.suffix!("image/png") == ".png"
    end
  end

  describe "format conversion" do
    test "maps negotiated MIME types to format atoms" do
      assert OutputNegotiation.format("image/avif") == {:ok, :avif}
      assert OutputNegotiation.format("image/webp") == {:ok, :webp}
      assert OutputNegotiation.format("image/jpeg") == {:ok, :jpeg}
      assert OutputNegotiation.format("image/jpg") == {:ok, :jpeg}
      assert OutputNegotiation.format("image/png") == {:ok, :png}
      assert OutputNegotiation.format("IMAGE/PNG; charset=binary") == {:ok, :png}

      assert OutputNegotiation.format("image/gif") ==
               {:error, {:unsupported_output_format, "image/gif"}}
    end

    test "maps format atoms to output MIME types" do
      assert OutputNegotiation.mime_type(:avif) == {:ok, "image/avif"}
      assert OutputNegotiation.mime_type(:webp) == {:ok, "image/webp"}
      assert OutputNegotiation.mime_type(:jpeg) == {:ok, "image/jpeg"}
      assert OutputNegotiation.mime_type(:png) == {:ok, "image/png"}
      assert OutputNegotiation.mime_type(:gif) == :error
    end
  end
end
