defmodule ImagePipeDemoWeb.FiddlePage do
  use Hologram.Page
  use Hologram.JS
  alias ImagePipeDemo.Fiddle.{DemoState, ProcessingPath}
  alias ImagePipeDemoWeb.Components.Fiddle.CommandBar
  alias ImagePipeDemoWeb.Components.Fiddle.CropTool
  alias ImagePipeDemoWeb.Components.Fiddle.RequestTool

  js_import :copy, from: "./fiddle/clipboard.mjs"

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

  def action(:copy_url, _params, component) do
    _ = JS.call(:copy, ["/img" <> component.state.path]) |> Task.await()
    component
  end

  def action(:toggle_request, _params, component) do
    put_state(component, :request_open, not component.state.request_open)
  end

  def action(:update_source, %{event: %{value: source}}, component) do
    recompute(component, DemoState.put_source(component.state.demo, source))
  end

  def action(:toggle_crop, _params, component) do
    demo = %{component.state.demo | crop_enabled: not component.state.demo.crop_enabled}
    recompute(component, demo)
  end

  def action(:set_crop_gravity, %{event: %{value: value}}, component) do
    recompute(component, %{component.state.demo | crop_gravity: value})
  end

  def action(:set_crop_width_unit, %{event: %{value: value}}, component) do
    recompute(component, %{component.state.demo | crop_width_unit: parse_unit(value)})
  end

  def action(:set_crop_height_unit, %{event: %{value: value}}, component) do
    recompute(component, %{component.state.demo | crop_height_unit: parse_unit(value)})
  end

  def action(:set_crop_width, %{event: %{value: value}}, component) do
    recompute(component, put_axis_value(component.state.demo, :width, value))
  end

  def action(:set_crop_height, %{event: %{value: value}}, component) do
    recompute(component, put_axis_value(component.state.demo, :height, value))
  end

  defp recompute(component, %DemoState{} = demo) do
    gen = component.state.preview_gen + 1

    component
    |> put_state(demo: demo, path: ProcessingPath.build(demo), preview_gen: gen)
  end

  defp parse_unit("px"), do: :px
  defp parse_unit("percent"), do: :percent
  defp parse_unit("full"), do: :full

  defp put_axis_value(demo, axis, raw) do
    case Integer.parse(to_string(raw)) do
      {n, _} -> put_axis_value(demo, axis, n, unit_for(demo, axis))
      :error -> demo
    end
  end

  defp unit_for(demo, :width), do: demo.crop_width_unit
  defp unit_for(demo, :height), do: demo.crop_height_unit

  defp put_axis_value(demo, :width, n, :percent),
    do: %{demo | crop_width_percent: clamp(n, 1, 99)}

  defp put_axis_value(demo, :width, n, _px), do: %{demo | crop_width: max(1, n)}

  defp put_axis_value(demo, :height, n, :percent),
    do: %{demo | crop_height_percent: clamp(n, 1, 99)}

  defp put_axis_value(demo, :height, n, _px), do: %{demo | crop_height: max(1, n)}

  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)

  def template do
    ~HOLO"""
    <div class="ip-demo fiddle-shell">
      <aside class="tools-sidebar">
        <div class="tool-stack">
          <RequestTool source={@demo.source} open={@request_open} />
          <CropTool demo={@demo} />
        </div>
      </aside>
      <section class="preview-workspace">
        <CommandBar path={@path} image_url={"/img" <> @path} />
        <div class="preview-canvas"></div>
      </section>
    </div>
    """
  end
end
