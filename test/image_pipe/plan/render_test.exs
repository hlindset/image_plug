defmodule ImagePipe.Plan.RenderTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Source

  defp base_plan(extra) do
    struct!(
      %Plan{
        source: %Source.Path{segments: ["a.jpg"]},
        pipelines: [],
        output: %Output{mode: :automatic}
      },
      extra
    )
  end

  test "render defaults to :image" do
    plan = base_plan(pipelines: [%Plan.Pipeline{operations: []}])
    assert plan.render == :image
  end

  test "validate_shape accepts a render spec carrying a module" do
    plan = base_plan(render: {:custom, SomeRendererModule, %{}})
    assert {:ok, ^plan} = Plan.validate_shape(plan)
  end

  test "validate_shape accepts the default :image" do
    plan = base_plan(pipelines: [%Plan.Pipeline{operations: []}])
    assert {:ok, ^plan} = Plan.validate_shape(plan)
  end

  test "validate_shape rejects a non-render, non-:image value" do
    plan = base_plan(render: :bogus)
    assert {:error, {:invalid_render_plan, :bogus}} = Plan.validate_shape(plan)
  end
end
