defmodule ImagePipe.Transform.Detector.ImageVisionTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.Detector.ImageVision

  test "available? mirrors Code.ensure_loaded?(Image.FaceDetection)" do
    assert ImageVision.available?([]) == Code.ensure_loaded?(Image.FaceDetection)
  end

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
    image = Image.open!("priv/static/images/woman.jpg")
    assert {:ok, regions} = ImageVision.detect(image, classes: ["face"])
    assert Enum.all?(regions, &match?(%{label: "face", box: {_, _, _, _}}, &1))
  end
end
