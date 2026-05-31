defmodule ImagePipe.Transform.CropOperationTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.State

  defp state(width, height) do
    {:ok, image} = Image.new(width, height, color: :white)
    %State{image: image}
  end

  defp dimensions(%State{image: image}), do: {Image.width(image), Image.height(image)}

  test "reduce shrinks the long axis to match ratio (default)" do
    op = %Crop{
      width: {:pixels, 100},
      height: {:pixels, 200},
      crop_from: :gravity,
      gravity: {:anchor, :center, :center},
      aspect_ratio: {:ratio, 1, 1},
      enlarge: false
    }

    {:ok, result} = Crop.execute(op, state(400, 400))
    assert {100, 100} == dimensions(result)
  end

  test "enlarge grows the short axis to match ratio" do
    op = %Crop{
      width: {:pixels, 100},
      height: {:pixels, 200},
      crop_from: :gravity,
      gravity: {:anchor, :center, :center},
      aspect_ratio: {:ratio, 1, 1},
      enlarge: true
    }

    {:ok, result} = Crop.execute(op, state(400, 400))
    assert {200, 200} == dimensions(result)
  end

  test "enlarge clamps to image bounds keeping ratio" do
    op = %Crop{
      width: {:pixels, 100},
      height: {:pixels, 200},
      crop_from: :gravity,
      gravity: {:anchor, :center, :center},
      aspect_ratio: {:ratio, 1, 1},
      enlarge: true
    }

    # image only 150 tall; enlarged 200x200 must shrink to fit -> 150x150
    {:ok, result} = Crop.execute(op, state(400, 150))
    assert {150, 150} == dimensions(result)
  end

  test "nil aspect_ratio leaves the crop unchanged" do
    op = %Crop{
      width: {:pixels, 100},
      height: {:pixels, 200},
      crop_from: :gravity,
      gravity: {:anchor, :center, :center},
      aspect_ratio: nil,
      enlarge: false
    }

    {:ok, result} = Crop.execute(op, state(400, 400))
    assert {100, 200} == dimensions(result)
  end

  describe "smart gravity" do
    test "smart crop produces the requested dimensions" do
      image = Image.open!("priv/static/images/woman.jpg")
      state = %State{image: image}

      op = %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: :smart
      }

      assert {:ok, %{image: out}} = Crop.execute(op, state)
      assert Image.width(out) == 100
      assert Image.height(out) == 100
    end

    test "smart crop differs from a centered crop on an off-center subject" do
      image = Image.open!("priv/static/images/woman.jpg")
      state = %State{image: image}

      base = %Crop{
        width: {:pixels, 200},
        height: {:pixels, 200},
        crop_from: :gravity
      }

      {:ok, %{image: smart}} = Crop.execute(%{base | gravity: :smart}, state)

      {:ok, %{image: center}} =
        Crop.execute(%{base | gravity: {:anchor, :center, :center}}, state)

      refute Image.write!(smart, :memory, suffix: ".png") ==
               Image.write!(center, :memory, suffix: ".png")
    end
  end

  describe "detect gravity" do
    setup do
      {:ok, image} = Image.new(400, 400, color: :white)
      {:ok, image: image}
    end

    test "anchors on the area-weighted centroid of detected boxes" do
      # A uniform image makes a detect-anchored crop byte-identical to the
      # attention fallback, so use a real photo and a corner face box: the
      # detected crop must diverge from the pure-attention (:smart) crop.
      image = Image.open!("priv/static/images/woman.jpg")

      state = %State{
        image: image,
        detector:
          {ImagePipe.Test.FakeDetector,
           [result: {:ok, [%{label: "face", score: 0.9, box: {10, 10, 30, 30}}]}]}
      }

      op = %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:detect, ["face"]}
      }

      assert {:ok, %{image: out}} = Crop.execute(op, state)
      assert Image.width(out) == 100 and Image.height(out) == 100

      {:ok, %{image: attention}} =
        Crop.execute(%{op | gravity: :smart}, %State{image: image})

      png = fn img -> Image.write!(img, :memory, suffix: ".png") end
      refute png.(out) == png.(attention)
    end

    test "no detections falls back to attention" do
      # On a real photo, the no-detection fallback must be byte-identical to a
      # pure-attention (:smart) crop, proving detection is bypassed cleanly.
      image = Image.open!("priv/static/images/woman.jpg")

      state = %State{
        image: image,
        detector: {ImagePipe.Test.FakeDetector, [result: {:ok, []}]}
      }

      op = %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:detect, ["face"]}
      }

      assert {:ok, %{image: out}} = Crop.execute(op, state)
      assert Image.width(out) == 100

      {:ok, %{image: attention}} =
        Crop.execute(%{op | gravity: :smart}, %State{image: image})

      assert Image.write!(out, :memory, suffix: ".png") ==
               Image.write!(attention, :memory, suffix: ".png")
    end

    test "out-of-image box is dropped, falls back to attention", %{image: image} do
      state = %State{
        image: image,
        detector:
          {ImagePipe.Test.FakeDetector,
           [result: {:ok, [%{label: "face", score: 0.9, box: {-50, -50, 5, 5}}]}]}
      }

      op = %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:detect, ["face"]}
      }

      assert {:ok, %{image: _}} = Crop.execute(op, state)
    end

    test "detector error falls back to attention (graceful)", %{image: image} do
      state = %State{
        image: image,
        detector: {ImagePipe.Test.FakeDetector, [result: {:error, :boom}]}
      }

      op = %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:detect, ["face"]}
      }

      assert {:ok, %{image: _}} = Crop.execute(op, state)
    end

    test "nil detector falls back to attention", %{image: image} do
      state = %State{image: image, detector: nil}

      op = %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:detect, ["face"]}
      }

      assert {:ok, %{image: _}} = Crop.execute(op, state)
    end

    test "malformed detector return (bad box shape) falls back to attention", %{image: image} do
      state = %State{
        image: image,
        detector:
          {ImagePipe.Test.FakeDetector,
           [result: {:ok, [%{label: "face", score: 0.9, box: :nonsense}]}]}
      }

      op = %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:detect, ["face"]}
      }

      assert {:ok, %{image: _}} = Crop.execute(op, state)
    end

    test "detection emits a [:image_pipe, :transform, :detect] span with safe metadata", %{
      image: image
    } do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:image_pipe, :transform, :detect, :stop]])

      state = %State{
        image: image,
        detector:
          {ImagePipe.Test.FakeDetector,
           [result: {:ok, [%{label: "face", score: 0.9, box: {10, 10, 20, 20}}]}]}
      }

      op = %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:detect, ["face"]}
      }

      {:ok, _} = Crop.execute(op, state)

      assert_receive {[:image_pipe, :transform, :detect, :stop], ^ref, %{duration: _}, metadata}
      refute Map.has_key?(metadata, :source_url)
      assert metadata.classes == ["face"]
      assert metadata.regions == 1
      assert metadata.result == :detected

      :telemetry.detach(ref)
    end

    test "no-detection fallback reports result: :no_regions on the detect span", %{image: image} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:image_pipe, :transform, :detect, :stop]])

      state = %State{
        image: image,
        detector: {ImagePipe.Test.FakeDetector, [result: {:ok, []}]}
      }

      op = %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:detect, ["face"]}
      }

      {:ok, _} = Crop.execute(op, state)

      assert_receive {[:image_pipe, :transform, :detect, :stop], ^ref, _m, metadata}
      assert metadata.regions == 0
      assert metadata.result == :no_regions

      :telemetry.detach(ref)
    end

    test "detector error reports result: :error on the detect span", %{image: image} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:image_pipe, :transform, :detect, :stop]])

      state = %State{
        image: image,
        detector: {ImagePipe.Test.FakeDetector, [result: {:error, :boom}]}
      }

      op = %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:detect, ["face"]}
      }

      {:ok, _} = Crop.execute(op, state)

      assert_receive {[:image_pipe, :transform, :detect, :stop], ^ref, _m, metadata}
      assert metadata.result == :error

      :telemetry.detach(ref)
    end

    test "nil detector still emits a detect span with result: :no_detector", %{image: image} do
      ref =
        :telemetry_test.attach_event_handlers(self(), [[:image_pipe, :transform, :detect, :stop]])

      state = %State{image: image, detector: nil}

      op = %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:detect, ["face"]}
      }

      {:ok, _} = Crop.execute(op, state)

      assert_receive {[:image_pipe, :transform, :detect, :stop], ^ref, _m, metadata}
      assert metadata.classes == ["face"]
      assert metadata.regions == 0
      assert metadata.result == :no_detector

      :telemetry.detach(ref)
    end
  end

  describe "face-assist gravity" do
    setup do
      image = Image.open!("priv/static/images/woman.jpg")
      {:ok, image: image}
    end

    test "face_assist blends attention with the face centroid (differs from pure attention)", %{
      image: image
    } do
      # Fake a face in one corner; the blended crop must differ from pure :smart attention.
      fake =
        {ImagePipe.Test.FakeDetector,
         [result: {:ok, [%{label: "face", score: 0.9, box: {5, 5, 8, 8}}]}]}

      state = %State{image: image, detector: fake}

      base = %Crop{width: {:pixels, 200}, height: {:pixels, 200}, crop_from: :gravity}

      {:ok, %{image: assist}} =
        Crop.execute(%{base | gravity: {:smart, :face_assist}}, state)

      {:ok, %{image: smart}} = Crop.execute(%{base | gravity: :smart}, state)

      png = fn img -> Image.write!(img, :memory, suffix: ".png") end
      refute png.(assist) == png.(smart)
    end

    test "face_assist with no faces falls back to pure attention", %{image: image} do
      state = %State{
        image: image,
        detector: {ImagePipe.Test.FakeDetector, [result: {:ok, []}]}
      }

      base = %Crop{width: {:pixels, 200}, height: {:pixels, 200}, crop_from: :gravity}

      {:ok, %{image: assist}} =
        Crop.execute(%{base | gravity: {:smart, :face_assist}}, state)

      {:ok, %{image: smart}} = Crop.execute(%{base | gravity: :smart}, state)

      assert Image.write!(assist, :memory, suffix: ".png") ==
               Image.write!(smart, :memory, suffix: ".png")
    end

    test "face_assist with nil detector falls back to pure attention", %{image: image} do
      state = %State{image: image, detector: nil}

      op = %Crop{
        width: {:pixels, 200},
        height: {:pixels, 200},
        crop_from: :gravity,
        gravity: {:smart, :face_assist}
      }

      assert {:ok, %{image: out}} = Crop.execute(op, state)
      assert Image.width(out) == 200
    end
  end
end
