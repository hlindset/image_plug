defmodule ImagePipeDemoWeb.FiddlePage do
  use Hologram.Page
  alias ImagePipeDemo.Fiddle.{DemoState, ProcessingPath}
  alias ImagePipeDemoWeb.Components.Fiddle.RequestTool

  route "/demo"
  layout ImagePipeDemoWeb.FiddleLayout

  def init(_params, component, _server) do
    demo = DemoState.default()

    put_state(component,
      demo: demo,
      path: ProcessingPath.build(demo),
      preview_gen: 0,
      request_open: true
    )
  end

  def action(:toggle_request, _params, component) do
    put_state(component, :request_open, not component.state.request_open)
  end

  def action(:update_source, %{event: %{value: source}}, component) do
    recompute(component, DemoState.put_source(component.state.demo, source))
  end

  defp recompute(component, %DemoState{} = demo) do
    gen = component.state.preview_gen + 1

    component
    |> put_state(demo: demo, path: ProcessingPath.build(demo), preview_gen: gen)
  end

  def template do
    ~HOLO"""
    <div class="ip-demo fiddle-shell">
      <aside class="tools-sidebar">
        <div class="tool-stack">
          <RequestTool source={@demo.source} open={@request_open} />
        </div>
      </aside>
      <section class="preview-workspace">
        <div class="preview-command-bar"><code>{@path}</code></div>
        <div class="preview-canvas"></div>
      </section>
    </div>
    """
  end
end
