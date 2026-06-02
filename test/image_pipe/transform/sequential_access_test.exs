defmodule ImagePipe.Transform.SequentialAccessTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.Operation.AutoOrient
  alias ImagePipe.Transform.Operation.Background
  alias ImagePipe.Transform.Operation.Blur
  alias ImagePipe.Transform.Operation.Brightness
  alias ImagePipe.Transform.Operation.Contrast
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.Duotone
  alias ImagePipe.Transform.Operation.ExtendCanvas
  alias ImagePipe.Transform.Operation.Flip
  alias ImagePipe.Transform.Operation.Monochrome
  alias ImagePipe.Transform.Operation.NormalizeColorProfile
  alias ImagePipe.Transform.Operation.Padding
  alias ImagePipe.Transform.Operation.Pixelate
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.Operation.Saturation
  alias ImagePipe.Transform.Operation.Sharpen
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  @beach "priv/static/images/beach.jpg"
  @dog "priv/static/images/dog.jpg"

  # Harness self-check: prove the sequential open GENUINELY streams (does not
  # silently buffer). A 90-degree transpose built directly on the sequential
  # image — bypassing Chain, which would materialize first — must error when its
  # pixels are pulled, because vips_rot does a non-sequential read. If copy_memory
  # succeeds here, the open is buffering and every equivalence assertion below
  # would be a tautology.
  test "sequential open genuinely streams (a raw transpose errors at evaluation)" do
    body = File.read!(@beach)
    {:ok, image} = Image.open([body], access: :sequential, fail_on: :error)
    {:ok, rotated} = Image.rotate(image, 90)

    assert {:error, _reason} = VipsImage.copy_memory(rotated)
  end

  test "anchor crop streams" do
    assert_sequential_matches_random(
      [
        %Crop{
          width: {:pixels, 80},
          height: {:pixels, 60},
          crop_from: :gravity,
          gravity: {:anchor, :center, :center}
        }
      ],
      File.read!(@beach)
    )
  end

  test "fit resize streams" do
    assert_sequential_matches_random(
      [%Resize{mode: :fit, width: {:pixels, 120}, height: :auto}],
      File.read!(@dog)
    )
  end

  test "force resize streams" do
    assert_sequential_matches_random(
      [%Resize{mode: :force, width: {:pixels, 100}, height: {:pixels, 100}}],
      File.read!(@beach)
    )
  end

  test "horizontal flip streams" do
    assert_sequential_matches_random([%Flip{axis: :horizontal}], File.read!(@beach))
  end

  test "blur streams" do
    assert_sequential_matches_random([%Blur{sigma: 2.0}], File.read!(@beach))
  end

  test "sharpen streams" do
    assert_sequential_matches_random([%Sharpen{sigma: 1.5}], File.read!(@beach))
  end

  test "background flatten streams (alpha png)" do
    assert_sequential_matches_random(
      [%Background{color: [255, 0, 0, 255]}],
      alpha_png_body()
    )
  end

  test "padding streams" do
    assert_sequential_matches_random(
      [%Padding{top: 10, right: 10, bottom: 10, left: 10, fill: :transparent}],
      File.read!(@beach)
    )
  end

  test "canvas extend streams" do
    assert_sequential_matches_random(
      [
        %ExtendCanvas{
          rule: {:dimensions, {:pixels, 400}, {:pixels, 400}},
          gravity: {:anchor, :center, :center},
          background: :transparent
        }
      ],
      File.read!(@beach)
    )
  end

  test "pixelate streams" do
    assert_sequential_matches_random([%Pixelate{size: 8}], File.read!(@beach))
  end

  test "brightness streams" do
    assert_sequential_matches_random([%Brightness{value: 20}], File.read!(@beach))
  end

  test "contrast streams" do
    assert_sequential_matches_random([%Contrast{value: 15}], File.read!(@beach))
  end

  test "saturation streams" do
    assert_sequential_matches_random([%Saturation{value: 25}], File.read!(@beach))
  end

  test "monochrome streams" do
    assert_sequential_matches_random(
      [%Monochrome{intensity: 0.8, color: [179, 179, 179]}],
      File.read!(@beach)
    )
  end

  test "duotone streams" do
    assert_sequential_matches_random(
      [%Duotone{intensity: 0.8, shadow: [0, 0, 0], highlight: [255, 255, 255]}],
      File.read!(@beach)
    )
  end

  test "normalize color profile streams" do
    assert_sequential_matches_random([%NormalizeColorProfile{}], File.read!(@beach))
  end

  defp oriented_jpeg_body(orientation) do
    {:ok, image} = Image.new(120, 80, color: :red)

    image
    |> Image.set_orientation!(orientation)
    |> Image.write!(:memory, suffix: ".jpg")
  end

  for orientation <- [1, 2, 3, 4, 5, 6, 7, 8] do
    @orientation orientation
    test "auto-orient streams for EXIF orientation #{orientation}" do
      assert_sequential_matches_random([%AutoOrient{}], oriented_jpeg_body(@orientation))
    end
  end

  defp alpha_png_body do
    {:ok, image} = Image.new(320, 180, color: [0, 255, 0, 255], bands: 4)
    Image.write!(image, :memory, suffix: ".png")
  end

  defp run_chain(chain, access, body) when access in [:random, :sequential] do
    with {:ok, image} <- Image.open([body], access: access, fail_on: :error),
         {:ok, state} <- Chain.execute(%State{image: image}, chain),
         {:ok, %State{} = state} <- Materializer.materialize(state) do
      {:ok, state.image}
    end
  end

  defp assert_sequential_matches_random(chain, body) do
    {:ok, random_image} = run_chain(chain, :random, body)
    {:ok, sequential_image} = run_chain(chain, :sequential, body)

    assert Image.width(sequential_image) == Image.width(random_image)
    assert Image.height(sequential_image) == Image.height(random_image)
    assert Image.has_alpha?(sequential_image) == Image.has_alpha?(random_image)
    assert_sampled_pixels_match(sequential_image, random_image)
  end

  defp assert_sampled_pixels_match(left, right) do
    for x <- sample_positions(Image.width(left)),
        y <- sample_positions(Image.height(left)) do
      assert Image.get_pixel!(left, x, y) == Image.get_pixel!(right, x, y)
    end
  end

  defp sample_positions(size) do
    last = max(size - 1, 0)
    Enum.uniq([0, div(last, 4), div(last, 2), div(last * 3, 4), last])
  end
end
