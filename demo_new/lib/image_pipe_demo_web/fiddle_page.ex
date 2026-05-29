defmodule ImagePipeDemoWeb.FiddlePage do
  use Hologram.Page
  alias ImagePipeDemo.Fiddle.{DemoState, ProcessingPath}

  route "/demo"
  layout ImagePipeDemoWeb.FiddleLayout

  def init(_params, component, _server) do
    demo = DemoState.default()

    put_state(component,
      demo: demo,
      path: ProcessingPath.build(demo)
    )
  end

  def template do
    ~HOLO"""
    <div class="ip-demo fiddle-shell">
      <p>path: {@path}</p>
    </div>
    """
  end
end
