defmodule ImagePipeDemo.Fiddle.SampleImages do
  @moduledoc "Hardcoded sample-image sources for the demo (no Vite scan)."

  @images [
    %{path: "images/dog.jpg", width: 5011, height: 7516},
    %{path: "images/beach.jpg", width: 4000, height: 2667}
  ]

  def all, do: @images
  def paths, do: Enum.map(@images, & &1.path)
  def valid?(path), do: Enum.any?(@images, &(&1.path == path))
  def width(path), do: dim(path).width
  def height(path), do: dim(path).height

  defp dim(path), do: Enum.find(@images, &(&1.path == path))
end
