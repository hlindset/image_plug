defmodule ImagePipeDemoWeb.FiddlePage do
  use Hologram.Page
  use Hologram.JS
  alias ImagePipeDemo.Fiddle.{DemoState, ProcessingPath}
  alias ImagePipeDemoWeb.Components.Fiddle.CommandBar
  alias ImagePipeDemoWeb.Components.Fiddle.CropTool
  alias ImagePipeDemoWeb.Components.Fiddle.RequestTool

  js_import :copy, from: "./fiddle/clipboard.mjs"
  js_import :load, from: "./fiddle/preview.mjs"

  alias ImagePipeDemoWeb.Components.Fiddle.PreviewCanvas

  route "/demo"
  layout ImagePipeDemoWeb.FiddleLayout

  def init(_params, component, _server) do
    demo = DemoState.default()

    component
    |> put_state(
      demo: demo,
      path: ProcessingPath.build(demo),
      preview_gen: 0,
      request_open: true,
      preview_loading: true,
      preview_error: nil,
      preview_object_url: nil,
      preview_width: nil,
      preview_height: nil,
      preview_bytes: nil,
      preview_content_type: nil
    )
    |> put_action(name: :commit, params: %{gen: 0})
  end

  def action(:copy_url, _params, component) do
    _ = JS.call(:copy, ["/img" <> component.state.path]) |> Task.await()
    component
  end

  def action(:commit, %{gen: gen}, component) do
    if gen != component.state.preview_gen do
      component
    else
      component = put_state(component, :preview_loading, true)
      result = JS.call(:load, ["/img" <> component.state.path]) |> Task.await()
      apply_preview_result(component, result)
    end
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
    |> put_action(name: :commit, delay: 150, params: %{gen: gen})
  end

  defp apply_preview_result(component, %{"ok" => true} = r) do
    put_state(component,
      preview_loading: false,
      preview_error: nil,
      preview_object_url: r["objectUrl"],
      preview_width: r["width"],
      preview_height: r["height"],
      preview_bytes: r["bytes"],
      preview_content_type: r["contentType"]
    )
  end

  defp apply_preview_result(component, %{"ok" => false, "kind" => "abort"}), do: component

  defp apply_preview_result(component, %{"ok" => false} = r) do
    put_state(component, preview_loading: false, preview_error: preview_error_label(r))
  end

  defp preview_error_label(%{"kind" => "http", "status" => status, "body" => body}),
    do: "#{status}: #{body}"

  defp preview_error_label(%{"message" => message}), do: message
  defp preview_error_label(_), do: "Preview failed"

  defp size_label(true, _w, _h, _b), do: "Loading"
  defp size_label(_loading, nil, _h, _b), do: ""
  defp size_label(_loading, w, h, nil), do: "#{w} × #{h}"
  defp size_label(_loading, w, h, bytes), do: "#{w} × #{h} (#{max(1, div(bytes, 1024))} kB)"

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
        <PreviewCanvas
          object_url={@preview_object_url}
          loading={@preview_loading}
          error={@preview_error}
          size_label={size_label(@preview_loading, @preview_width, @preview_height, @preview_bytes)}
          output_label={@preview_content_type || "auto"}
        />
      </section>
    </div>
    """
  end
end
