defmodule ImagePipe.Parser.TwicPicsTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Parser.TwicPics
  alias ImagePipe.Plan

  test "parse/2 returns a Plan for a valid twic request" do
    conn = conn(:get, "/images/beach.jpg?twic=v1/resize=100/output=avif")

    assert {:ok, %Plan{output: %Plan.Output{mode: {:explicit, :avif}}}} = TwicPics.parse(conn, [])
  end

  test "parse/2 returns an error for an unsupported transform" do
    conn = conn(:get, "/images/beach.jpg?twic=v1/zoom=2")
    assert {:error, {:unsupported_transform, "zoom"}} = TwicPics.parse(conn, [])
  end

  test "handle_error/2 sends a 400 text response" do
    conn = conn(:get, "/x?twic=v1/zoom=2")
    result = TwicPics.handle_error(conn, {:error, {:unsupported_transform, "zoom"}})

    assert result.status == 400
    assert get_resp_header(result, "content-type") == ["text/plain; charset=utf-8"]
  end

  test "validate_options!/1 normalizes the :twicpics sub-options into the opts" do
    assert TwicPics.validate_options!([]) == [twicpics: []]
    assert TwicPics.validate_options!(parser: TwicPics)[:twicpics] == []
  end

  test "validate_options!/1 raises on a non-list :twicpics value" do
    assert_raise ArgumentError, ~r/invalid twicpics options/, fn ->
      TwicPics.validate_options!(twicpics: :nope)
    end
  end
end
