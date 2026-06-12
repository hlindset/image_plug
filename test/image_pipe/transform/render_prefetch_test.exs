defmodule ImagePipe.Transform.RenderPrefetchTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Source
  alias ImagePipe.Transform

  defp plan(extra) do
    struct!(
      %Plan{
        source: %Source.Path{segments: ["a.jpg"]},
        pipelines: [],
        output: %Output{mode: :automatic}
      },
      extra
    )
  end

  test "a render plan with an empty pipeline is prefetch-safe (returns {:ok, []})" do
    p = plan(render: {:custom, SomeRendererModule, %{}}, output: nil)
    assert {:ok, []} = Transform.validate_prefetch_safe_plan(p)
  end

  test "an image-encode plan with an empty pipeline is still rejected" do
    p = plan(render: :image)
    assert {:error, :empty_pipeline_plan} = Transform.validate_prefetch_safe_plan(p)
  end

  test "a malformed render plan is rejected by shape validation before the pipeline check" do
    p = plan(render: :bogus)
    assert {:error, {:invalid_render_plan, :bogus}} = Transform.validate_prefetch_safe_plan(p)
  end
end
