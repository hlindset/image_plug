defmodule ImagePipe.SequentialCompatibilityTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.Response
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.Operation.AutoOrient
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.State

  @cat_path "priv/static/images/beach.jpg"
  @dog_path "priv/static/images/dog.jpg"

  test "auto-orient-only chains match random access after materialization" do
    chain = [
      %AutoOrient{}
    ]

    assert_sequential_matches_random(chain, jpeg_body(@cat_path))
  end

  test "width-only fit resize matches random access after materialization" do
    chain = [
      %Resize{mode: :fit, width: {:pixels, 100}, height: :auto}
    ]

    assert_sequential_matches_random(chain, jpeg_body(@cat_path))
  end

  test "height-only fit resize matches random access after materialization" do
    chain = [
      %Resize{mode: :fit, width: :auto, height: {:pixels, 100}}
    ]

    assert_sequential_matches_random(chain, jpeg_body(@cat_path))
  end

  test "width-only fit upscale matches random access after materialization" do
    chain = [
      %Resize{mode: :fit, width: {:pixels, 400}, height: :auto}
    ]

    assert_sequential_matches_random(chain, jpeg_body(@cat_path))
  end

  test "height-only fit upscale matches random access after materialization" do
    chain = [
      %Resize{mode: :fit, width: :auto, height: {:pixels, 400}}
    ]

    assert_sequential_matches_random(chain, jpeg_body(@cat_path))
  end

  test "force resize matches random access after materialization" do
    chain = [
      %Resize{mode: :force, width: {:pixels, 100}, height: :auto}
    ]

    assert_sequential_matches_random(chain, jpeg_body(@cat_path))
  end

  test "fit resize matches random access for progressive non-square jpeg" do
    chain = [
      %Resize{mode: :fit, width: {:pixels, 120}, height: {:pixels, 90}}
    ]

    assert_sequential_matches_random(chain, jpeg_body(@dog_path))
  end

  test "fit resize matches random access for alpha png" do
    chain = [
      %Resize{mode: :fit, width: {:pixels, 400}, height: {:pixels, 400}}
    ]

    assert_sequential_matches_random(chain, alpha_png_body(), "image/png")
  end

  defp assert_sequential_matches_random(chain, body, content_type \\ "image/jpeg") do
    {:ok, random_image, _random_response} = run_chain(chain, :random, body, content_type)

    {:ok, sequential_image, _sequential_response} =
      run_chain(chain, :sequential, body, content_type)

    assert Image.width(sequential_image) == Image.width(random_image)
    assert Image.height(sequential_image) == Image.height(random_image)
    assert Image.has_alpha?(sequential_image) == Image.has_alpha?(random_image)
    assert_sampled_pixels_match(sequential_image, random_image)
  end

  defp run_chain(chain, access, body, _content_type) when access in [:random, :sequential] do
    response = %Response{stream: [body]}

    with {:ok, image} <-
           Image.open(response.stream, access: access, fail_on: :error),
         {:ok, state} <- Chain.execute(%State{image: image}, chain),
         {:ok, materialized_image} <- Materializer.materialize(state.image) do
      {:ok, materialized_image, response}
    end
  end

  defp assert_sampled_pixels_match(left, right) do
    width = Image.width(left)
    height = Image.height(left)

    for x <- sample_positions(width),
        y <- sample_positions(height) do
      assert Image.get_pixel!(left, x, y) == Image.get_pixel!(right, x, y)
    end
  end

  defp sample_positions(size) do
    last = max(size - 1, 0)

    [0, div(last, 4), div(last, 2), div(last * 3, 4), last]
    |> Enum.uniq()
  end

  defp jpeg_body(path), do: File.read!(path)

  defp alpha_png_body do
    {:ok, image} = Image.new(320, 180, color: [0, 255, 0, 255], bands: 4)
    Image.write!(image, :memory, suffix: ".png")
  end
end
