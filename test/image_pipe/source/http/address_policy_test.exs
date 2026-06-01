defmodule ImagePipe.Source.HTTP.AddressPolicyTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.HTTP.AddressPolicy

  describe "classify/1 IPv4" do
    test "categorizes well-known IPv4 ranges" do
      assert AddressPolicy.classify({127, 0, 0, 1}) == :loopback
      assert AddressPolicy.classify({127, 5, 5, 5}) == :loopback
      assert AddressPolicy.classify({0, 0, 0, 0}) == :unspecified
      assert AddressPolicy.classify({0, 1, 2, 3}) == :unspecified
      assert AddressPolicy.classify({169, 254, 169, 254}) == :link_local
      assert AddressPolicy.classify({10, 0, 0, 1}) == :private
      assert AddressPolicy.classify({172, 16, 0, 1}) == :private
      assert AddressPolicy.classify({172, 31, 255, 255}) == :private
      assert AddressPolicy.classify({172, 32, 0, 1}) == :public
      assert AddressPolicy.classify({192, 168, 1, 1}) == :private
      assert AddressPolicy.classify({100, 64, 0, 1}) == :cgnat
      assert AddressPolicy.classify({224, 0, 0, 1}) == :multicast
      assert AddressPolicy.classify({255, 255, 255, 255}) == :broadcast
      assert AddressPolicy.classify({198, 18, 0, 1}) == :reserved
      assert AddressPolicy.classify({192, 0, 2, 5}) == :reserved
      assert AddressPolicy.classify({93, 184, 216, 34}) == :public
      assert AddressPolicy.classify({8, 8, 8, 8}) == :public
    end
  end
end
