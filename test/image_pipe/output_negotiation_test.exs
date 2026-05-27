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
end
