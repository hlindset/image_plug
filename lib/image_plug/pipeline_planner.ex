defmodule ImagePlug.PipelinePlanner do
  @moduledoc """
  Converts native processing requests into executable transform chains.
  """

  alias ImagePlug.ProcessingRequest
  alias ImagePlug.Transform
  alias ImagePlug.TransformChain

  @default_focus {:anchor, :center, :center}

  @spec plan(ProcessingRequest.t()) :: {:ok, TransformChain.t()} | {:error, term()}
  def plan(%ProcessingRequest{} = request) do
    with {:ok, geometry_chain} <- plan_geometry(request) do
      chain =
        geometry_chain
        |> prepend_focus(request.focus)
        |> append_output(request.format)

      {:ok, chain}
    end
  end

  defp plan_geometry(%ProcessingRequest{fit: nil, width: nil, height: nil}), do: {:ok, []}

  defp plan_geometry(%ProcessingRequest{fit: nil, width: width, height: height}) do
    {:ok, [scale(width || :auto, height || :auto)]}
  end

  defp plan_geometry(%ProcessingRequest{fit: :cover, width: nil}), do: missing_dimensions(:cover)
  defp plan_geometry(%ProcessingRequest{fit: :cover, height: nil}), do: missing_dimensions(:cover)

  defp plan_geometry(%ProcessingRequest{fit: :cover, width: width, height: height}) do
    {:ok,
     [
       {Transform.Cover,
        %Transform.Cover.CoverParams{
          type: :dimensions,
          width: width,
          height: height,
          constraint: :none
        }}
     ]}
  end

  defp plan_geometry(%ProcessingRequest{fit: :contain, width: nil, height: nil}) do
    missing_dimensions(:contain)
  end

  defp plan_geometry(%ProcessingRequest{fit: :contain, width: width, height: height}) do
    {:ok, [contain(width || :auto, height || :auto, false)]}
  end

  defp plan_geometry(%ProcessingRequest{fit: :fill, width: nil}), do: missing_dimensions(:fill)
  defp plan_geometry(%ProcessingRequest{fit: :fill, height: nil}), do: missing_dimensions(:fill)

  defp plan_geometry(%ProcessingRequest{fit: :fill, width: width, height: height}) do
    {:ok, [scale(width, height)]}
  end

  defp plan_geometry(%ProcessingRequest{fit: :inside, width: nil}),
    do: missing_dimensions(:inside)

  defp plan_geometry(%ProcessingRequest{fit: :inside, height: nil}),
    do: missing_dimensions(:inside)

  defp plan_geometry(%ProcessingRequest{fit: :inside, width: width, height: height}) do
    {:ok, [contain(width, height, true)]}
  end

  defp plan_geometry(%ProcessingRequest{fit: fit}), do: {:error, {:unsupported_fit, fit}}

  defp scale(width, height) do
    {Transform.Scale,
     %Transform.Scale.ScaleParams{
       type: :dimensions,
       width: width,
       height: height
     }}
  end

  defp contain(width, height, letterbox) do
    {Transform.Contain,
     %Transform.Contain.ContainParams{
       type: :dimensions,
       width: width,
       height: height,
       constraint: :regular,
       letterbox: letterbox
     }}
  end

  defp prepend_focus([], _focus), do: []
  defp prepend_focus(chain, @default_focus), do: chain

  defp prepend_focus([{Transform.Cover, _params} | _rest] = chain, focus) do
    [{Transform.Focus, %Transform.Focus.FocusParams{type: focus}} | chain]
  end

  defp prepend_focus(chain, _focus), do: chain

  defp append_output(chain, nil), do: chain
  defp append_output(chain, :auto), do: chain

  defp append_output(chain, format) do
    chain ++ [{Transform.Output, %Transform.Output.OutputParams{format: format}}]
  end

  defp missing_dimensions(fit), do: {:error, {:missing_dimensions, fit}}
end
