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
      map(pixel_dimension(), &[width: &1]),
      map(pixel_dimension(), &[height: &1]),
      map({pixel_dimension(), pixel_dimension()}, fn {width, height} ->
        [width: width, height: height]
      end),
      map({member_of([:cover, :fill, :inside]), pixel_dimension(), pixel_dimension()}, fn
        {fit, width, height} -> [fit: fit, width: width, height: height]
      end),
      map(
        {constant(:contain), one_of([pixel_dimension(), constant(nil)]),
         one_of([pixel_dimension(), constant(nil)])},
        fn
          {:contain, nil, nil} -> [fit: :contain, width: {:pixels, 1}]
          {:contain, width, height} -> [fit: :contain, width: width, height: height]
        end
      )
    ])
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
