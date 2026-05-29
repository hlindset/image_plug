# Hologram demo spike — app shell + Request & Crop tools

- **Date:** 2026-05-29
- **Status:** Approved (design), pending implementation plan
- **Location of work:** `demo_new/` (the Phoenix + Hologram demo harness). The existing
  Svelte app under `demo/` is the porting reference only and is not modified.

## Context & goal

The demo (currently a Svelte SPA in `demo/`) is a dev/test fiddle for the ImagePipe plug:
a control panel that builds an imgproxy-style processing URL and previews the transformed
image. We are porting it to Hologram (the isomorphic Elixir framework already wired into
`demo_new/`).

This is an **initial spike**, not the full port. It builds the complete app shell and the
hard cross-cutting infrastructure (deep-linkable URL state, real image preview with
metadata, HMAC signing, theming, responsive drawer, scoped CSS) but restricts the transform
tools to just **Request** and **Crop**. The remaining ~11 tools (Resize, Gravity, Effects,
Padding, Background, Format, Quality, etc.) are deferred; the structure is designed so adding
them later is mechanical.

The Svelte app's reactive model leans on browser-native patterns that do not map 1:1 to
Hologram: a flat ~60-field `DemoState`, a derived imgproxy path, live `history.replaceState`
URL sync, and a fetch→blob→objectURL preview that reads byte size and decoded dimensions.
Hologram keeps state in the client component, but navigation is a full page load, its router
captures only single non-slash route segments, and live URL rewriting / blob fetching both
require JS interop. The decisions below resolve that mismatch.

## Decisions

1. **State + URL — deep-link via a single dynamic route segment.** `route "/demo/:state"`
   with `param :state, :string`. The full processing path — including the leading signature
   segment (`_` for unsigned, or the HMAC for signed) — is serialized into one URL-safe token
   (base64url; `A–Z a–z 0–9 - _`, no slashes). `init/3` decodes it on load. Live edits rewrite
   the address bar via `history.replaceState` (JS interop). The same Elixir parser handles both
   initial load and round-trip. No splat route required.
   **Signature round-trip:** the signature *segment* is encoded, but the raw key/salt are
   **not** placed in the shareable URL. On load, an `_`/`unsafe` segment selects unsigned mode;
   any other segment selects signed mode with key/salt defaulted to the plug's configured
   values. Because signed mode already defaults to those values, default-key signed links
   round-trip faithfully; reproducing a link signed with a *custom* key/salt is a known spike
   limitation (acceptable — the demo plug only validates its configured key anyway).
2. **Preview — fetch + metadata via JS interop.** A JS facade fetches the image as a blob,
   creates an object URL, reads natural dimensions, and returns
   `{objectUrl, width, height, bytes, contentType}` to an Elixir action. Reproduces today's
   size · format · dimensions overlay, loading spinner, and error box.
3. **Signing — included, computed client-side via JS interop.** A JS facade calls Web Crypto
   `subtle.sign` (HMAC-SHA256), mirroring the Svelte approach; no server round-trip. Signed
   mode defaults its key/salt to the demo plug's configured values (`keys: ["736563726574"]`,
   `salts: ["68656c6c6f"]`) so signed previews actually validate against the mounted plug.
4. **Shell fidelity — full, including theme + responsive.** Two-column desktop layout,
   command bar with live parameter code, checkerboard preview canvas, sidebar tool stack,
   light/dark/system theme toggle (localStorage via JS interop, `data-theme` on root), and
   the mobile drawer + scrim.
5. **State architecture — centralized page state** (see Architecture).
6. **CSS — root class + native `@scope`** (see CSS strategy).

## Scope

**In:** app shell (sidebar tool-stack, command bar, checkerboard preview, mobile drawer +
scrim), theme toggle, Request tool, Crop tool, real preview with metadata, unsigned + signed
URLs, deep-linkable state.

**Out (deferred, structured to be mechanical to add):** Resize, Gravity, Scale options,
Orientation, Aspect canvas, Padding, Background, Effects, Format, Quality tools.

## Architecture & state model

**Centralized page state.** A single page, `ImagePipeDemoWeb.FiddlePage`, owns the entire
flat demo-state map (the imgproxy `DemoState`, ported field-for-field). Tool sections are
**stateless presentational components** that render from props and fire actions at
`target: "page"`. The page recomputes the derived processing path on every change.

Rationale: the processing path is a pure function of the *whole* state and must recompute on
any field change. Hologram makes "parent reads child state" awkward (no clean upward
aggregation), so distributing state across stateful tool components would require constant
context plumbing. Centralized state mirrors the Svelte single-`DemoState` model and keeps the
path-builder a pure function; tool components stay dumb and reusable.

Rejected alternative: per-tool stateful components aggregated via context.

## Component tree & file layout (under `demo_new/`)

```
lib/image_pipe_demo_web/
  fiddle_page.ex              # route "/demo/:state"; owns DemoState, actions, preview orchestration
  fiddle_layout.ex           # <html data-theme>, <Hologram.UI.Runtime>, global css link, <slot/>
  components/fiddle/
    tool_section.ex           # .tool-section wrapper + header (toggle/collapsible)
    tool_toggle_header.ex     # title/summary + switch (ports ToolToggleHeader.svelte)
    request_tool.ex           # source select, signature mode/key/salt
    crop_tool.ex              # width/height dual-unit + gravity
    crop_dimension_control.ex # px/%/full unit + number + slider (ports CropDimensionControl.svelte)
    preview_canvas.ex         # checkerboard, <img>, metadata overlay, spinner, error
    command_bar.ex            # menu btn, live parameter code, theme toggle, actions
  fiddle/
    demo_state.ex             # DemoState struct + defaults
    processing_path.ex        # state -> imgproxy path (pure); ports processing-path.ts
    demo_path.ex              # base64url encode/decode of the canonical path (deep-link)
    sample_images.ex          # source image list
priv/static/
  css/fiddle.css             # ported global stylesheet (wrapped in @scope); served via Plug.Static
  images/*.jpg               # sample images copied from the library's priv/static/images
assets/js/fiddle/            # JS interop facades:
  preview.mjs                #   fetch image -> {objectUrl,width,height,bytes,contentType}
  sign.mjs                   #   Web Crypto HMAC-SHA256 -> base64url signature
  history.mjs                #   history.replaceState(token)
  theme.mjs                  #   read/write localStorage, set data-theme
```

`processing_path.ex` and `demo_path.ex` are plain pure modules — unit-testable with ExUnit,
no browser required. `css/fiddle.css` is added to the demo's `static_paths/0` (already done
for `css`) and linked from the layout as a plain `<link>` (no esbuild/Tailwind).

## Data flow

```
control $change → action on "page" → put_state(field)
   → recompute path = ProcessingPath.build(state)        (pure)
   → put_state(:path); bump :gen counter
   → put_action(:refresh_preview, delay: 150, gen: gen)   # debounce
   → put_action(:sync_url,        delay: 150, gen: gen)   # debounce

:refresh_preview (client/JS interop): if gen == current → call preview.mjs fetch facade
:sync_url        (client/JS interop): if gen == current → history.replaceState(base64url(processing path, incl. signature segment))
```

- **Debounce** = `delay:` plus a generation counter: a stale scheduled action no-ops when a
  newer change has bumped `:gen`. (Hologram has no native debounce/cancel; this also reuses
  the Svelte race-guard idea, which additionally guards stale fetch responses.)
- **Initial load:** `init/3` (server) decodes `:state` (base64url → canonical path →
  `DemoState` via the same parser). On client mount, a chained `put_action(:refresh_preview)`
  loads the first image.

## Tools & path encoding

Full preview URL: `/img` (the mounted plug prefix) + `/{sig}/{opts}/plain/{source}`.

**Request tool:** source `<select>` (from `SampleImages`); signature mode `<select>`
(unsigned / signed); when signed → key + salt text inputs (default to the plug's configured
values); a signing-error line. Unsigned signature segment = `_`.

**Crop tool:** width + height via `CropDimensionControl` (unit px / % / full + number input +
slider); gravity `<select>` (`inherit`, `ce`, `no`, `so`, `ea`, `we`, `noea`, `nowe`, `soea`,
`sowe`). Crop encoding: `c:{w}:{h}[:{gravity}]` where `full → 0`, `percent → 0.x`,
`px → integer`; the gravity arg is omitted when `inherit`.

Source path form: the proven `images/<name>` form is confirmed working against the demo plug;
during implementation, confirm whether to keep the Svelte `local:///images/<name>` scheme or
the bare form (both are documented as equivalent by the imgproxy parser).

## Signing (client JS interop)

`assets/js/fiddle/sign.mjs` exposes an async HMAC-SHA256 via Web Crypto `subtle.sign`,
returning the base64url signature. A client action awaits it (Promise → Task) and
`put_state(:signature)`. Faithful to the Svelte approach; preview stays client-driven.

## Preview (JS interop fetch facade)

`assets/js/fiddle/preview.mjs`: `fetch(url)` with `AbortController` → blob → `createObjectURL`
→ load into an `Image` for natural width/height → returns
`{objectUrl, width, height, bytes, contentType}` to an Elixir action, which `put_state`s the
metadata and clears loading. Race-guarded by the generation counter; failures set
`previewError`. Matches the existing overlay (size · format · dimensions) + spinner + error.

## CSS strategy, theme, responsive

**Root class + native `@scope`.** The page root carries `class="ip-demo"`; the ported
stylesheet wraps its rules in `@scope (.ip-demo) { … }`. This is the closest proxy to Svelte's
scoped CSS: it localizes the demo's styles so they cannot leak into Hologram's runtime DOM or
future pages, and it lets us keep clean — even bare-element — selectors safely inside the
scope, making the port of the existing component `<style>` blocks near-mechanical. Theme stays
as the existing global `:root` / `[data-theme]` CSS-variable system.

Caveat: `@scope` requires modern browsers (Chrome 118+, Safari 17.4+, Firefox 128+) —
acceptable for a dev/test harness. Rejected alternative: flat BEM-prefixed classes (universal
support, but verbose and loses bare-element safety).

**Theme:** `data-theme` on the layout root, driven by page state, persisted to `localStorage`
via `theme.mjs`, hydrated on mount. **Responsive:** the mobile drawer + scrim are pure CSS
plus a `drawer_open` state field toggled by the menu and scrim buttons.

## Testing

- ExUnit unit tests for `ProcessingPath.build/1` — Request and Crop encodings, including the
  px / % / full unit variants and gravity inclusion/omission.
- ExUnit round-trip test for `DemoPath` — state → base64url token → state.
- One wire-level test: `GET /img/_/c:…/plain/images/…` returns `200 image/jpeg` with the
  expected decoded output dimensions (reuses the harness's request-boundary test pattern).
- JS-interop facades (sign / preview / theme) verified manually in-browser during the spike
  (screenshot).

## Risks / things the spike validates

- Async JS interop (Promise → Task) for Web Crypto and `fetch` behaving as documented.
- `delay:`-based debounce + generation guard feeling smooth under slider drags.
- `@scope` porting fidelity versus Svelte's per-component scoped styles.
- The single-segment base64url route round-tripping cleanly through `init/3`.

## Out of scope / future

- The remaining transform tools (added incrementally on the same shell + path-builder).
- Per-component `@scope` isolation (the spike uses one root-level scope).
- Server-side signing, and signing with arbitrary keys that the plug does not trust.
- Any change to the library or the existing Svelte `demo/`.
