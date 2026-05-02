defmodule ImagePlug.OutputSelectionTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePlug.OutputSelection
  alias ImagePlug.Transform.Output

  describe "preselect/3" do
    test "builds an automatic AVIF selection before origin metadata is available" do
      conn =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", "image/avif,image/webp")

      assert {:ok, selection} = OutputSelection.preselect(conn, [], [])

      assert selection.format == :avif
      assert selection.reason == :auto
      assert selection.headers == [{"vary", "Accept"}]

      assert selection.chain == [
               {Output, %Output.OutputParams{format: :avif}}
             ]
    end

    test "defers when source metadata is required to choose the output" do
      conn =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", "image/jpeg")

      assert OutputSelection.preselect(conn, [], []) == :defer
    end

    test "returns not acceptable when no supported output can match before origin fetch" do
      conn =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", "image/*;q=0")

      assert OutputSelection.preselect(conn, [], []) == {:error, :not_acceptable}
    end
  end

  describe "negotiate/4" do
    test "uses accepted source-format metadata" do
      conn =
        :get
        |> conn("/_/plain/images/cat.jpg")
        |> put_req_header("accept", "image/png")

      assert {:ok, selection} = OutputSelection.negotiate(conn, :png, [], [])

      assert selection.format == :png
      assert selection.reason == :source
      assert selection.headers == [{"vary", "Accept"}]
      assert selection.chain == [{Output, %Output.OutputParams{format: :png}}]
    end
  end
end
