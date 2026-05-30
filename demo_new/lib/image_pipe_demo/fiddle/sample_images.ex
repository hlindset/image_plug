defmodule ImagePipeDemo.Fiddle.SampleImages do
  @moduledoc "Hardcoded sample-image sources for the demo (no Vite scan)."

  @images [
    %{path: "images/dog.jpg", width: 5011, height: 7516},
    %{path: "images/beach.jpg", width: 4000, height: 2667}
  ]

  def all, do: @images
  def paths, do: Enum.map(@images, fn image -> image.path end)
  def valid?(path), do: Enum.any?(@images, fn image -> image.path == path end)
  def width(path), do: dim(path).width
  def height(path), do: dim(path).height

  # NOTE: use an explicit `fn image -> … end` rather than the `&(&1.path …)`
  # capture shorthand. Hologram 0.9 mis-compiles the `&1.field` capture to a
  # `matchPlaceholder()` (undefined) on the client, so the shorthand crashes
  # with a BadMapError when these run in the browser (e.g. CropTool reading
  # `SampleImages.width(@demo.source)` for the slider max). Server-side Elixir
  # is unaffected, which is why SSR/init worked but the crop toggle did not.
  defp dim(path), do: Enum.find(@images, fn image -> image.path == path end)
end
