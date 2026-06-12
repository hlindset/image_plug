defmodule ImagePipe.Cache.KeyRenderTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.Key
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Render
  alias ImagePipe.Plan.Source

  defp representation(render) do
    plan =
      struct!(
        %Plan{
          source: %Source.Path{segments: ["a.jpg"]},
          pipelines: [%Plan.Pipeline{operations: []}],
          output: %Output{mode: :automatic}
        },
        render: render
      )

    {:ok, material} = Key.plan_material(plan, [])
    material[:representation]
  end

  test "render selector changes the representation key data" do
    image = representation(:image_encode)
    info = representation(%Render{module: SomeRenderer, params: %{}})
    refute image == info
  end

  test "different render modules produce different representation data" do
    a = representation(%Render{module: RendererA, params: %{}})
    b = representation(%Render{module: RendererB, params: %{}})
    refute a == b
  end

  test "the :image_encode representation is unchanged (still just the version)" do
    assert representation(:image_encode) == [version: Key.representation_version()]
  end
end
