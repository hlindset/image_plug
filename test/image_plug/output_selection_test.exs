defmodule ImagePlug.OutputSelectionTest do
  use ExUnit.Case, async: true

  alias ImagePlug.OutputSelection

  describe "preselect/2" do
    test "builds an automatic AVIF selection before origin metadata is available" do
      assert {:ok, selection} = OutputSelection.preselect("image/avif,image/webp", [])

      assert selection.format == :avif
      assert selection.reason == :auto
      assert selection.headers == [{"vary", "Accept"}]
    end

    test "defers when source metadata is required to choose the output" do
      assert OutputSelection.preselect("image/jpeg", []) == :defer
    end

    test "returns not acceptable when no supported output can match before origin fetch" do
      assert OutputSelection.preselect("image/*;q=0", []) == {:error, :not_acceptable}
    end
  end

  describe "negotiate/3" do
    test "uses accepted source-format metadata" do
      assert {:ok, selection} = OutputSelection.negotiate("image/png", :png, [])

      assert selection.format == :png
      assert selection.reason == :source
      assert selection.headers == [{"vary", "Accept"}]
    end
  end
end
