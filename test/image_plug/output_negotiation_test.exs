defmodule ImagePlug.OutputNegotiationTest do
  use ExUnit.Case, async: true

  alias ImagePlug.OutputNegotiation

  describe "negotiate/2" do
    test "uses q-values before server priority" do
      assert OutputNegotiation.negotiate("image/webp;q=0.4,image/avif;q=0.9", true) ==
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

    test "exact q zero excludes a format even when a wildcard matches" do
      assert OutputNegotiation.negotiate("image/avif;q=0,image/*;q=1", true) ==
               {:ok, "image/webp"}
    end

    test "falls back to png for alpha when modern formats are not accepted" do
      assert OutputNegotiation.negotiate("image/jpeg", true) == {:ok, "image/png"}
    end

    test "does not select png fallback for alpha when png is q zero" do
      assert OutputNegotiation.negotiate("image/png;q=0", true) == {:ok, "image/avif"}
    end

    test "falls back to jpeg for non-alpha when modern formats are not accepted" do
      assert OutputNegotiation.negotiate("image/png;q=0", false) == {:ok, "image/jpeg"}
    end

    test "does not select jpeg fallback for non-alpha when jpeg is q zero" do
      assert OutputNegotiation.negotiate("image/jpeg;q=0", false) == {:ok, "image/avif"}
    end

    test "returns not acceptable when an image wildcard excludes every alpha format" do
      assert OutputNegotiation.negotiate("image/*;q=0", true) == {:error, :not_acceptable}
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
  end

  describe "suffix!/1" do
    test "maps output MIME types to encoder suffixes" do
      assert OutputNegotiation.suffix!("image/avif") == ".avif"
      assert OutputNegotiation.suffix!("image/webp") == ".webp"
      assert OutputNegotiation.suffix!("image/jpeg") == ".jpg"
      assert OutputNegotiation.suffix!("image/png") == ".png"
    end
  end
end
