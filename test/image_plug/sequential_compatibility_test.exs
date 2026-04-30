defmodule ImagePlug.SequentialCompatibilityTest do
  use ExUnit.Case, async: true

  alias ImagePlug.ImageMaterializer
  alias ImagePlug.Origin
  alias ImagePlug.Transform.Contain
  alias ImagePlug.Transform.Contain.ContainParams
  alias ImagePlug.Transform.Scale
  alias ImagePlug.Transform.Scale.ScaleParams
  alias ImagePlug.TransformChain
  alias ImagePlug.TransformState

  @cat_path "priv/static/images/cat-300.jpg"
  @dog_path "priv/static/images/dog.jpg"

  test "width-only scale matches random access after materialization" do
    chain = [
      {Scale, %ScaleParams{type: :dimensions, width: {:pixels, 100}, height: :auto}}
    ]

    assert_sequential_matches_random(chain, jpeg_body(@cat_path))
  end

  test "height-only scale matches random access after materialization" do
    chain = [
      {Scale, %ScaleParams{type: :dimensions, width: :auto, height: {:pixels, 100}}}
    ]

    assert_sequential_matches_random(chain, jpeg_body(@cat_path))
  end

  test "width-only upscale matches random access after materialization" do
    chain = [
      {Scale, %ScaleParams{type: :dimensions, width: {:pixels, 400}, height: :auto}}
    ]

    assert_sequential_matches_random(chain, jpeg_body(@cat_path))
  end

  test "height-only upscale matches random access after materialization" do
    chain = [
      {Scale, %ScaleParams{type: :dimensions, width: :auto, height: {:pixels, 400}}}
    ]

    assert_sequential_matches_random(chain, jpeg_body(@cat_path))
  end

  test "regular non-letterboxed contain matches random access after materialization" do
    chain = [
      {Contain,
       %ContainParams{
         type: :dimensions,
         width: {:pixels, 100},
         height: {:pixels, 80},
         constraint: :regular,
         letterbox: false
       }}
    ]

    assert_sequential_matches_random(chain, jpeg_body(@cat_path))
  end

  test "width-only regular non-letterboxed contain matches random access after materialization" do
    chain = [
      {Contain,
       %ContainParams{
         type: :dimensions,
         width: {:pixels, 100},
         height: :auto,
         constraint: :regular,
         letterbox: false
       }}
    ]

    assert_sequential_matches_random(chain, jpeg_body(@cat_path))
  end

  test "height-only regular non-letterboxed contain matches random access after materialization" do
    chain = [
      {Contain,
       %ContainParams{
         type: :dimensions,
         width: :auto,
         height: {:pixels, 80},
         constraint: :regular,
         letterbox: false
       }}
    ]

    assert_sequential_matches_random(chain, jpeg_body(@cat_path))
  end

  test "regular non-letterboxed contain matches random access for progressive non-square jpeg" do
    chain = [
      {Contain,
       %ContainParams{
         type: :dimensions,
         width: {:pixels, 120},
         height: {:pixels, 90},
         constraint: :regular,
         letterbox: false
       }}
    ]

    assert_sequential_matches_random(chain, jpeg_body(@dog_path))
  end

  test "regular non-letterboxed contain matches random access for alpha png" do
    chain = [
      {Contain,
       %ContainParams{
         type: :dimensions,
         width: {:pixels, 400},
         height: {:pixels, 400},
         constraint: :regular,
         letterbox: false
       }}
    ]

    assert_sequential_matches_random(chain, alpha_png_body(), "image/png")
  end

  test "successful sequential materialization drains origin stream before delivery" do
    chain = [
      {Scale, %ScaleParams{type: :dimensions, width: {:pixels, 100}, height: :auto}}
    ]

    {:ok, _sequential_image, sequential_response} =
      run_chain(chain, :sequential, jpeg_body(@cat_path), "image/jpeg")

    assert Origin.terminal_status(sequential_response) == :done
    assert Origin.terminal_status(sequential_response) == :done
  end

  defp assert_sequential_matches_random(chain, body, content_type \\ "image/jpeg") do
    {:ok, random_image, _random_response} = run_chain(chain, :random, body, content_type)

    {:ok, sequential_image, sequential_response} =
      run_chain(chain, :sequential, body, content_type)

    assert Origin.terminal_status(sequential_response) == :done
    assert Origin.terminal_status(sequential_response) == :done
    assert Image.width(sequential_image) == Image.width(random_image)
    assert Image.height(sequential_image) == Image.height(random_image)
    assert Image.has_alpha?(sequential_image) == Image.has_alpha?(random_image)
    assert_sampled_pixels_match(sequential_image, random_image)
  end

  defp run_chain(chain, access, body, content_type) when access in [:random, :sequential] do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type(content_type)
      |> Plug.Conn.send_resp(200, body)
    end

    with {:ok, response} <-
           Origin.fetch("https://img.example/fixture", plug: plug),
         {:ok, image} <- Image.open(response.stream, access: access, fail_on: :error),
         {:ok, state} <- TransformChain.execute(%TransformState{image: image}, chain),
         {:ok, materialized_image} <- ImageMaterializer.materialize(state.image) do
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
