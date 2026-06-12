defmodule ImagePipe.Cache.KeyRenderTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.Key
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Output
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
    image = representation(:image)
    info = representation({:custom, SomeRenderer, %{}})
    refute image == info
  end

  test "different render modules produce different representation data" do
    a = representation({:custom, RendererA, %{}})
    b = representation({:custom, RendererB, %{}})
    refute a == b
  end

  test "the :image representation is unchanged (still just the version)" do
    assert representation(:image) == [version: Key.representation_version()]
  end
end
