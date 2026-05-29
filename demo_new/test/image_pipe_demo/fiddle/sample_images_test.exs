defmodule ImagePipeDemo.Fiddle.SampleImagesTest do
  use ExUnit.Case, async: true
  alias ImagePipeDemo.Fiddle.SampleImages

  test "lists the two spike sources with dimensions" do
    assert SampleImages.paths() == ["images/dog.jpg", "images/beach.jpg"]
    assert SampleImages.width("images/dog.jpg") == 5011
    assert SampleImages.height("images/dog.jpg") == 7516
    assert SampleImages.width("images/beach.jpg") == 4000
    assert SampleImages.height("images/beach.jpg") == 2667
  end

  test "valid?/1 distinguishes known sources" do
    assert SampleImages.valid?("images/dog.jpg")
    refute SampleImages.valid?("images/nope.jpg")
  end
end
