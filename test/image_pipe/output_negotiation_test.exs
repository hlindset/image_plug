defmodule ImagePipe.Output.NegotiationTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.Negotiation

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

    test "treats missing, empty, and global wildcard-only Accept as no modern format signal" do
      assert Negotiation.modern_candidates(nil, []) == []
      assert Negotiation.modern_candidates("", []) == []
      assert Negotiation.modern_candidates("   ", []) == []
      assert Negotiation.modern_candidates("*/*", []) == []
      assert Negotiation.modern_candidates("*/*;q=1", []) == []
      assert Negotiation.modern_candidates("*/*; q=0.8", []) == []
      assert Negotiation.modern_candidates("application/json,*/*;q=1", []) == []
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

    test "matches image wildcard and explicit modern formats when global wildcard is also present" do
      assert Negotiation.modern_candidates("image/*", []) == [:avif, :webp]
      assert Negotiation.modern_candidates("image/webp,*/*", []) == [:webp]
    end

    test "exact q zero excludes a modern format even when wildcard matches" do
      assert Negotiation.modern_candidates("image/avif;q=0,image/*;q=1", []) == [:webp]

      assert Negotiation.modern_candidates("image/avif;q=0,image/avif;q=1,*/*;q=1", []) == []
    end

    test "image wildcard exclusion leaves global wildcard ignored" do
      assert Negotiation.modern_candidates("image/*;q=0,*/*;q=1", []) == []
    end
  end

  describe "modern_candidates/2 capability filtering" do
    test "drops avif when the build cannot write it" do
      opts = [output_capabilities: %{avif: false}]

      assert Negotiation.modern_candidates("image/avif,image/webp", opts) == [:webp]
    end

    test "an avif-only Accept on an avif-less build yields no modern candidates" do
      opts = [output_capabilities: %{avif: false}]

      assert Negotiation.modern_candidates("image/avif", opts) == []
    end

    test "keeps both when the build supports both" do
      opts = [output_capabilities: %{avif: true, webp: true}]

      assert Negotiation.modern_candidates("image/avif,image/webp", opts) == [:avif, :webp]
    end
  end
end
