defmodule ImagePipe.Plan.RenderContextTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.RenderContext
  alias ImagePipe.Plan.SourceInfo

  test "carries a SourceInfo" do
    info = %SourceInfo{format: :jpeg, width: 4, height: 3, orientation: 1}
    ctx = %RenderContext{info: info}
    assert ctx.info == info
  end
end
