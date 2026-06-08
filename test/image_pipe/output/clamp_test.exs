defmodule ImagePipe.Output.ClampTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.Encoder

  describe "encoder_limit/1" do
    test "returns the WebP and AVIF hard dimension limits" do
      assert Encoder.encoder_limit(:webp) == %{max_dimension: 16383}
      assert Encoder.encoder_limit(:avif) == %{max_dimension: 16384}
    end

    test "returns the documented JPEG limit and unbounded PNG" do
      assert Encoder.encoder_limit(:jpeg) == %{max_dimension: 65535}
      assert Encoder.encoder_limit(:png) == %{max_dimension: :infinity}
    end
  end

  describe "clamp/3" do
    alias ImagePipe.Output.Clamp

    # A blank image of exact dimensions; cheap and lazy.
    defp image(width, height) do
      {:ok, image} = Image.new(width, height)
      image
    end

    test "returns the image unchanged with nil info when within the limit" do
      img = image(200, 50)
      assert {:ok, ^img, nil} = Clamp.clamp(img, 1000, [])
    end

    test "is a no-op for an :infinity limit" do
      img = image(200, 50)
      assert {:ok, ^img, nil} = Clamp.clamp(img, :infinity, [])
    end

    test "uniformly downscales when the longest axis exceeds the limit" do
      img = image(200, 50)
      assert {:ok, resized, info} = Clamp.clamp(img, 100, [])

      assert Image.width(resized) == 100
      assert Image.height(resized) == 25
      assert info.source_dimensions == {200, 50}
      assert info.dimensions == {100, 25}
      assert info.max_dimension == 100
      assert_in_delta info.scale, 0.5, 1.0e-6
    end

    test "guarantees the realized longest axis is at most the limit (rounding)" do
      # 333 * (100/333) = 100.0 -> round 100; this also exercises the
      # measure-and-verify path that keeps a rounding quirk from exceeding it.
      img = image(333, 10)
      assert {:ok, resized, info} = Clamp.clamp(img, 100, [])

      assert Image.width(resized) <= 100
      assert max(Image.width(resized), Image.height(resized)) <= 100
      assert info.dimensions == {Image.width(resized), Image.height(resized)}
    end
  end
end
