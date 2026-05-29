# Hologram Demo Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the Svelte image-transform fiddle to Hologram as spike #1 — full desktop app shell (dark) + Request and Crop tools + a real `fetch`-based preview — running against the ImagePipe plug already mounted at `/img` in `demo_new/`.

**Architecture:** One Hologram page (`route "/demo"`) holds the entire flat demo state; stateless tool components render from props and fire actions at `target: "page"`. The page recomputes a pure imgproxy path on every change and, debounced via a generation counter, calls a JS-interop facade that fetches the image and returns metadata. CSS is one global stylesheet scoped with `@scope (.ip-demo)`; dark theme only.

**Tech Stack:** Elixir + Hologram 0.9 (Pages/Components/Actions, `~HOLO` templates, JS interop), the ImagePipe imgproxy parser/plug, ExUnit, plain CSS (`@scope`, no esbuild/Tailwind).

**Reference (read, do not modify):** the Svelte original at `/Users/hlindset/src/image_plug/demo/src/` — especially `processing-path.ts` (encoding), `App.svelte` (shell markup + `<style>` at lines 1378–2152), `styles.css` (theme vars), `CropDimensionControl.svelte`, `ToolToggleHeader.svelte`.

**Spec:** `docs/superpowers/specs/2026-05-29-hologram-demo-spike-design.md` (twice-reviewed).

**Working dir for all commands:** `demo_new/`. Prefix Elixir commands with `mise exec --`. Run the server with `HOLOGRAM_START=1 mise exec -- mix phx.server`.

---

## File structure

```
demo_new/
  lib/image_pipe_demo/fiddle/
    sample_images.ex          # [{path,width,height}] sources (pure)
    demo_state.ex             # flat state struct + defaults + source-driven crop reset (pure)
    processing_path.ex        # DemoState -> imgproxy path (pure)
  lib/image_pipe_demo_web/
    fiddle_layout.ex          # <html data-theme="dark"> + Runtime + css link + <slot/>
    fiddle_page.ex            # route "/demo"; owns state, actions, preview orchestration
    fiddle/preview.mjs        # JS interop facade: fetch image -> tagged result map
    components/fiddle/
      tool_toggle_header.ex   # title/summary + on/off switch button
      request_tool.ex         # source <select>
      crop_dimension_control.ex # number + unit select + range slider
      crop_tool.ex            # width/height (CropDimensionControl) + gravity select
      command_bar.ex          # live parameter code + Copy URL / Open
      preview_canvas.ex       # checkerboard, <img>, metadata, spinner, error
  priv/static/css/fiddle.css  # global theme vars + @scope (.ip-demo) component styles
  priv/static/images/         # dog.jpg + beach.jpg (already present)
  test/image_pipe_demo/fiddle/ # ExUnit for the pure modules
  test/image_pipe_demo_web/    # wire-level plug test
```

The three pure modules are the correctness core and are fully unit-tested. The page/components/CSS are verified by the wire test + a browser screenshot. `preview.mjs` is colocated under `lib/.../fiddle/` so it can be imported with a relative path from the page module.

---

## Task 1: SampleImages (pure)

**Files:**
- Create: `lib/image_pipe_demo/fiddle/sample_images.ex`
- Test: `test/image_pipe_demo/fiddle/sample_images_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/image_pipe_demo/fiddle/sample_images_test.exs
defmodule ImagePipeDemo.Fiddle.SampleImagesTest do
  use ExUnit.Case, async: true
  alias ImagePipeDemo.Fiddle.SampleImages

  test "lists the two spike sources with dimensions" do
    assert SampleImages.paths() == ["images/dog.jpg", "images/beach.jpg"]
    assert SampleImages.width("images/dog.jpg") == 5011
    assert SampleImages.height("images/dog.jpg") == 7516
    assert SampleImages.width("images/beach.jpg") == 4000
    assert SampleImages.height("images/beach.jpg") == 2667
  end

  test "valid?/1 distinguishes known sources" do
    assert SampleImages.valid?("images/dog.jpg")
    refute SampleImages.valid?("images/nope.jpg")
  end
end
```

- [ ] **Step 2: Run it; expect failure**

Run: `mise exec -- mix test test/image_pipe_demo/fiddle/sample_images_test.exs`
Expected: FAIL (`SampleImages` undefined).

- [ ] **Step 3: Implement**

```elixir
# lib/image_pipe_demo/fiddle/sample_images.ex
defmodule ImagePipeDemo.Fiddle.SampleImages do
  @moduledoc "Hardcoded sample-image sources for the demo (no Vite scan)."

  @images [
    %{path: "images/dog.jpg", width: 5011, height: 7516},
    %{path: "images/beach.jpg", width: 4000, height: 2667}
  ]

  def all, do: @images
  def paths, do: Enum.map(@images, & &1.path)
  def valid?(path), do: Enum.any?(@images, &(&1.path == path))
  def width(path), do: dim(path).width
  def height(path), do: dim(path).height

  defp dim(path), do: Enum.find(@images, %{width: 1, height: 1}, &(&1.path == path))
end
```

- [ ] **Step 4: Run it; expect pass**

Run: `mise exec -- mix test test/image_pipe_demo/fiddle/sample_images_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe_demo/fiddle/sample_images.ex test/image_pipe_demo/fiddle/sample_images_test.exs
git commit -m "feat(demo): SampleImages source list for the fiddle spike"
```

---

## Task 2: DemoState (pure)

The flat state, restricted to spike-1 fields (Request: `source`; Crop: enable + width/height unit/px/percent + gravity). Crop px defaults derive from the source dimensions and reset when the source changes (ports `resetCropPixelsToSource`, `processing-path.ts:174`).

**Files:**
- Create: `lib/image_pipe_demo/fiddle/demo_state.ex`
- Test: `test/image_pipe_demo/fiddle/demo_state_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/image_pipe_demo/fiddle/demo_state_test.exs
defmodule ImagePipeDemo.Fiddle.DemoStateTest do
  use ExUnit.Case, async: true
  alias ImagePipeDemo.Fiddle.DemoState

  test "default starts on dog.jpg with crop disabled and px sized to the source" do
    s = DemoState.default()
    assert s.source == "images/dog.jpg"
    assert s.crop_enabled == false
    assert s.crop_width_unit == :px
    assert s.crop_width == 5011
    assert s.crop_height == 7516
    assert s.crop_width_percent == 50
    assert s.crop_gravity == "inherit"
  end

  test "put_source resets crop px to the new source dimensions" do
    s = DemoState.default() |> DemoState.put_source("images/beach.jpg")
    assert s.source == "images/beach.jpg"
    assert s.crop_width == 4000
    assert s.crop_height == 2667
  end

  test "put_source ignores unknown sources" do
    s = DemoState.default()
    assert DemoState.put_source(s, "images/nope.jpg") == s
  end
end
```

- [ ] **Step 2: Run it; expect failure**

Run: `mise exec -- mix test test/image_pipe_demo/fiddle/demo_state_test.exs`
Expected: FAIL (`DemoState` undefined).

- [ ] **Step 3: Implement**

```elixir
# lib/image_pipe_demo/fiddle/demo_state.ex
defmodule ImagePipeDemo.Fiddle.DemoState do
  @moduledoc "Flat demo state for spike 1 (Request + Crop). Crop px derive from the source."

  alias ImagePipeDemo.Fiddle.SampleImages

  defstruct source: "images/dog.jpg",
            crop_enabled: false,
            crop_width_unit: :px,
            crop_width: 0,
            crop_width_percent: 50,
            crop_height_unit: :px,
            crop_height: 0,
            crop_height_percent: 50,
            crop_gravity: "inherit"

  @type unit :: :px | :percent | :full
  @type t :: %__MODULE__{}

  def default, do: reset_crop_pixels_to_source(%__MODULE__{})

  def reset_crop_pixels_to_source(%__MODULE__{source: source} = state) do
    %{state | crop_width: SampleImages.width(source), crop_height: SampleImages.height(source)}
  end

  def put_source(%__MODULE__{} = state, source) do
    if SampleImages.valid?(source) do
      reset_crop_pixels_to_source(%{state | source: source})
    else
      state
    end
  end
end
```

- [ ] **Step 4: Run it; expect pass**

Run: `mise exec -- mix test test/image_pipe_demo/fiddle/demo_state_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe_demo/fiddle/demo_state.ex test/image_pipe_demo/fiddle/demo_state_test.exs
git commit -m "feat(demo): DemoState with source-driven crop defaults"
```

---

## Task 3: ProcessingPath (pure)

Ports the crop encoding from `processing-path.ts` (`optionSegments`, `cropOptionSegment`, `cropDimensionSegment`, `signedPathForState`). **Divergence from Svelte (Decision 5):** use the bare `images/x.jpg` source form, not `local:///images/x.jpg`. Unsigned `_` only.

**Files:**
- Create: `lib/image_pipe_demo/fiddle/processing_path.ex`
- Test: `test/image_pipe_demo/fiddle/processing_path_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/image_pipe_demo/fiddle/processing_path_test.exs
defmodule ImagePipeDemo.Fiddle.ProcessingPathTest do
  use ExUnit.Case, async: true
  alias ImagePipeDemo.Fiddle.{DemoState, ProcessingPath}

  test "no-geometry: crop disabled yields /_/plain/<source>" do
    assert ProcessingPath.build(DemoState.default()) == "/_/plain/images/dog.jpg"
  end

  test "crop in px omits inherit gravity" do
    s = %{DemoState.default() | crop_enabled: true, crop_width: 800, crop_height: 600}
    assert ProcessingPath.build(s) == "/_/c:800:600/plain/images/dog.jpg"
  end

  test "crop in percent encodes value/100" do
    s = %{
      DemoState.default()
      | crop_enabled: true,
        crop_width_unit: :percent,
        crop_width_percent: 50,
        crop_height_unit: :percent,
        crop_height_percent: 25
    }
    assert ProcessingPath.build(s) == "/_/c:0.5:0.25/plain/images/dog.jpg"
  end

  test "crop full encodes 0" do
    s = %{DemoState.default() | crop_enabled: true, crop_width_unit: :full, crop_height_unit: :full}
    assert ProcessingPath.build(s) == "/_/c:0:0/plain/images/dog.jpg"
  end

  test "non-inherit crop gravity is appended" do
    s = %{DemoState.default() | crop_enabled: true, crop_width: 800, crop_height: 600, crop_gravity: "no"}
    assert ProcessingPath.build(s) == "/_/c:800:600:no/plain/images/dog.jpg"
  end

  test "px is clamped to >= 1" do
    s = %{DemoState.default() | crop_enabled: true, crop_width: 0, crop_height: 600}
    assert ProcessingPath.build(s) == "/_/c:1:600/plain/images/dog.jpg"
  end
end
```

- [ ] **Step 2: Run it; expect failure**

Run: `mise exec -- mix test test/image_pipe_demo/fiddle/processing_path_test.exs`
Expected: FAIL (`ProcessingPath` undefined).

- [ ] **Step 3: Implement**

```elixir
# lib/image_pipe_demo/fiddle/processing_path.ex
defmodule ImagePipeDemo.Fiddle.ProcessingPath do
  @moduledoc """
  Pure builder: DemoState -> unsigned imgproxy processing path.
  Spike 1: Request + Crop only, unsigned `_`, bare `images/x.jpg` source form.
  """

  alias ImagePipeDemo.Fiddle.DemoState

  @doc "Full unsigned path: `/_/{opts}/plain/{source}` (or `/_/plain/{source}` with no opts)."
  def build(%DemoState{} = state), do: "/_" <> signed_path(state)

  def signed_path(%DemoState{} = state) do
    opts = state |> option_segments() |> Enum.join("/")
    opts_path = if opts == "", do: "", else: "/" <> opts
    opts_path <> "/plain/" <> state.source
  end

  def option_segments(%DemoState{} = state), do: maybe_crop([], state)

  defp maybe_crop(segments, %DemoState{crop_enabled: false}), do: segments
  defp maybe_crop(segments, %DemoState{} = state), do: segments ++ [crop_segment(state)]

  defp crop_segment(%DemoState{} = state) do
    base = [
      "c",
      crop_dimension(state.crop_width_unit, state.crop_width, state.crop_width_percent),
      crop_dimension(state.crop_height_unit, state.crop_height, state.crop_height_percent)
    ]

    parts = if state.crop_gravity == "inherit", do: base, else: base ++ [state.crop_gravity]
    Enum.join(parts, ":")
  end

  defp crop_dimension(:full, _px, _pct), do: "0"
  defp crop_dimension(:percent, _px, pct), do: percent_string(pct)
  defp crop_dimension(:px, px, _pct), do: Integer.to_string(max(1, px))

  # Mirror JS `String(percent / 100)`: 50 -> "0.5", 25 -> "0.25", 1 -> "0.01".
  defp percent_string(pct), do: Float.to_string(pct / 100)
end
```

- [ ] **Step 4: Run it; expect pass**

Run: `mise exec -- mix test test/image_pipe_demo/fiddle/processing_path_test.exs`
Expected: PASS.

> If `percent_string/1` ever mismatches JS for an odd percent (float repr), switch to an
> integer-based decimal formatter; the example tests above are the contract.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe_demo/fiddle/processing_path.ex test/image_pipe_demo/fiddle/processing_path_test.exs
git commit -m "feat(demo): ProcessingPath builder for Request+Crop (unsigned)"
```

---

## Task 4: Confirm sample images on disk

**Files:** none created. Verifies `demo_new/priv/static/images/` has the two sources.

- [ ] **Step 1: Verify**

Run: `ls priv/static/images/dog.jpg priv/static/images/beach.jpg`
Expected: both paths print (both are already committed). If either is missing, copy from the library: `cp ../priv/static/images/dog.jpg ../priv/static/images/beach.jpg priv/static/images/` (copy named files only — never `cp *`; do not pull in `waterfall.jpg` or `.DS_Store`).

- [ ] **Step 2: Commit (only if files were added)**

```bash
git add priv/static/images/ && git commit -m "chore(demo): ensure dog/beach sample images present"
```

---

## Task 5: Fiddle layout + page skeleton (boots)

Minimal layout + page that renders the `.ip-demo` root and the default parameter path. No tools or preview yet — just prove the route boots and renders state.

**Files:**
- Create: `lib/image_pipe_demo_web/fiddle_layout.ex`
- Create: `lib/image_pipe_demo_web/fiddle_page.ex`

- [ ] **Step 1: Implement the layout**

```elixir
# lib/image_pipe_demo_web/fiddle_layout.ex
defmodule ImagePipeDemoWeb.FiddleLayout do
  use Hologram.Component
  alias Hologram.UI.Runtime

  def template do
    ~HOLO"""
    <!DOCTYPE html>
    <html lang="en" data-theme="dark">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>ImagePipe Fiddle</title>
        <link rel="stylesheet" href="/css/fiddle.css" />
        <Runtime />
      </head>
      <body>
        <slot />
      </body>
    </html>
    """
  end
end
```

- [ ] **Step 2: Implement the page skeleton**

```elixir
# lib/image_pipe_demo_web/fiddle_page.ex
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
```

- [ ] **Step 3: Compile and boot**

Run: `mise exec -- mix compile` → Expected: compiles (only upstream Hologram warnings).
Run (background): `HOLOGRAM_START=1 mise exec -- mix phx.server`
Run: `curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4000/demo`
Expected: `200`. And `curl -s http://localhost:4000/demo | grep -o 'path: /_/plain/images/dog.jpg'` prints the default path. Stop the server.

- [ ] **Step 4: Commit**

```bash
git add lib/image_pipe_demo_web/fiddle_layout.ex lib/image_pipe_demo_web/fiddle_page.ex
git commit -m "feat(demo): Hologram /demo page + layout skeleton"
```

---

## Task 6: Global stylesheet (theme vars + @scope)

Port the styling. `fiddle.css` has two parts: (1) **global** theme variables + resets (outside `@scope`), dark only; (2) all component/layout rules wrapped in `@scope (.ip-demo) { … }`.

**Files:**
- Create: `priv/static/css/fiddle.css`

- [ ] **Step 1: Build `fiddle.css`**

1. **Global section (outside `@scope`):** copy the CSS-variable definitions and resets from `demo/src/styles.css`. Keep only the **dark** values: the `:root` / `[data-theme="dark"]` variable blocks (`styles.css:18–56`) and the resets (`*`, `html`/`body`/`#demo-app` → change `#demo-app` to `.ip-demo`, `button,input,select`, `code`, lines `120–151`). **Omit** the `[data-theme="light"]` and `@media (prefers-color-scheme: light)` blocks (spike is dark-only).
2. **Scoped section:** wrap in `@scope (.ip-demo) { … }`. Copy the layout/component rules from `App.svelte`'s `<style>` (`App.svelte:1378–2152`), plus the per-component styles from `CropDimensionControl.svelte` (`98–207`) and `ToolToggleHeader.svelte` (`32–113`). While copying, apply these rewrites:
   - **Drop every `:global(...)` wrapper.** The `bits-ui` selectors it targeted are replaced by our own markup:
     - Slider: we use a native `<input type="range" class="ip-range">` (Task 9). Replace the `.slider-root/.slider-range/.slider-thumb` rules with `.ip-range` styling (style the native range track + thumb via `input[type=range]` pseudo-elements). Keep the visual size/colors from `CropDimensionControl.svelte:169–206`.
     - Switch: `.switch-root/.switch-thumb` are already plain markup (Task 7) — keep those rules as-is (drop the `:global`).
     - Collapsible/RadioGroup/Accordion `:global` rules in `App.svelte` that target the Request collapsible: our Request section is a plain header button + `{%if}` body (Task 8), so port only the visual rules you actually use and delete the rest.
   - **`class:` directives become static classes** in templates — no CSS change, but the classes (`.is-checked`, `.is-loading`, `.is-open`) must exist; keep their rules.
   - **Keep** `.fiddle-shell`, `.tools-sidebar`, `.tool-stack`, `.tool-section`, `.preview-workspace`, `.preview-command-bar`, `.preview-canvas`, `.image-frame`, `.preview-metadata`, `.preview-spinner`, `.preview-error`, `.tool-toggle-heading`, `.crop-dimension-control`, `.value-row`, `.value-controls`, `.unit-suffix` — these are the class names the components in later tasks use.
   - **Skip** all rules belonging to deferred tools/features (theme toggle, mobile drawer `.mobile-scrim`/`.drawer-topbar`/`.drawer-actions`, and the non-Request/Crop tool bodies). Porting only what spike-1 markup uses keeps the file lean; the rest ports when those tools land.

   > `@scope` contains these styles at the `.ip-demo` boundary but does **not** isolate bare
   > selectors from each other inside it — that's expected for a single page (per spec).

- [ ] **Step 2: Update the stale guideline comment**

Edit `priv/static/css/app.css`: update or remove the "no bare element selectors" comment (lines ~8–11) so it doesn't contradict the `@scope` stylesheet. Replace with a one-liner noting `fiddle.css` uses `@scope (.ip-demo)` for the fiddle page.

- [ ] **Step 3: Verify served + styled**

`css` is already in `ImagePipeDemoWeb.static_paths/0`. Boot the server and:
Run: `curl -s -o /dev/null -w "%{http_code} %{content_type}\n" http://localhost:4000/css/fiddle.css`
Expected: `200 text/css`. Load `http://localhost:4000/demo` in a browser — the `.ip-demo` root should pick up the dark background/fonts. Stop the server.

- [ ] **Step 4: Commit**

```bash
git add priv/static/css/fiddle.css priv/static/css/app.css
git commit -m "feat(demo): scoped fiddle stylesheet (dark, @scope ip-demo)"
```

---

## Task 7: ToolToggleHeader component

Ports `ToolToggleHeader.svelte` — a button with title/summary and an on/off switch, firing one action at the page. Stateless; the `checked` value and the action name come from props.

**Files:**
- Create: `lib/image_pipe_demo_web/components/fiddle/tool_toggle_header.ex`

- [ ] **Step 1: Implement**

```elixir
# lib/image_pipe_demo_web/components/fiddle/tool_toggle_header.ex
defmodule ImagePipeDemoWeb.Components.Fiddle.ToolToggleHeader do
  use Hologram.Component

  prop :title, :string
  prop :summary, :string
  prop :checked, :boolean
  prop :action, :atom

  def template do
    ~HOLO"""
    <button
      class={"tool-toggle-heading #{if @checked, do: "is-checked", else: ""}"}
      type="button"
      $click={action: @action, target: "page"}
    >
      <span>
        <h2>{@title}</h2>
        <p>{@summary}</p>
      </span>
      <span class="switch-root" aria-hidden="true">
        <span class="switch-thumb"></span>
      </span>
    </button>
    """
  end
end
```

> The page action named by `@action` flips the corresponding `crop_enabled` boolean (Task 9).
> Verify the conditional-class interpolation form against the Template Syntax doc; an
> equivalent is `class={if @checked, do: "tool-toggle-heading is-checked", else: "tool-toggle-heading"}`.

- [ ] **Step 2: Verify it compiles**

Run: `mise exec -- mix compile`
Expected: compiles. (Rendered use is exercised in Task 9.)

- [ ] **Step 3: Commit**

```bash
git add lib/image_pipe_demo_web/components/fiddle/tool_toggle_header.ex
git commit -m "feat(demo): ToolToggleHeader component"
```

---

## Task 8: Request tool + page state wiring

The Request tool is a collapsible section with a source `<select>`. Add the `request_open` state, the source action, and render the tool inside the sidebar.

**Files:**
- Create: `lib/image_pipe_demo_web/components/fiddle/request_tool.ex`
- Modify: `lib/image_pipe_demo_web/fiddle_page.ex`

- [ ] **Step 1: Implement the Request tool**

```elixir
# lib/image_pipe_demo_web/components/fiddle/request_tool.ex
defmodule ImagePipeDemoWeb.Components.Fiddle.RequestTool do
  use Hologram.Component
  alias ImagePipeDemo.Fiddle.SampleImages

  prop :source, :string
  prop :open, :boolean

  def template do
    ~HOLO"""
    <section class="tool-section">
      <button type="button" class="tool-toggle-heading" $click={action: :toggle_request, target: "page"}>
        <span><h2>Request</h2><p>{@source}</p></span>
      </button>
      {%if @open}
        <label class="value-row">
          <span>Source image</span>
          <select $change={action: :update_source, target: "page"}>
            {%for image <- SampleImages.all()}
              <option value={image.path} selected={image.path == @source}>{image.path}</option>
            {/for}
          </select>
        </label>
      {/if}
    </section>
    """
  end
end
```

- [ ] **Step 2: Wire page state + actions**

Replace `fiddle_page.ex` `init/3` and add actions + the `recompute/2` helper (debounce + path recompute). The `:commit` action is added in Task 12; for now `recompute/2` just bumps the gen and recomputes the path.

```elixir
# lib/image_pipe_demo_web/fiddle_page.ex  (init/3 + actions)
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

def action(:update_source, %{event: event}, component) do
  source = event["value"]
  recompute(component, DemoState.put_source(component.state.demo, source))
end

defp recompute(component, %DemoState{} = demo) do
  gen = component.state.preview_gen + 1

  component
  |> put_state(demo: demo, path: ProcessingPath.build(demo), preview_gen: gen)
end
```

> The exact key for the selected value in `params.event` (here `event["value"]`) must be
> confirmed against the Hologram Forms doc for a `$change` on `<select>`. If the change event
> delivers the value under a different key, adjust `update_source` accordingly.

- [ ] **Step 3: Render the tool in the page template**

Update the page `template/0` to the shell + sidebar with the Request tool:

```elixir
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
```

Add `alias ImagePipeDemoWeb.Components.Fiddle.RequestTool` near the top of the page module.

- [ ] **Step 4: Verify in browser**

Boot the server, open `http://localhost:4000/demo`. Changing the source `<select>` updates the `<code>` parameter path from `…/plain/images/dog.jpg` to `…/plain/images/beach.jpg`. Collapsing/expanding Request works. Stop the server.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe_demo_web/components/fiddle/request_tool.ex lib/image_pipe_demo_web/fiddle_page.ex
git commit -m "feat(demo): Request tool (source picker) + page state wiring"
```

---

## Task 9: Crop tool (dimension control + gravity)

Crop is a toggle section: a `ToolToggleHeader` enabling it, two `CropDimensionControl`s (number + unit select + range slider), and a gravity `<select>`.

**Files:**
- Create: `lib/image_pipe_demo_web/components/fiddle/crop_dimension_control.ex`
- Create: `lib/image_pipe_demo_web/components/fiddle/crop_tool.ex`
- Modify: `lib/image_pipe_demo_web/fiddle_page.ex`

- [ ] **Step 1: Implement the dimension control**

```elixir
# lib/image_pipe_demo_web/components/fiddle/crop_dimension_control.ex
defmodule ImagePipeDemoWeb.Components.Fiddle.CropDimensionControl do
  use Hologram.Component

  prop :label, :string
  prop :unit, :atom            # :px | :percent | :full
  prop :pixels, :integer
  prop :percent, :integer
  prop :max_pixels, :integer
  prop :unit_action, :atom     # page action: set this axis' unit
  prop :value_action, :atom    # page action: set this axis' active numeric value

  def template do
    ~HOLO"""
    <div class="crop-dimension-control">
      <label class="value-row">
        <span>{@label}</span>
        <span class="value-controls">
          {%if @unit != :full}
            <input
              type="number"
              min={if @unit == :percent, do: 1, else: 1}
              max={if @unit == :percent, do: 99, else: @max_pixels}
              step="1"
              value={if @unit == :percent, do: @percent, else: @pixels}
              $change={action: @value_action, target: "page"}
            />
            <span class="unit-suffix">{if @unit == :percent, do: "%", else: "px"}</span>
          {/if}
          <select $change={action: @unit_action, target: "page"}>
            <option value="px" selected={@unit == :px}>px</option>
            <option value="percent" selected={@unit == :percent}>%</option>
            <option value="full" selected={@unit == :full}>full</option>
          </select>
        </span>
      </label>
      {%if @unit != :full}
        <input
          type="range"
          class="ip-range"
          min={if @unit == :percent, do: 1, else: 1}
          max={if @unit == :percent, do: 99, else: @max_pixels}
          step="1"
          value={if @unit == :percent, do: @percent, else: @pixels}
          $change={action: @value_action, target: "page"}
        />
      {/if}
    </div>
    """
  end
end
```

- [ ] **Step 2: Implement the crop tool**

```elixir
# lib/image_pipe_demo_web/components/fiddle/crop_tool.ex
defmodule ImagePipeDemoWeb.Components.Fiddle.CropTool do
  use Hologram.Component
  alias ImagePipeDemo.Fiddle.{DemoState, SampleImages}
  alias ImagePipeDemoWeb.Components.Fiddle.{ToolToggleHeader, CropDimensionControl}

  prop :demo, :map   # %DemoState{}

  @gravities ~w(inherit ce no so ea we noea nowe soea sowe)

  def template do
    ~HOLO"""
    <section class="tool-section">
      <ToolToggleHeader
        title="Crop"
        summary={if @demo.crop_enabled, do: "On", else: "Off"}
        checked={@demo.crop_enabled}
        action={:toggle_crop}
      />
      {%if @demo.crop_enabled}
        <CropDimensionControl
          label="Width"
          unit={@demo.crop_width_unit}
          pixels={@demo.crop_width}
          percent={@demo.crop_width_percent}
          max_pixels={SampleImages.width(@demo.source)}
          unit_action={:set_crop_width_unit}
          value_action={:set_crop_width}
        />
        <CropDimensionControl
          label="Height"
          unit={@demo.crop_height_unit}
          pixels={@demo.crop_height}
          percent={@demo.crop_height_percent}
          max_pixels={SampleImages.height(@demo.source)}
          unit_action={:set_crop_height_unit}
          value_action={:set_crop_height}
        />
        <label class="value-row">
          <span>Gravity</span>
          <select $change={action: :set_crop_gravity, target: "page"}>
            {%for g <- unquote(@gravities)}
              <option value={g} selected={g == @demo.crop_gravity}>{g}</option>
            {/for}
          </select>
        </label>
      {/if}
    </section>
    """
  end
end
```

> If `unquote(@gravities)` (a module attribute) isn't accepted inside `~HOLO`, inline the list
> literal in the `{%for}` instead. Confirm the `{%for}` + module-attr interaction during impl.

- [ ] **Step 3: Add crop actions to the page**

Add these actions to `fiddle_page.ex`. Each updates the `%DemoState{}` and calls `recompute/2`. Unit values arrive as strings from the `<select>` and map to atoms.

```elixir
def action(:toggle_crop, _params, component) do
  demo = %{component.state.demo | crop_enabled: not component.state.demo.crop_enabled}
  recompute(component, demo)
end

def action(:set_crop_gravity, %{event: event}, component) do
  recompute(component, %{component.state.demo | crop_gravity: event["value"]})
end

def action(:set_crop_width_unit, %{event: event}, component) do
  recompute(component, %{component.state.demo | crop_width_unit: parse_unit(event["value"])})
end

def action(:set_crop_height_unit, %{event: event}, component) do
  recompute(component, %{component.state.demo | crop_height_unit: parse_unit(event["value"])})
end

def action(:set_crop_width, %{event: event}, component) do
  recompute(component, put_axis_value(component.state.demo, :width, event["value"]))
end

def action(:set_crop_height, %{event: event}, component) do
  recompute(component, put_axis_value(component.state.demo, :height, event["value"]))
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

defp put_axis_value(demo, :width, n, :percent), do: %{demo | crop_width_percent: clamp(n, 1, 99)}
defp put_axis_value(demo, :width, n, _px), do: %{demo | crop_width: max(1, n)}
defp put_axis_value(demo, :height, n, :percent), do: %{demo | crop_height_percent: clamp(n, 1, 99)}
defp put_axis_value(demo, :height, n, _px), do: %{demo | crop_height: max(1, n)}

defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)
```

- [ ] **Step 4: Render the crop tool**

Add `alias ImagePipeDemoWeb.Components.Fiddle.CropTool` and place `<CropTool demo={@demo} />` after `<RequestTool .../>` in the `.tool-stack`.

- [ ] **Step 5: Verify in browser**

Boot, open `/demo`. Toggle Crop on → the `<code>` path gains `c:5011:7516`. Switch Width unit to `%` → `c:0.5:…`; to `full` → `c:0:…`. Drag the slider → the path's width updates live. Pick gravity `no` → trailing `:no`. Stop the server.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe_demo_web/components/fiddle/crop_dimension_control.ex lib/image_pipe_demo_web/components/fiddle/crop_tool.ex lib/image_pipe_demo_web/fiddle_page.ex
git commit -m "feat(demo): Crop tool (dimensions + gravity) wired to page state"
```

---

## Task 10: Command bar (Copy URL / Open)

Live parameter code + two buttons. "Copy URL" copies the live `/img` image URL via a clipboard JS facade; "Open" links to it. No deep-link page state.

**Files:**
- Create: `lib/image_pipe_demo_web/components/fiddle/command_bar.ex`
- Create: `lib/image_pipe_demo_web/fiddle/clipboard.mjs`
- Modify: `lib/image_pipe_demo_web/fiddle_page.ex`

- [ ] **Step 1: Clipboard facade**

```js
// lib/image_pipe_demo_web/fiddle/clipboard.mjs
export async function copy(text) {
  try { await navigator.clipboard.writeText(text); return { ok: true }; }
  catch (e) { return { ok: false, message: String((e && e.message) || e) }; }
}
```

- [ ] **Step 2: Command bar component**

```elixir
# lib/image_pipe_demo_web/components/fiddle/command_bar.ex
defmodule ImagePipeDemoWeb.Components.Fiddle.CommandBar do
  use Hologram.Component

  prop :path, :string        # /_/.../plain/...
  prop :image_url, :string   # /img/_/.../plain/...

  def template do
    ~HOLO"""
    <div class="preview-command-bar">
      <code>{@path}</code>
      <span>
        <button type="button" $click={action: :copy_url, target: "page"}>Copy URL</button>
        <a href={@image_url} target="_blank" rel="noopener">Open</a>
      </span>
    </div>
    """
  end
end
```

- [ ] **Step 3: Page action + render**

In `fiddle_page.ex` add `use Hologram.JS` and the import + action; compute `image_url` in the template as `"/img" <> @path`.

```elixir
use Hologram.JS
js_import :copy, from: "./fiddle/clipboard.mjs"

def action(:copy_url, _params, component) do
  _ = JS.call(:copy, ["/img" <> component.state.path]) |> Task.await()
  component
end
```

Replace the inline `<div class="preview-command-bar">…</div>` in the page template with
`<CommandBar path={@path} image_url={"/img" <> @path} />` (add the alias).

> Confirm the `js_import` relative path resolves from the page module file to
> `lib/image_pipe_demo_web/fiddle/clipboard.mjs`. If Hologram resolves interop relative to a
> different root, colocate the `.mjs` accordingly.

- [ ] **Step 4: Verify**

Boot, open `/demo`. "Copy URL" puts `/img/_/…/plain/images/dog.jpg` on the clipboard; "Open" opens that image in a new tab (it should render the processed image). Stop the server.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe_demo_web/components/fiddle/command_bar.ex lib/image_pipe_demo_web/fiddle/clipboard.mjs lib/image_pipe_demo_web/fiddle_page.ex
git commit -m "feat(demo): command bar with Copy URL / Open (image url)"
```

---

## Task 11: Preview fetch facade (preview.mjs)

The single JS-interop facade that fetches the image and returns a **tagged map** (always resolves; never rejects — a rejected Task is not observable in an Elixir action). Single-flight: aborts the prior request; revokes the prior object URL.

**Files:**
- Create: `lib/image_pipe_demo_web/fiddle/preview.mjs`

- [ ] **Step 1: Implement**

```js
// lib/image_pipe_demo_web/fiddle/preview.mjs
let currentController = null;
let currentObjectUrl = null;

export async function load(url) {
  if (currentController) currentController.abort();
  const controller = new AbortController();
  currentController = controller;
  const timeout = setTimeout(() => controller.abort(), 15000);

  try {
    const response = await fetch(url, { signal: controller.signal });
    if (!response.ok) {
      const body = await response.text().catch(() => "");
      return { ok: false, kind: "http", status: response.status, statusText: response.statusText, body };
    }
    const blob = await response.blob();
    const objectUrl = URL.createObjectURL(blob);
    const size = await naturalSize(objectUrl);
    if (currentObjectUrl) URL.revokeObjectURL(currentObjectUrl);
    currentObjectUrl = objectUrl;
    return {
      ok: true,
      objectUrl,
      width: size.width,
      height: size.height,
      bytes: blob.size,
      contentType: blob.type || response.headers.get("content-type") || "",
    };
  } catch (error) {
    if (error && error.name === "AbortError") return { ok: false, kind: "abort" };
    return { ok: false, kind: "error", message: String((error && error.message) || error) };
  } finally {
    clearTimeout(timeout);
    if (currentController === controller) currentController = null;
  }
}

function naturalSize(objectUrl) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.onload = () => resolve({ width: img.naturalWidth, height: img.naturalHeight });
    img.onerror = () => reject(new Error("decode failed"));
    img.src = objectUrl;
  });
}

export function teardown() {
  if (currentController) currentController.abort();
  if (currentObjectUrl) { URL.revokeObjectURL(currentObjectUrl); currentObjectUrl = null; }
}
```

- [ ] **Step 2: Commit**

```bash
git add lib/image_pipe_demo_web/fiddle/preview.mjs
git commit -m "feat(demo): preview fetch facade (tagged-map, single-flight)"
```

---

## Task 12: Preview canvas + :commit orchestration (debounced live preview)

Wire the debounced `:commit` action: `recompute/2` schedules one delayed `:commit` carrying the current gen; `:commit` (client) awaits `preview.mjs` and pattern-matches the resolved map. `init/3` chains a `:commit` to load on mount.

**Files:**
- Create: `lib/image_pipe_demo_web/components/fiddle/preview_canvas.ex`
- Modify: `lib/image_pipe_demo_web/fiddle_page.ex`

- [ ] **Step 1: Preview canvas component**

```elixir
# lib/image_pipe_demo_web/components/fiddle/preview_canvas.ex
defmodule ImagePipeDemoWeb.Components.Fiddle.PreviewCanvas do
  use Hologram.Component

  prop :object_url, :string
  prop :loading, :boolean
  prop :error, :string
  prop :size_label, :string
  prop :output_label, :string

  def template do
    ~HOLO"""
    <div class="preview-canvas">
      <div class="preview-metadata">
        <span>{@size_label}</span>
        <span>{@output_label}</span>
      </div>
      <div class="image-frame">
        {%if @object_url}
          <figure>
            <img class={"#{if @loading, do: "is-loading", else: ""}"} src={@object_url} />
          </figure>
        {/if}
      </div>
      {%if @error}
        <div class="preview-error">{@error}</div>
      {/if}
      {%if @loading}
        <div class="preview-spinner"></div>
      {/if}
    </div>
    """
  end
end
```

- [ ] **Step 2: Extend page state + init + :commit**

Add the preview state keys to `init/3`, chain a mount `:commit`, update `recompute/2` to schedule the debounced `:commit`, and add the `:commit` action + result handling. Add `js_import :load, from: "./fiddle/preview.mjs"` (the page already has `use Hologram.JS` from Task 10).

```elixir
# init/3 — add preview keys and mount commit
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

# recompute/2 — now schedules the debounced commit
defp recompute(component, %DemoState{} = demo) do
  gen = component.state.preview_gen + 1

  component
  |> put_state(demo: demo, path: ProcessingPath.build(demo), preview_gen: gen)
  |> put_action(name: :commit, delay: 150, params: %{gen: gen})
end

# :commit — debounce guard, then await the facade (always resolves)
def action(:commit, %{gen: gen}, component) do
  if gen != component.state.preview_gen do
    component
  else
    component = put_state(component, :preview_loading, true)
    result = JS.call(:load, ["/img" <> component.state.path]) |> Task.await()
    apply_preview_result(component, result)
  end
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
```

> Confirm map keys are strings when a JS object crosses to Elixir (the spec assumes
> `r["objectUrl"]` etc.). If interop delivers atom keys, adjust the matches.

- [ ] **Step 3: Render the canvas with metadata labels**

Compute simple labels inline and render `<PreviewCanvas .../>` in place of the empty `<div class="preview-canvas">`:

```elixir
# add alias ImagePipeDemoWeb.Components.Fiddle.PreviewCanvas
# in template, replace the preview-canvas div with:
<PreviewCanvas
  object_url={@preview_object_url}
  loading={@preview_loading}
  error={@preview_error}
  size_label={size_label(@preview_loading, @preview_width, @preview_height, @preview_bytes)}
  output_label={@preview_content_type || "auto"}
/>
```

```elixir
# helpers on the page module
defp size_label(true, _w, _h, _b), do: "Loading"
defp size_label(_loading, nil, _h, _b), do: ""
defp size_label(_loading, w, h, nil), do: "#{w} × #{h}"
defp size_label(_loading, w, h, bytes), do: "#{w} × #{h} (#{max(1, div(bytes, 1024))} kB)"
```

- [ ] **Step 4: Verify live preview**

Boot, open `/demo`. On load the dog image renders with a `W × H (… kB)` label. Toggle Crop, drag the Width slider quickly — the preview updates smoothly (debounced; no flicker storms), the spinner shows during loads, and stale drags don't land late. Switch source to beach — image + dimensions update. Stop the server.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe_demo_web/components/fiddle/preview_canvas.ex lib/image_pipe_demo_web/fiddle_page.ex
git commit -m "feat(demo): live debounced preview via JS fetch facade"
```

---

## Task 13: Wire-level plug tests (crop + no-geometry)

Two request-boundary tests through the endpoint/router to the ImagePipe plug, decoding the response to assert dimensions. Reuses the harness pattern.

**Files:**
- Create: `test/image_pipe_demo_web/fiddle_image_test.exs`

- [ ] **Step 1: Write the tests**

```elixir
# test/image_pipe_demo_web/fiddle_image_test.exs
defmodule ImagePipeDemoWeb.FiddleImageTest do
  use ImagePipeDemoWeb.ConnCase, async: true

  defp dims(body) do
    {:ok, img} = Image.from_binary(body)
    {Image.width(img), Image.height(img)}
  end

  test "no-geometry request returns the source re-encoded", %{conn: conn} do
    conn = get(conn, "/img/_/plain/images/dog.jpg")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/"
    {w, h} = dims(conn.resp_body)
    assert w == 5011 and h == 7516
  end

  test "crop request returns the cropped dimensions", %{conn: conn} do
    conn = get(conn, "/img/_/c:800:600/plain/images/dog.jpg")
    assert conn.status == 200
    assert {800, 600} == dims(conn.resp_body)
  end
end
```

- [ ] **Step 2: Run; expect pass**

Run: `mise exec -- mix test test/image_pipe_demo_web/fiddle_image_test.exs`
Expected: PASS. (`Image` is available transitively via `image_pipe`. If `ConnCase` lacks `get_resp_header`, import `Plug.Conn` in the test.)

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe_demo_web/fiddle_image_test.exs
git commit -m "test(demo): wire-level crop + no-geometry image requests"
```

---

## Task 14: Full suite + browser verification

**Files:** none.

- [ ] **Step 1: Full Elixir suite + compile gate**

Run: `mise exec -- mix compile` → Expected: no errors (only upstream Hologram warnings).
Run: `mise exec -- mix test` → Expected: all pass (the new fiddle tests + the generated error tests).
Run: `mise exec -- mix format`.

- [ ] **Step 2: Browser screenshot**

Boot `HOLOGRAM_START=1 mise exec -- mix phx.server`, open `http://localhost:4000/demo`, and capture a screenshot showing: the dark two-column shell, Request + Crop tools in the sidebar, the live parameter code in the command bar, and a cropped preview with its dimension label. Confirm no errors in the browser console. Stop the server.

- [ ] **Step 3: Commit any format-only changes**

```bash
git add -A && git commit -m "chore(demo): format + final spike verification" || true
```

---

## Self-review (run by the plan author)

**Spec coverage:** shell (Tasks 5,6,8,9,10,12) ✓; Request tool (8) ✓; Crop tool incl. px/%/full + gravity + source-derived defaults (2,3,9) ✓; preview fetch + metadata facade (11,12) ✓; debounce + gen guard + single chained `:commit` (12) ✓; `@scope` dark CSS + stale-comment fix (6) ✓; bare source form + crop encoding verified (3,13) ✓; no-geometry form + test (3,13) ✓; signing/deep-link/theme-toggle/drawer correctly **absent** (deferred) ✓.

**Placeholder scan:** all code steps contain full code; CSS task references exact source ranges + concrete transform rules (a port instruction, not a TODO). The `> confirm …` notes flag genuine Hologram-syntax/interop details the executor must validate against the docs — they are verification reminders, not missing content.

**Type/name consistency:** state keys (`demo`, `path`, `preview_gen`, `preview_loading`, `preview_error`, `preview_object_url`, `preview_width/height/bytes/content_type`, `request_open`) are consistent across `init/3`, actions, and templates. Action names (`toggle_request`, `update_source`, `toggle_crop`, `set_crop_width/height`, `set_crop_width_unit/height_unit`, `set_crop_gravity`, `copy_url`, `commit`) match between component `$`-bindings and page `action/3` clauses. `DemoState`/`SampleImages`/`ProcessingPath` signatures match their call sites. Crop units are atoms (`:px/:percent/:full`) end-to-end; gravity is a string.

**Known executor-verification points (by design, not gaps):** (1) `$change` event value key in `params.event` for `<select>`/`number`/`range`; (2) JS-interop relative-path resolution for the colocated `.mjs` files; (3) string-vs-atom keys on a JS object crossing to Elixir; (4) conditional-class interpolation form in `~HOLO`; (5) module-attr list inside `{%for}`. Each has an inline note and a fallback.
