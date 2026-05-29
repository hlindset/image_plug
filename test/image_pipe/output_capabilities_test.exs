defmodule ImagePipe.Output.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.Capabilities

  describe "supports?/1" do
    test "baseline jpeg and png are always supported without probing" do
      assert Capabilities.supports?(:jpeg)
      assert Capabilities.supports?(:png)
    end

    test "returns a boolean for avif and webp" do
      assert is_boolean(Capabilities.supports?(:avif))
      assert is_boolean(Capabilities.supports?(:webp))
    end

    test "unknown formats are unsupported" do
      refute Capabilities.supports?(:gif)
    end
  end

  describe "supports?/2 with an injected capability map" do
    test "the override decides avif/webp" do
      opts = [output_capabilities: %{avif: false, webp: true}]
      refute Capabilities.supports?(:avif, opts)
      assert Capabilities.supports?(:webp, opts)
    end

    test "falls back to the probe when the format is absent from the map" do
      opts = [output_capabilities: %{webp: false}]
      assert is_boolean(Capabilities.supports?(:avif, opts))
    end

    test "without the key, behaves like supports?/1" do
      assert Capabilities.supports?(:jpeg, [])
    end
  end

  describe "probe/0" do
    test "returns :ok and is idempotent" do
      assert Capabilities.probe() == :ok
      assert Capabilities.probe() == :ok
    end
  end
end
