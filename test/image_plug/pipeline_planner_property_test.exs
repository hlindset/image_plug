defmodule ImagePlug.PipelinePlannerPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePlug.PipelinePlanner
  alias ImagePlug.ProcessingRequest
  alias ImagePlug.Transform

  property "explicit output format is always planned last" do
    check all request <- valid_plannable_request_with_explicit_format(),
              max_runs: 100 do
      assert {:ok, chain} = PipelinePlanner.plan(request)

      assert List.last(chain) ==
               {Transform.Output, %Transform.Output.OutputParams{format: request.format}}
    end
  end

  defp valid_plannable_request_with_explicit_format do
    map({valid_geometry(), member_of([:webp, :avif, :jpeg, :png])}, fn {geometry, format} ->
      request(Keyword.put(geometry, :format, format))
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
