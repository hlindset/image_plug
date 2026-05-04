defmodule ImagePlug.PipelinePlannerPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePlug.PipelinePlanner
  alias ImagePlug.ProcessingRequest

  property "explicit output format does not change planned operations" do
    check all {request, request_without_format} <- valid_plannable_request_pair(),
              max_runs: 100 do
      assert {:ok, chain} = PipelinePlanner.plan(request)
      assert {:ok, chain_without_format} = PipelinePlanner.plan(request_without_format)

      refute Enum.any?(chain, fn {module, _params} ->
               Module.split(module) == ["ImagePlug", "Transform", "Output"]
             end)

      assert chain == chain_without_format
    end
  end

  defp valid_plannable_request_pair do
    map({valid_geometry(), member_of([:webp, :avif, :jpeg, :png])}, fn {geometry, format} ->
      {request(Keyword.put(geometry, :format, format)), request(geometry)}
    end)
  end

  defp valid_geometry do
    one_of([
      constant([]),
      map(fit_dimension(), &[width: &1]),
      map(fit_dimension(), &[height: &1]),
      map({fit_dimension(), fit_dimension()}, fn {width, height} ->
        [width: width, height: height]
      end),
      map({constant(:fill), fit_dimension(), fit_dimension()}, fn {resizing_type, width, height} ->
        [resizing_type: resizing_type, width: width, height: height]
      end),
      constant(resizing_type: :force),
      map({constant(:force), pixel_dimension(), one_of([pixel_dimension(), constant(nil)])}, fn
        {resizing_type, width, height} ->
          [resizing_type: resizing_type, width: width, height: height]
      end)
    ])
  end

  defp fit_dimension do
    map(integer(0..10_000), &{:pixels, &1})
  end

  defp pixel_dimension do
    map(integer(1..10_000), &{:pixels, &1})
  end

  defp request(attrs) do
    struct!(
      ProcessingRequest,
      Keyword.merge(
        [
          signature: "_",
          source_kind: :plain,
          source_path: ["images", "cat.jpg"]
        ],
        attrs
      )
    )
  end
end
