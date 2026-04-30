defmodule ImagePlug.InputDecodeAccessBenchmark do
  alias ImagePlug.ImageMaterializer
  alias ImagePlug.Transform.Scale
  alias ImagePlug.Transform.Scale.ScaleParams
  alias ImagePlug.TransformChain
  alias ImagePlug.TransformState

  @scale_chain [
    {Scale, %ScaleParams{type: :dimensions, width: {:pixels, 200}, height: :auto}}
  ]

  def run(argv) do
    {:ok, _apps} = Application.ensure_all_started(:image)

    access = parse_access(argv)
    body = large_jpeg_body()

    {microseconds, {:ok, image}} =
      :timer.tc(fn ->
        with {:ok, image} <- Image.open([body], access: access, fail_on: :error),
             {:ok, state} <- TransformChain.execute(%TransformState{image: image}, @scale_chain),
             {:ok, materialized} <- ImageMaterializer.materialize(state.image) do
          {:ok, materialized}
        end
      end)

    IO.puts("access=#{access}")
    IO.puts("width=#{Image.width(image)}")
    IO.puts("height=#{Image.height(image)}")
    IO.puts("wall_ms=#{System.convert_time_unit(microseconds, :microsecond, :millisecond)}")
    IO.puts("beam_memory_bytes=#{:erlang.memory(:total)}")
    IO.puts("vips_tracked_memory_bytes=#{Vix.Vips.tracked_get_mem()}")
    IO.puts("vips_highwater_memory_bytes=#{Vix.Vips.tracked_get_mem_highwater()}")
  end

  defp parse_access(["random"]), do: :random
  defp parse_access(["sequential"]), do: :sequential
  defp parse_access(["--" | argv]), do: parse_access(argv)

  defp parse_access(other) do
    raise ArgumentError, "expected one argument: random or sequential, got #{inspect(other)}"
  end

  defp large_jpeg_body do
    {:ok, source} = Image.open("priv/static/images/cat-300.jpg", access: :random, fail_on: :error)
    {:ok, large} = Image.resize(source, 16.0)
    Image.write!(large, :memory, suffix: ".jpg")
  end
end

ImagePlug.InputDecodeAccessBenchmark.run(System.argv())
