defmodule ImagePlug.OutputNegotiationTest do
  use ExUnit.Case, async: true

  alias ImagePlug.OutputNegotiation

  describe "negotiate/2" do
    test "uses server preference before relative q-values" do
      assert OutputNegotiation.negotiate("image/webp;q=1,image/avif;q=0.1", false) ==
               {:ok, "image/avif"}
    end

    test "uses server priority when q-values tie" do
      assert OutputNegotiation.negotiate("image/webp,image/avif", true) == {:ok, "image/avif"}
    end

    test "matches image wildcards" do
      assert OutputNegotiation.negotiate("image/*;q=0.8", true) == {:ok, "image/avif"}
    end

    test "matches global wildcards" do
      assert OutputNegotiation.negotiate("*/*;q=0.8", true) == {:ok, "image/avif"}
    end

    test "excludes q zero" do
      assert OutputNegotiation.negotiate("image/avif;q=0,image/webp;q=1", true) ==
               {:ok, "image/webp"}
    end

    test "excludes uppercase q zero" do
      assert OutputNegotiation.negotiate("image/avif;Q=0,image/webp;q=1", true) ==
               {:ok, "image/webp"}
    end

    test "uses uppercase q quality values" do
      assert OutputNegotiation.negotiate("image/webp;Q=0.4,image/avif;q=0.9", true) ==
               {:ok, "image/avif"}
    end

    test "trims q parameter names before comparing case-insensitively" do
      assert OutputNegotiation.negotiate("image/webp; Q =0.4,image/avif;q=0.9", true) ==
               {:ok, "image/avif"}
    end

    test "trims q values but does not let relative q reorder server preference" do
      assert OutputNegotiation.negotiate("image/webp;q= 1,image/avif;q=0.9", true) ==
               {:ok, "image/avif"}
    end

    test "exact q zero excludes a format even when a wildcard matches" do
      assert OutputNegotiation.negotiate("image/avif;q=0,image/*;q=1", false) ==
               {:ok, "image/webp"}
    end

    test "exact q zero excludes a format even with duplicate positive exact entries" do
      accept = "image/avif;q=0,image/avif;q=1,*/*;q=1"

      assert OutputNegotiation.negotiate(accept, false) == {:ok, "image/webp"}
      assert OutputNegotiation.preselect(accept, []) == {:ok, :webp}
    end

    test "matches image and global wildcards" do
      assert OutputNegotiation.negotiate("image/*", false) == {:ok, "image/avif"}
      assert OutputNegotiation.negotiate("*/*", false) == {:ok, "image/avif"}
    end

    test "does not fall back to unaccepted formats for alpha images" do
      assert OutputNegotiation.negotiate("image/jpeg", true) == {:error, :not_acceptable}
    end

    test "does not select a fallback when only png is excluded for alpha images" do
      assert OutputNegotiation.negotiate("image/png;q=0", true) == {:error, :not_acceptable}
    end

    test "does not fall back to unaccepted formats for non-alpha images" do
      assert OutputNegotiation.negotiate("image/png;q=0", false) == {:error, :not_acceptable}
    end

    test "prefers accepted source format before alpha-derived fallback" do
      assert OutputNegotiation.negotiate("image/png", false, source_format: :png) ==
               {:ok, "image/png"}

      assert OutputNegotiation.negotiate("image/webp", true,
               auto_avif: false,
               auto_webp: false,
               source_format: :webp
             ) == {:ok, "image/webp"}
    end

    test "does not select a fallback when only jpeg is excluded for non-alpha images" do
      assert OutputNegotiation.negotiate("image/jpeg;q=0", false) == {:error, :not_acceptable}
    end

    test "returns not acceptable when no supported format is accepted" do
      assert OutputNegotiation.negotiate("application/json", false) == {:error, :not_acceptable}
    end

    test "falls back to an accepted legacy format from image wildcards" do
      assert OutputNegotiation.negotiate("image/avif;q=0,image/webp;q=0,image/*", true) ==
               {:ok, "image/png"}
    end

    test "returns not acceptable when an image wildcard excludes every alpha format" do
      assert OutputNegotiation.negotiate("image/*;q=0", true) == {:error, :not_acceptable}
    end

    test "returns not acceptable when wildcard excludes every supported output" do
      assert OutputNegotiation.negotiate("image/*;q=0", false) == {:error, :not_acceptable}
    end

    test "returns not acceptable when a global wildcard excludes every non-alpha format" do
      assert OutputNegotiation.negotiate("*/*;q=0", false) == {:error, :not_acceptable}
    end

    test "returns not acceptable when explicit q zero entries exclude every non-alpha format" do
      assert OutputNegotiation.negotiate(
               "image/avif;q=0,image/webp;q=0,image/jpeg;q=0",
               false
             ) == {:error, :not_acceptable}
    end

    test "respects automatic format feature flags" do
      assert OutputNegotiation.negotiate("image/avif,image/webp", false, auto_avif: false) ==
               {:ok, "image/webp"}

      assert OutputNegotiation.preselect("image/avif,image/webp",
               auto_avif: false,
               auto_webp: false
             ) == :defer

      assert OutputNegotiation.preselect("image/avif", auto_avif: false, auto_webp: false) ==
               :defer

      assert OutputNegotiation.preselect("image/webp", auto_avif: false, auto_webp: false) ==
               :defer

      assert OutputNegotiation.preselect(nil, auto_avif: false, auto_webp: false) == :defer
    end

    test "preselects AVIF and WebP before origin metadata is available" do
      assert OutputNegotiation.preselect("image/webp;q=1,image/avif;q=0.1", []) == {:ok, :avif}
      assert OutputNegotiation.preselect("image/avif;q=0,image/*;q=1", []) == {:ok, :webp}
      assert OutputNegotiation.preselect("image/*;q=0", []) == {:error, :not_acceptable}
      assert OutputNegotiation.preselect("image/png", []) == :defer
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
      assert OutputNegotiation.format("image/gif") == :error
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
