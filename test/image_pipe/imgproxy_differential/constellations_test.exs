defmodule ImagePipe.Test.ImgproxyDifferential.ConstellationsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Test.ImgproxyDifferential.Constellations

  @valid_sources Map.keys(Constellations.source_files())

  test "every constellation is well-formed" do
    for c <- Constellations.all() do
      assert is_binary(c.id) and c.id != ""
      assert c.source in @valid_sources
      assert is_binary(c.opts)
      assert c.verdict in [:equal, :diverges]
      assert c.group in [:transform, :lossy]
      assert match?(nil, c.tol) or is_map(c.tol)

      if c.verdict == :diverges do
        assert is_map(c.divergence), "diverges row #{c.id} must declare a divergence metric"
      end
    end
  end

  test "ids are unique" do
    ids = Enum.map(Constellations.all(), & &1.id)
    assert ids == Enum.uniq(ids)
  end

  test "imgproxy_path builds an unsafe processing path ending in the local source" do
    c = %{
      id: "x",
      source: :high_freq,
      opts: "rs:fill:240:180",
      verdict: :equal,
      group: :transform,
      tol: nil,
      divergence: nil
    }

    path = Constellations.imgproxy_path(c)
    assert path =~ "/unsafe/"
    assert path =~ "rs:fill:240:180"
    assert path =~ "f:png"
    assert String.ends_with?(path, "plain/local:///high_freq.jpg")
  end

  test "imgproxy_path for a lossy constellation keeps the requested format and source ext" do
    c = %{
      id: "y",
      source: :high_freq_webp,
      opts: "rs:fill:240:180/f:webp",
      verdict: :equal,
      group: :lossy,
      tol: nil,
      divergence: nil
    }

    path = Constellations.imgproxy_path(c)
    assert path =~ "f:webp"
    refute path =~ "f:png"
    assert String.ends_with?(path, "plain/local:///high_freq.webp")
  end
end
