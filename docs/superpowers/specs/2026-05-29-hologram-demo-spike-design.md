# Hologram demo spike — app shell + Request & Crop tools

- **Date:** 2026-05-29
- **Status:** Approved (design, reviewed), pending implementation plan
- **Location of work:** `demo_new/` (the Phoenix + Hologram demo harness). The existing
  Svelte app under `demo/` is the porting reference only and is not modified.

> This spec was revised after a four-reviewer pass (Hologram-correctness, architecture/
> data-flow, CSS/theming/responsive, scope/path-correctness). The reviewers verified claims
> against the Hologram source and by running the real ImagePipe parser/plug end-to-end. The
> scope was **trimmed to a de-risking core**; deferred features and the correctness caveats
> that apply when they land are recorded in "Spike 2 backlog".

## Context & goal

The demo (currently a Svelte SPA in `demo/`) is a dev/test fiddle for the ImagePipe plug: a
control panel that builds an imgproxy-style processing URL and previews the transformed image.
We are porting it to Hologram (the isomorphic Elixir framework already wired into `demo_new/`).

This is **spike #1**, deliberately small. It validates the genuine unknowns of the port with
the smallest surface that exercises them, and restricts the transform tools to **Request**
(source picker) and **Crop**. The remaining ~11 tools and the deferred features (below) are
spike 2+.

**The unknowns this spike de-risks:**
1. Async JS interop (Promise → Elixir Task) for a real `fetch`-based preview with metadata.
2. `@scope`-based CSS as a stand-in for Svelte's per-component scoped styles.
3. Reimplementing the Svelte interactive control primitives (toggle switch, collapsible,
   slider) — previously `bits-ui` — as Hologram components.
4. Centralized page-state + debounced derived-path recompute feeling smooth under slider drags.

## Scope

**In (spike #1):**
- Desktop app shell: two-column layout (sidebar tool-stack + preview workspace), command bar
  with live parameter-code display, checkerboard preview canvas, metadata overlay, spinner,
  error box.
- **Request tool:** source-image `<select>` only.
- **Crop tool:** width + height (unit px/%/full + number + slider) and gravity `<select>`.
- Real preview via a `fetch`-based JS-interop facade returning byte size + decoded dimensions
  + content-type, with loading and error states.
- Debounced state→path→preview pipeline.
- `@scope`-based global stylesheet; **dark theme only** (no toggle).

**Deferred to spike 2+ (see backlog):** signing (unsigned `_` only for now), deep-link / URL
state, light/dark/system theme toggle, mobile drawer + scrim, and the other ~11 transform
tools. The shell and the pure path-builder are structured so these are additive.

## Decisions

1. **State — centralized page state, in-memory.** One page, `ImagePipeDemoWeb.FiddlePage`
   (`route "/demo"`, static — no route param in spike 1), owns the entire flat demo-state map.
   Tool sections are **stateless presentational components** that render from props and fire
   actions at `target: "page"` (verified valid: a stateless component may bind
   `$change={action: …, target: "page"}`). No URL persistence in spike 1.
2. **Preview — `fetch` + metadata via JS interop.** A JS facade fetches the image, reads blob
   size + content-type, creates an object URL, and loads it into an `Image` for natural
   dimensions. It **always RESOLVES with a tagged result map** (success / abort / error) and
   **never rejects** — a rejected Task is not observable in an Elixir action (no `.catch` in
   the runtime's await/execute path, and `try/rescue` is unimplemented client-side). The facade
   owns single-flight cancellation and object-URL lifecycle (see Preview).
3. **Signing — deferred.** Spike 1 uses the unsigned `_` signature segment (the demo plug
   trusts `_`/`unsafe`). HMAC compatibility between Web Crypto and ImagePipe's `signature.ex`
   was already proven during review, so adding signed mode later is low-risk (see Spike 2
   backlog for the recipe and invariants).
4. **Shell — desktop, dark only.** Full two-column shell + command bar + preview canvas. The
   theme toggle and the mobile drawer are deferred (the global stylesheet's `:root` already
   defaults to dark, so no toggle is needed to look right).
5. **Source form — bare `images/<name>`.** Both `images/x.jpg` and `local:///images/x.jpg`
   parse to the same `path:` source, but the bare form matches the existing HomePage and wire
   tests, and (when signing lands) avoids the signed-bytes/URL mismatch that the `local:///`
   form would require care with. `ProcessingPath` emits the bare form.
6. **CSS — root class + native `@scope`** (see CSS strategy, with corrected expectations).

## Architecture & state model

**Centralized page state.** `FiddlePage` holds the entire flat demo-state map (ported
field-for-field from the Svelte `DemoState`, restricted to the fields the in-scope tools use
plus their derived defaults). Tool sections are **stateless** components rendering from props
and firing actions at `target: "page"`. The page recomputes the derived processing path on
every change via a pure `ProcessingPath.build/1`.

Rationale: the path is a pure function of the whole state, so a single owner is simplest;
Hologram makes upward state aggregation awkward, so distributed tool state would mean constant
context plumbing. This scales to the deferred tools by field-count only, not by dispatch shape.
Rejected alternative: per-tool stateful components aggregated via context.

## Component tree & file layout (under `demo_new/`)

```
lib/image_pipe_demo_web/
  fiddle_page.ex             # route "/demo"; owns DemoState, actions, preview orchestration
  fiddle_layout.ex           # <!DOCTYPE><html data-theme="dark"><head><Hologram.UI.Runtime/>
                             #   + global css <link></head><body><slot/></body>
  components/fiddle/
    ui/
      toggle_switch.ex        # reimplements the bits-ui Switch (on/off, data-state hook)
      collapsible.ex          # reimplements the bits-ui Collapsible (Request section header+body)
      slider.ex               # reimplements the bits-ui Slider (crop dimension)
    tool_section.ex           # .tool-section wrapper + header
    tool_toggle_header.ex     # title/summary + toggle_switch (ports ToolToggleHeader.svelte)
    request_tool.ex           # source <select>
    crop_tool.ex              # width/height (dual-unit + slider) + gravity <select>
    crop_dimension_control.ex # px/%/full unit + number + slider (ports CropDimensionControl.svelte)
    preview_canvas.ex         # checkerboard, <img>, metadata overlay, spinner, error
    command_bar.ex            # menu placeholder, live parameter code, actions:
                             #   Copy URL = copy the live /img/_/{opts}/plain/{source} IMAGE url;
                             #   Open = open that image url in a new tab.
                             #   (Neither uses deep-link page state, which is deferred.)
  fiddle/
    demo_state.ex             # DemoState struct + defaults; resets crop px from source
    processing_path.ex        # state -> imgproxy path (pure); ports processing-path.ts
    sample_images.ex          # [{path, width, height}] — explicit hardcoded list (no Vite scan):
                             #   images/dog.jpg {5011,7516} (default), images/beach.jpg {4000,2667}
priv/static/
  css/fiddle.css             # ported global stylesheet (@scope) + theme variables; Plug.Static
  images/*.jpg               # sample images copied from the library's priv/static/images
assets/js/fiddle/
  preview.mjs                # fetch image -> {objectUrl,width,height,bytes,contentType}|error;
                             #   owns AbortController single-flight + objectURL revocation
```

`processing_path.ex`, `demo_state.ex`, and `sample_images.ex` are pure modules — unit-testable
with ExUnit, no browser. `css/fiddle.css` is added to the demo's `static_paths/0` (already
includes `css`) and linked from the layout as a plain `<link>` (no esbuild/Tailwind).

The three `ui/` primitives are first-class porting work, not styling. The Svelte version's
`bits-ui` Switch/Collapsible/Slider are dropped (a Svelte lib); the styles that target them
(`:global(.switch-root)`, `[data-state="checked"]`, etc.) must be rewritten against whatever
markup/attributes these Hologram components emit. Spike 1 reproduces the `[data-state]` hooks
the CSS relies on.

## Data flow

Spike 1 has a single side-effecting effect (preview fetch); there is no URL sync and no
signing, so there is exactly **one** chained action — which matters because `Hologram.Component`
stores `next_action` as a single overwriting field (chaining two `put_action`s would silently
drop one).

```
control $change → action on "page" → put_state(field)
   → recompute path = ProcessingPath.build(state)        (pure)
   → put_state(:path); bump :preview_gen
   → put_action(name: :commit, delay: 150, params: %{gen: preview_gen})   # debounce; ONE chained action
                                                                          # (longhand: top-level gen: would be ignored)

:commit (client/JS interop): if params.gen != current :preview_gen → no-op (stale scheduled action)
                             else put_state(:loading, true) and `Task.await(preview.mjs load)`.
                             The facade ALWAYS RESOLVES with a tagged map (it never rejects;
                             a rejected Task never reaches the action's state-application path):
                               → %{ok: true, …}             → put_state(metadata, objectUrl); loading false
                               → %{ok: false, kind: "abort"} → return state unchanged (a newer fetch won)
                               → %{ok: false, …}             → put_state(:preview_error, {status, body})
```

- **Debounce** = `delay:` + a generation counter. `delay:` exists for actions and scheduled
  actions cannot be cancelled, so the generation guard is necessary to drop stale *scheduled*
  actions. (`delay` on commands is unimplemented — keep debounced work in actions.)
- **Stale *responses* are handled in the facade, not Elixir.** `preview.mjs` is single-flight:
  each call aborts the previous in-flight `fetch`. A superseded request **resolves** with
  `%{ok: false, kind: "abort"}` (it must NOT reject — a rejected Task never reaches the action),
  which the action ignores, so stale metadata never lands. This is why the Elixir side needs no
  second gen re-check after the await.
- **`Task.await` has no enforced client timeout** in the Hologram runtime, so the facade owns
  the timeout (its `AbortController` aborts on a deadline as well as on supersession).
- **Initial load:** `init/3` builds default state (default source → `resetCropPixelsToSource`)
  and chains a single `put_action(:commit)` that runs on client mount to load the first image.

## Tools & path encoding

Full preview URL: `/img` (the mounted plug prefix) + `/_/{opts}/plain/{source}`. When Crop is
disabled there are zero options, giving the **no-geometry** form `/img/_/plain/images/<name>`
(the parser accepts an empty option list before `plain/`); the preview then returns the source
re-encoded at its original dimensions.

**Request tool (spike 1):** source `<select>` from `SampleImages`. Changing the source runs
the `resetCropPixelsToSource` equivalent (crop px defaults + slider limits derive from the
selected image's dimensions). Signature UI is deferred.

**Crop tool:** width + height via `CropDimensionControl` (unit px / % / full + number input +
`ui/slider`); gravity `<select>` (`inherit`, `ce`, `no`, `so`, `ea`, `we`, `noea`, `nowe`,
`soea`, `sowe`). Encoding `c:{w}:{h}[:{gravity}]` where `full → 0`, `percent → 0.x`,
`px → integer`; the gravity arg is omitted when `inherit`. Verified against the parser:
`option_grammar.ex` maps `0→:auto`, `0<n<1→{:scale,n}`, `n≥1→{:pixels,n}`, and all nine
gravity tokens exist; `inherit` correctly has no token.

**Crop defaults are source-dependent** (this was missing before): `SampleImages` carries
`{path, width, height}` per image. `DemoState` derives the default crop px width/height from
the default source, and the `CropDimensionControl` px-unit slider max is bounded by the source
dimensions. Both are recomputed when `source` changes. Note: crop px and % fields round-trip
independently — only the *active* unit's value is authoritative (matches Svelte).

## Preview (JS interop fetch facade)

`assets/js/fiddle/preview.mjs` exposes an async `load(url) -> {objectUrl, width, height, bytes,
contentType}`. It is **single-flight** and owns the full lifecycle:
It **always resolves with a tagged map — it never rejects** (a rejected Task is not deliverable
to an Elixir action: the runtime's await/execute path has no `.catch`, and `try/rescue` is
unimplemented client-side):
- `%{ok: true, objectUrl, width, height, bytes, contentType}` on success.
- `%{ok: false, kind: "http", status, statusText, body}` on a non-OK response, so the action can
  build the same `"{status}: {body}"` label the Svelte app shows.
- `%{ok: false, kind: "abort"}` when superseded/aborted (the action ignores it).
- `%{ok: false, kind: "error", message}` for any thrown/network error (caught in JS).

Lifecycle the facade owns:
- Holds the current `AbortController`; aborts the previous in-flight request on each new call,
  on a timeout deadline (since `Task.await` won't time out), and on page teardown.
- On OK: blob → `createObjectURL` → load into `Image` for natural width/height → resolve.
- Holds the current object URL; **revokes the previous one** when a new one is ready, and on
  abort/error/teardown. (The Svelte app revokes meticulously; not doing so leaks a blob URL on
  every slider tick.)

The awaiting `:commit` action pattern-matches the resolved map (above) — no `try`/`catch`.

## CSS strategy (with corrected expectations)

**Root class + native `@scope`.** The page root carries `class="ip-demo"`; the demo's layout/
component rules are wrapped in `@scope (.ip-demo) { … }`. What this **does**: contain the
demo's styles at the *app boundary* so they cannot leak into Hologram's runtime DOM or future
pages — equivalent to prefixing every rule with `.ip-demo`, plus proximity-based specificity.

What it **does not** do (corrected from the first draft): it is **one flat scope**, not
per-component isolation. Bare element selectors (`select`, `code`, nested `img`/`figure`/`h2`)
still apply across the *entire* `.ip-demo` subtree — they are contained from the outside world
but not isolated from siblings inside the demo. Acceptable for a single-page spike; revisit
per-component `@scope` if multiple pages later share the stylesheet. Specificity differs from
Svelte's compiled output, so the `:where(...)`/`:global(...)` blocks need a manual review pass
during the port — this is **not** a mechanical wrap.

Theme variables and resets (`:root`, `[data-theme]`, `html`, `body`) stay **outside** `@scope`
(global), exactly as today. Spike 1 ships **dark only** (the stylesheet's `:root` defaults to
dark); no `data-theme` toggle, no `localStorage`, so no SSR flash-of-theme to handle yet.

**Browser support:** `@scope` needs Chrome 118+/Safari 17.4+/FF 128+. Acceptable for a dev/
test harness, but note the failure mode is a cliff: an unsupported engine drops the whole
`@scope` block and renders the demo unstyled. No fallback for the spike.

**Stale guideline:** `demo_new/priv/static/css/app.css` carries a comment mandating flat
prefixed classes / no bare selectors. The `@scope` approach deliberately supersedes that for
the scoped demo stylesheet (leakage is contained at the app boundary); update or remove that
comment so the two don't contradict the next reader.

## Testing

- ExUnit unit tests for `ProcessingPath.build/1` — Crop encodings across px/%/full and gravity
  inclusion/omission; Request source form.
- ExUnit tests for `DemoState` source-change → crop-default/limit derivation
  (`resetCropPixelsToSource`).
- One wire-level test: `GET /img/_/c:…/plain/images/…` → `200 image/jpeg` with expected decoded
  output dimensions (reuses the `imgproxy_wire_conformance_test.exs` `c:` pattern).
- Wire-level no-geometry case: `GET /img/_/plain/images/dog.jpg` → `200 image/jpeg` at the
  source's original dimensions (crop disabled; per CLAUDE.md, cover the no-geometry form
  separately).
- The `preview.mjs` facade is verified manually in-browser (screenshot) during the spike.

## Risks / things the spike validates

- Async JS interop (Promise → Task) for `fetch`, and the facade-owned single-flight/abort/
  object-URL lifecycle behaving smoothly under slider drags.
- `delay:` + generation-counter debounce feeling smooth.
- `@scope` porting fidelity vs. Svelte's per-component scoped styles, including the manual
  `:where`/`:global` specificity pass and the reimplemented switch/collapsible/slider.

## Spike 2 backlog (deferred, with the caveats that apply when they land)

- **Signing (client Web Crypto):** HMAC-SHA256 over the path; sign `salt <> signed_path` where
  `signed_path` is everything after the signature segment; truncate to 32 bytes; **unpadded**
  base64url; hex-decode key/salt. Defaults to the plug's configured `keys: ["736563726574"]`,
  `salts: ["68656c6c6f"]` so signed previews validate. **Invariant:** the signed bytes and the
  request URL's source segment must come from one canonical string (use the bare `images/x.jpg`
  form everywhere) or you get a 403. This **diverges from the Svelte reference**, which signs the
  `local:///images/...` form — so do not port the Svelte signing tests as the canonical string.
  Do **not** add an Elixir test asserting the HMAC string
  (tests the encoding, not the contract) — the wire-level `200` on a signed path is the
  assertion.
- **Deep-link / URL state:** `route "/demo/:state"` + `param :state, :string` with the canonical
  path serialized as **unpadded** base64url in one segment. Match Svelte: encode only
  `{options}/plain/{source}` — **not** the signature (signature mode/key/salt are session-only),
  which makes the round-trip lossless. Port `resetCropPixelsToSource` on decode. The live URL
  rewrite must use `history.replaceState(history.state, "", url)` — preserving Hologram's own
  `history.state` snapshot UUID, or back/forward breaks. Guarantee is state→token→state, not
  byte-identity. Handle the empty/initial `/demo` case.
- **Theme toggle (light/dark/system):** `data-theme` on the layout `<html>` driven by **page**
  state (the page-state→layout-props merge propagates it; the toggle targets `"page"`).
  Persist via `localStorage`. **FOUC:** SSR cannot read `localStorage`, so add a tiny **inline,
  blocking `<head>` script** that sets `data-theme` before first paint — a deferred interop
  facade runs too late and will flash.
- **Mobile drawer + scrim:** pure-CSS transform drawer toggled by a `drawer_open` page-state
  field. Reproduce the deferred a11y: focus trap, Escape-to-close, focus restoration, and
  `inert` on the off-screen panel gated by a `matchMedia("(max-width: 720px)")` interop signal
  (`inert` can't be set by CSS).
- **The other ~11 transform tools** (Resize, Gravity, Scale options, Orientation, Aspect
  canvas, Padding, Background, Effects, Format, Quality), added on the same shell + path-builder.

## Out of scope

- Any change to the library or to the existing Svelte `demo/`.
- Per-component `@scope` isolation (spike uses one root-level scope).
- Server-side signing; signing with keys the plug does not trust.
- **Note:** `demo_new/` does not yet replace `demo/`, so the CLAUDE.md transform-sync
  obligation ("update the demo when a transform's params change") still points at `demo/` until
  the cutover. A future transform change currently has two demos to consider.
