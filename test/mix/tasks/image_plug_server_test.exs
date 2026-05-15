defmodule Mix.Tasks.ImagePlug.ServerTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.ImagePlug.Server

  describe "parse_args/1" do
    test "defaults to port 4000" do
      assert Server.parse_args([]) == {:ok, %{cache?: false, port: 4000, vite?: true}}
    end

    test "accepts an explicit port" do
      assert Server.parse_args(["--port", "4001"]) ==
               {:ok, %{cache?: false, port: 4001, vite?: true}}

      assert Server.parse_args(["-p", "4002"]) ==
               {:ok, %{cache?: false, port: 4002, vite?: true}}
    end

    test "accepts cache toggles" do
      assert Server.parse_args(["--cache"]) == {:ok, %{cache?: true, port: 4000, vite?: true}}
      assert Server.parse_args(["--no-cache"]) == {:ok, %{cache?: false, port: 4000, vite?: true}}
    end

    test "accepts vite toggles" do
      assert Server.parse_args(["--no-vite"]) == {:ok, %{cache?: false, port: 4000, vite?: false}}
      assert Server.parse_args(["--vite"]) == {:ok, %{cache?: false, port: 4000, vite?: true}}
    end

    test "rejects invalid arguments" do
      assert {:error, message} = Server.parse_args(["--port", "0"])
      assert message =~ "expected --port to be between 1 and 65535"

      assert {:error, message} = Server.parse_args(["--unknown"])
      assert message =~ "unknown option: --unknown"

      assert {:error, message} = Server.parse_args(["extra"])
      assert message =~ "unexpected argument: extra"
    end
  end
end
