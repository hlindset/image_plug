defmodule ImagePipe.Test.ImgproxyDifferential.SkewTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Test.ImgproxyDifferential.Skew

  test "runtime_libvips returns the Vix libvips version string" do
    assert Skew.runtime_libvips() == Vix.Vips.version()
  end

  test "aligned? compares runtime libvips against a manifest's recorded version" do
    assert Skew.aligned?(%{imgproxy_libvips: Vix.Vips.version()})
    refute Skew.aligned?(%{imgproxy_libvips: "0.0.0-not-a-real-version"})
  end

  test "ci? reflects the CI env var" do
    assert Skew.ci?(%{"CI" => "true"})
    assert Skew.ci?(%{"CI" => "1"})
    refute Skew.ci?(%{})
    refute Skew.ci?(%{"CI" => ""})
  end
end
