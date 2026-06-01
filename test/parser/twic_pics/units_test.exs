defmodule ImagePipe.Parser.TwicPics.UnitsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.TwicPics.Units

  describe "length/1" do
    test "bare and px numbers are pixels" do
      assert Units.length("250") == {:ok, {:px, 250}}
      assert Units.length("250px") == {:ok, {:px, 250}}
    end

    test "percent suffix" do
      assert Units.length("50p") == {:ok, {:percent, 50}}
      assert Units.length("4.5p") == {:ok, {:percent, 4.5}}
    end

    test "scale suffix" do
      assert Units.length("0.5s") == {:ok, {:scale, 0.5}}
    end

    test "rejects malformed and non-positive pixels" do
      assert {:error, _} = Units.length("abc")
      assert {:error, _} = Units.length("0")
      assert {:error, _} = Units.length("-3")
    end
  end
end
