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
end
