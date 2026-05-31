defmodule ImagePipe.Transform.Detector.ImageVisionTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.Detector.ImageVision

  test "identity reflects availability" do
    expected =
      if ImageVision.available?([]),
        do: {ImageVision, {"opencv/face_detection_yunet", "face_detection_yunet_2023mar.onnx"}},
        else: {ImageVision, :unavailable}

    assert ImageVision.identity([]) == expected
  end

  test "detect returns unavailable when the dependency is absent" do
    # In the default (no-dep) lane, available? is false → detect short-circuits.
    if ImageVision.available?([]) do
      assert {:ok, _} = ImageVision.detect(Image.new!(64, 64, color: :black), classes: ["face"])
    else
      assert {:error, {:detector, :unavailable}} =
               ImageVision.detect(Image.new!(64, 64, color: :black), classes: ["face"])
    end
  end

  @tag :image_vision
  test "detect returns face regions when the dependency is present" do
    unless ImageVision.available?([]) do
      flunk("""
      The :image_vision lane needs the real face detector, but Image.FaceDetection \
      is not loaded (available?([]) == false). image_vision compiles that module \
      only when its ONNX backend is configured (`if ImageVision.ortex_configured?()`), \
      so the lane requires BOTH `:image_vision` and `:ortex` (a Rust/ONNX runtime). \
      Both are in the IMAGE_VISION-gated deps in mix.exs — run \
      `IMAGE_VISION=1 mix deps.get` (needs a Rust toolchain); the YuNet model \
      (~340 KB) downloads from HuggingFace on the first detect call.\
      """)
    end

    image = Image.open!("priv/static/images/woman.jpg")
    assert {:ok, regions} = ImageVision.detect(image, classes: ["face"])
    assert Enum.all?(regions, &match?(%{label: "face", box: {_, _, _, _}}, &1))
  end
end
