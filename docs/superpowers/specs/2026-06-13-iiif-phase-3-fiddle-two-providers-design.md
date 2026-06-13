# Fiddle demo: two providers (imgproxy + IIIF) — IIIF Phase 3

**Issue:** [#254](https://github.com/hlindset/image_pipe/issues/254)
**Depends on:** [#253 / PR #270](https://github.com/hlindset/image_pipe/pull/270) — Phase 2 `ImagePipe.Parser.IIIF` (merged)
**Status:** design approved (interactive brainstorm); reviewed (3 parallel lenses — frontend state-model, imgproxy no-regression, backend/IIIF integration) and revised; pending user spec review → implementation plan

## Goal

Extend the `fiddle/` demo from a single provider (imgproxy) to two (imgproxy + IIIF Image API 3.0), so the demo exercises the IIIF parser end-to-end. This closes the `AGENTS.md` "keep the demo UI in sync" gap that Phase 2 (#253) consciously deferred for the IIIF parser options and the `gray` quality op.

The one-provider → two-provider shift is a UI/state-model design problem, not a copy-paste: provider selection, divergent control grammars, per-provider URL state with no cross-dialect leakage, and provider-specific features that must not bleed across.

## Non-goals (deferred)

- **info.json / descriptor exploration.** Both providers now expose JSON descriptors (imgproxy info API #252, IIIF `info.json` #253). Surfacing them in the demo is its own follow-up issue. The #254 acceptance criteria mark this optional.
- **Deeper shell decomposition** (breaking the preview workspace / command bar / mobile drawer into sub-components). Out of scope; only the provider control panels are extracted.
- **Renaming `DemoState`.** It stays as the imgproxy state slice to minimize churn and imgproxy-regression risk.
- **A third+ provider.** The model is built to accept more (Thumbor, imgix, TwicPics, …) via a provider registry + dropdown, but only imgproxy and IIIF ship here.

---

## Decisions (from the brainstorm)

| Decision | Choice | Rationale |
| --- | --- | --- |
| Frontend state model | **Namespaced container**, in-memory | `AppState = { provider, imgproxy, iiif }`; both slices held in memory, **only the active one serializes to the URL**. No cross-dialect leakage by construction; in-session toggling preserves edits. |
| URL serialization | **Single provider** (the active one) | Keeps each URL ~1:1 with that provider's request path; the URL never carries both dialects' params. |
| App.svelte refactor | **Extract per-provider panels, bindable `state` prop** | `App.svelte` keeps the shell; imgproxy sections → `ImgproxyControls.svelte`, IIIF → `IiifControls.svelte`. Each panel takes a `bind:state` prop equal to its slice, so the moved markup's `state.X` references are **unchanged** (low churn, not a `state.X → state.imgproxy.X` rewrite). Matches the codebase's "large file = doing too much" guideline; isolates regression risk per panel. |
| Browser URL scheme | **Provider as first segment; IIIF service off-root** | Browser `/imgproxy/…` and `/iiif/…`; imgproxy service stays at `/img`, IIIF service mounts at `/iiif-image` so `/iiif/…` is free for the SPA. |
| IIIF control panel | **One grouped "IIIF parameters" panel** | IIIF's five params are positional and always present — no on/off toggles. A single always-visible form fits; per-concept accordions would add clicks/chrome for nothing. |
| Provider switcher | **Dropdown at top of sidebar**, above Request | Scales to N providers (future targets slot in as menu items, no layout change). |

---

## Architecture

### Backend (`fiddle/`)

The IIIF image service mounts exactly like the imgproxy one — a thin plug delegating to `ImagePipe.Plug.call/2` with opts built once at boot and stashed in `:persistent_term`.

**Router** (`lib/image_pipe_fiddle_web/router.ex`):

```elixir
forward "/img", ImagePipeFiddleWeb.Imgproxy          # existing — imgproxy image service
forward "/iiif-image", ImagePipeFiddleWeb.IIIF       # new — IIIF image service

scope "/", ImagePipeFiddleWeb do
  pipe_through :browser
  get "/*path", PageController, :home                # SPA: serves /, /imgproxy/*, /iiif/*
end
```

`/imgproxy/*` and `/iiif/*` (browser URLs) fall through to the catch-all SPA route — no collision, because the forwarded image services are `/img` and `/iiif-image`, neither of which shadows the `iiif` or `imgproxy` first segment.

**New plug** `ImagePipeFiddleWeb.IIIF`. Unlike imgproxy, the canonical IIIF mount runs `ImagePipe.Parser.IIIF.CORS` **ahead of** `ImagePipe.Plug` — that plug owns `OPTIONS` preflight (halts with `Allow-Methods`) and registers the `Access-Control-Allow-Origin: *` before-send hook; the IIIF parser's `parse/2` returns a tuple, not a conn, so it cannot set these itself. So the imgproxy plug is *not* a complete template here:

```elixir
defmodule ImagePipeFiddleWeb.IIIF do
  @behaviour Plug
  alias ImagePipe.Parser.IIIF.CORS

  def init(_opts), do: []

  def call(conn, _opts) do
    cors_conn = CORS.call(conn, CORS.init([]))

    if cors_conn.halted do
      cors_conn
    else
      ImagePipe.Plug.call(cors_conn, :persistent_term.get({ImagePipeFiddle.Application, :iiif_opts}))
    end
  end
end
```

(The demo's own preview is same-origin, so CORS headers aren't *functionally* required for the preview to load — but the mount must be correct and `OPTIONS` handled, matching the canonical IIIF mount and the Phase-4 viewer-interop story.)

> This manual composition is **interim**. [#284](https://github.com/hlindset/image_pipe/issues/284) moves CORS behind a generic `Parser` behaviour hook the core invokes; when it lands, this plug drops the wrapper and delegates straight to `ImagePipe.Plug`. #254 is not blocked on it.

**`application.ex`** builds and stores `iiif_opts` alongside `imgproxy_opts`:

```elixir
:persistent_term.put({__MODULE__, :iiif_opts}, build_iiif_opts())

defp build_iiif_opts do
  static_root = Application.app_dir(:image_pipe_fiddle, "priv/static")

  [
    parser: ImagePipe.Parser.IIIF,
    iiif: [resolver: {ImagePipe.Parser.IIIF.Resolver.Static, map: iiif_source_map()}],
    sources: [path: {ImagePipe.Source.File, root: static_root, root_id: "static", stable: :trusted}]
  ]
  |> maybe_put_cache(Application.get_env(:image_pipe_fiddle, :cache))
  |> ImagePipe.Plug.init()
end
```

- No `detector_required:` — IIIF Level 2 has no smart/object-detect crop, so `Plan.detect_classes/1` is always `nil` and the detector gate is a dead branch. Carrying it would be misleading copy-paste from imgproxy.
- The existing `cache_children/1` supervisor child is started **once** (it already is). `build_iiif_opts` reuses `maybe_put_cache/2` so both plugs share the one cache backend — do **not** add a second `cache_children` call. Cache keys differ by plan/parser, so there is no cross-provider collision.

`iiif_source_map/0` maps each sample image to `id → %ImagePipe.Plan.Source.Path{segments: ["images", "<file>"]}`, resolved against the `Source.File` root (the same static root imgproxy uses). IIIF default opts (`auto_rotate: true`, `formats: [:jpg, :png, :webp, :avif]`, `qualities: [:default, :color, :gray, :bitonal]`, `tile_size: 512`) are accepted as-is.

**Identifiers must be a single, stem-unique path segment.** `Parser.IIIF.Path.classify/1` dispatches by exact `path_info` segment count, so an id containing `/` would split into extra segments and break classification. Identifiers are therefore the slash-free basename **without extension**: `images/dog.jpg → "dog"`, `images/concert.jpeg → "concert"`, `images/dog_2.jpg → "dog_2"`. Because the extension is dropped, **stems must be unique across the whole sample set** (a future `dog.png` beside `dog.jpg` would both map to `dog` and silently shadow in the map). `iiif_source_map/0` builds the map from the one shared sample-image set and the frontend derives the same id from the sample-image path; the derivation must stay identical on both sides. Pin it: a wire test round-trips a real id, and a frontend test asserts derived ids are unique across `sampleImages`.

### Frontend state model

A container wraps two independent provider slices:

```ts
type Provider = "imgproxy" | "iiif";

type AppState = {
  provider: Provider;
  imgproxy: DemoState;   // unchanged imgproxy slice (today's DemoState)
  iiif: IiifState;       // new
};

type IiifRegion =
  | { kind: "full" }
  | { kind: "square" }
  // px: x,y non-negative integers; w,h positive integers.
  | { kind: "px"; x: number; y: number; w: number; h: number }
  // pct: x,y non-negative DECIMALS; w,h positive decimals (grammar accepts pct:10.5,20,33.3,40).
  | { kind: "pct"; x: number; y: number; w: number; h: number };

type IiifSize =
  | { kind: "max" }
  | { kind: "w"; w: number }            // w,    — positive integer
  | { kind: "h"; h: number }            // ,h    — positive integer
  | { kind: "wh"; w: number; h: number } // w,h  — positive integers, may distort
  | { kind: "confined"; w: number; h: number } // !w,h — positive integers
  | { kind: "pct"; n: number };         // pct:n — positive decimal; n > 100 only when upscale

type IiifState = {
  source: SourceImage;                  // shared sample-image set; IIIF id derived from it
  region: IiifRegion;
  size: IiifSize;
  upscale: boolean;                     // the leading ^ on size
  rotation: 0 | 90 | 180 | 270;
  quality: "default" | "color" | "gray" | "bitonal";
  format: "jpg" | "png" | "webp" | "avif";
};
```

- **Constraints are enforced in `iiif-path.ts` builders + `controlLimits`, not left to bare `number`** — these mirror `Parser.IIIF.Grammar` exactly so the UI can never build a token the backend 400s:
  - px region: `x,y ≥ 0`, `w,h ≥ 1`, integers. pct region: `x,y ≥ 0`, `w,h > 0`, decimals allowed.
  - size `w`/`h`/`wh`/`confined`: positive integers. size `pct`: `> 0`, and `> 100` only when `upscale` is set (the `^`-gated rule; bare `pct:200` is a 400, `^pct:200` is valid). `wh` is the only distorting form (`mode: :stretch`).
  - rotation is a fixed 4-item select (`0/90/180/270`); no mirror (`!`) input — the grammar rejects it.
- **px-region bounds policy:** the backend *clips* a partially out-of-bounds px region to the image and only 400s a region that is wholly outside or has `w`/`h` = 0 (per the IIIF support matrix). So per-axis clamping to the source's real dimensions (reusing the `cropPixelLimit` pattern) is a UX nicety; **no joint `x + w ≤ W` bound is required** and `0,0,W,H`-style over-asks are harmless.
- Both slices live in `AppState` for the session. **Only the active slice is encoded into the URL.** On mount the URL seeds the active slice and the other defaults; on `popstate` the dispatcher re-derives **only the active provider's slice** and **leaves the in-memory inactive slice untouched** (it is not reset) — so Back/Forward never silently wipes the other panel's edits. A reload/share starts a fresh page, so only the active provider survives there.
- A **provider switch uses `history.replaceState`** (a mode change, not a navigable document), rewriting the URL to the newly active provider's canonical form. Root/unknown first segment → default provider default state, also via `replaceState`.
- `source` (which sample image) is shared UI; each provider maps the chosen image to its own identifier form (`local:///images/dog.jpg` for imgproxy, `dog` for IIIF).
- `IiifState` defaults: `region: full`, `size: max`, `upscale: false`, `rotation: 0`, `quality: default`, `format: jpg`. Default URL: `/iiif/dog/full/max/0/default.jpg`.

### URL scheme

Browser URLs (the only persistence — `parseDemoPath` on mount/`popstate`, `updateDemoLocation` on edit):

```
/imgproxy/<opts>/plain/local:///images/<file>
/iiif/<id>/<region>/<size>/<rotation>/<quality>.<format>
```

`demo-url-state.ts` gains a **dispatcher layer** that owns the provider prefix; the existing imgproxy builders/parsers stay **prefix-free and unchanged**:
- New `appPathForState(appState)` / `parseAppPath(pathname)`: on build, prepend `/<provider>`; on parse, read+strip the first segment, then hand the **unprefixed remainder** to that provider's build/parse.
  - `imgproxy` → the existing `signedPathForState` / `optionSegments` / `applyOptionSegment` (operate on `/<opts>/plain/…`, **never** see the `/imgproxy` prefix). Their unit tests are unaffected.
  - `iiif` → new IIIF build/parse over `<id>/<region>/<size>/<rotation>/<quality>.<format>`.
- Root `/` or an unknown first segment → default provider (imgproxy) default state, then `replaceState` to `/imgproxy/…`. **Greenfield break (accepted):** an old, unprefixed bookmark like `/g:sm/plain/local:///images/dog.jpg` is no longer recognized (first segment `g:sm` is unknown) and resets to defaults — acceptable since no released URLs exist; called out so it isn't a silent surprise.
- App.svelte calls `appPathForState` for `window.history` updates (replacing the current `demoPathForState` usage) and `parseAppPath` on mount/`popstate`.

**Signing invariant (must hold):** the `/imgproxy` browser prefix lives **only** in the dispatcher's build/parse. It must never be an input to `signedPathForState`, `buildProcessingPath`, the preview `fetch`, or the Copy-URL action — those continue to operate on the unprefixed signed path and the `/img/<sig>/…` fetch path. (Stated so an implementer doesn't "simplify" the copy/preview path to reuse the browser-URL builder, which would sign the prefixed path and break signed mode.)

**Fetch paths** (shape unchanged from today):
- imgproxy: `/img/<signature>/<opts>/plain/local:///images/<file>` — built by `buildProcessingPath`; the `/imgproxy` browser prefix never enters it; signing logic untouched.
- IIIF: `/iiif-image/<id>/<region>/<size>/<rotation>/<quality>.<format>` — **no signature**; the format is explicit in the path, so there is **no `Accept` negotiation** and a provider-specific resolved-output label simply shows the chosen format (IIIF must not reuse the imgproxy-only `resolvedOutputLabel`). The `previewParameters` line (today an imgproxy-shaped two-segment strip of `/img/<sig>/`) branches per provider.

### Components

```
fiddle/assets/
  App.svelte               # shell: provider dropdown, shared Request (source), preview workspace,
                           #        command bar, theme, mobile drawer, copy/open/reset. Owns AppState,
                           #        computes the active fetch path, renders the active provider panel.
  ImgproxyControls.svelte  # NEW — all existing imgproxy tool sections, bound to AppState.imgproxy.
                           #        Signature/signing moves here (imgproxy-only).
  IiifControls.svelte      # NEW — the single grouped "IIIF parameters" panel bound to AppState.iiif.
  processing-path.ts       # imgproxy state (DemoState) + signed-path/URL building (largely unchanged).
  iiif-path.ts             # NEW — IiifState type, defaults, region/size/rotation/quality/format
                           #        segment builders, the IIIF browser+fetch path builders, control limits.
  demo-url-state.ts        # provider-dispatch parse/build; imgproxy parse (existing) + IIIF parse (new).
```

- **Provider dropdown** is the first control, above Request. Changing it flips `AppState.provider`, swaps the rendered panel, and `replaceState`s the URL to the newly active provider's canonical form.
- **Shared Request section**: `source` only. Imgproxy signature controls move into `ImgproxyControls.svelte`.
- **Binding contract.** Each panel receives `bind:state={appState.imgproxy}` / `bind:state={appState.iiif}` (its slice) plus `source` (or its derived limit) as a prop. Naming the prop `state` keeps the moved markup's `state.X` references identical.
  - **Svelte reactivity hazard (call out for the implementer):** several imgproxy controls mutate state **in place** rather than reassigning — the focal-point picker (`state.gravityFocalX = …`), `syncObjClasses` (`state.objSelectedClasses = …`, `state.objWeights = …`), and crop-pixel resets. In-place mutation of a `bind:`-passed object must still reassign the bound prop (`state = state` / assign-then-reassign) so the parent's derived path/URL recompute. These are the regression-prone spots; cover them with a focal-point + object-class interaction test, not just path-builder round-trips.
- **Cross-provider source reset.** `source` is shared and lives in App, but it feeds *both* providers' source-dependent pixel fields. On a source change App must reset **both** the imgproxy crop pixels (`resetCropPixelsToSource`) **and** the IIIF px-region inputs to the new source's dimensions — otherwise an IIIF px region left over from a larger image is stale after switching source. Each panel recomputes its pixel limits from the `source` prop.
- **`IiifControls.svelte`**: region select (`full` / `square` / pixel / percent) with conditional x,y,w,h inputs (pixel inputs clamped per-axis to the source's real dimensions, reusing the `cropPixelLimit` pattern; percent inputs accept decimals); size select (`max` / `w,` / `,h` / `w,h` / `!w,h` / `pct:n`) with conditional numeric inputs + an "Allow upscaling (`^`)" toggle (which gates `pct:n > 100`); rotation select; quality select; format select. A live URL tail mirrors the generated path.

---

## Testing (`mise run precommit:demo` must pass)

Per the `AGENTS.md` demo/fiddle test guidance — representative wire-level coverage of public contracts, not exhaustive grammar combinatorics (the parser/grammar tests in the core lib already own that).

**Elixir wire** (`fiddle/test/image_pipe_fiddle_web/wire_test.exs`), real `ImagePipe.call/2` requests through the new `ImagePipeFiddleWeb.IIIF` plug (so CORS composition is exercised):
- `GET /iiif-image/dog/full/max/0/default.jpg` → `200`, image content type, decoded dimensions equal the source (full/max baseline), and `Access-Control-Allow-Origin: *` present.
- A representative geometry request (e.g. `…/0,0,100,100/50,/0/default.jpg`) → `200` with the expected decoded dimensions.
- A representative bad token (e.g. invalid rotation `…/0/0/45/default.jpg`) → `400`; an unknown id → `404`.
- `OPTIONS /iiif-image/dog/full/max/0/default.jpg` → `200` with `Access-Control-Allow-Methods` (preflight halts before `ImagePipe.Plug`).
- Existing imgproxy wire tests unchanged — **no regression** (the `/img` mount, signing, and `Accept` negotiation are untouched).

**JS** (`fiddle/assets/*.test.ts`):
- `iiif-path`: each region/size/rotation/quality/format form builds the expected segment; parse∘build round-trips per `IiifState`, including `^` upscaling, decimal `pct:` region/size, and `!w,h`; the `^`-gated `pct:n > 100` and positive-int constraints reject out-of-range inputs.
- `demo-url-state` dispatcher: first-segment provider dispatch; **switching providers yields a valid URL for the selected provider with no cross-dialect parameter leakage** (the inactive slice never appears in the active URL); `popstate` re-derives only the active slice and leaves the inactive in-memory slice intact; root/unknown → default.
- A **frontend assertion that derived IIIF ids are unique across `sampleImages`** (guards the stem-collision hazard).
- A **focal-point + object-class interaction test** for `ImgproxyControls` covering the in-place-mutation reactivity path.
- **Test-contract change to acknowledge (not "intact"):** the imgproxy *option/signed-path* builders (`optionSegments`, `signedPathForState`) stay prefix-free, so their `processing-path.test.ts` assertions are unchanged. But any assertion on the *browser* URL (the old `demoPathForState`, which returned the unprefixed signed path) moves to the new dispatcher (`appPathForState`) and gains the `/imgproxy` prefix. Those specific assertions are updated; new dispatcher round-trip tests are added.

---

## Acceptance criteria (from #254)

- [x] Provider selector the controls and URL-state layer respect → dropdown driving `AppState.provider`.
- [x] IIIF controls covering the Level 2 surface from #253: region (`full`/`square`/pixel/`pct:`), size (all forms incl. `!w,h`, `pct:n`, `^`), rotation (90s), quality (`default`/`color`/`gray`/`bitonal`), format.
- [x] Per-provider URL encode/decode; provider switch yields a valid URL for the selected provider, no cross-dialect leakage.
- [x] Existing imgproxy demo behavior preserved (no regression).
- [x] `mise run precommit:demo` passes.

## Conformance-doc impact

This is the demo/fiddle subproject, so no `docs/iiif_3_support_matrix.md` change is required — the demo surfaces the already-documented Level 2 parser surface without altering parser/output/stage behavior. (Per `AGENTS.md`, the compatibility reviewer is optional for fiddle-only changes; review lenses should be UI/state-model design, the two-provider abstraction, and imgproxy no-regression.)
