# TwicPics-compatible parser — design

- **Status:** Approved (brainstorming) — revised after parallel review cycle; ready for implementation planning
- **Date:** 2026-05-31
- **Scope owner:** `ImagePipe.Parser.TwicPics.*`

## Context

ImagePipe already ships an imgproxy-compatible parser (`ImagePipe.Parser.Imgproxy`)
that translates a vendor URL dialect into a product-neutral `ImagePipe.Plan` and
reuses the shared source / cache / output / response runtime. This design adds a
second compatibility parser for the [TwicPics media transformation
API](https://www.twicpics.com/docs/essentials/api.md) as an alternative dialect
in front of the same runtime.

A limited TwicPics parser existed previously (last present around commit
`e80fbbb`), but it predated the `ImagePipe.Plan` model: it lived in the old
`ImagePlug.*` namespace and returned `[{TransformModule, ParamsStruct}]` tuples
directly with no Plan. It was removed when the native (now imgproxy-compatible)
path API landed. We are **not** porting it wholesale. We keep its lessons (a clean
units grammar, a paren-aware key/value splitter, position-tracked error
reporting) and rewrite the transform mapping against today's
`Plan.Operation.*` constructors.

### TwicPics is order-dependent — and so is ImagePipe's Plan

TwicPics chains are explicitly applied **in order**, each transformation
operating on the result of the previous one, and relative units (`p` percent,
`s` scale) resolve against the **running** dimensions:

```
resize=340/resize=50p   →   170px   (50% of the prior 340, not of the source)
```

This is **not** in tension with ImagePipe's core. ImagePipe's `Plan` is an
**ordered pipeline by design** — sequential, order-dependent execution is native
to ImagePipe. The CLAUDE.md constraint that "URL option order must not define
processing order" is a property of the **native (imgproxy) dialect**, not of
ImagePipe itself: that dialect was deliberately built so URL option order does
*not* define processing order — its parser emits a fixed-order pipeline
regardless of how the options are written. That order-insensitivity lives in the
imgproxy parser, not in the Plan.

So TwicPics' ordered chain maps **directly** onto ImagePipe's ordered Plan
pipeline. The only discipline required is the one CLAUDE.md states for any
compatibility parser: keep dialect-specific quirks (the chain→pipeline ordering,
stateful focus, relative units) **isolated in the TwicPics parser** and don't
force them into the imgproxy parser's order-insensitive contract. The Plan gains
the ability to carry a *relative dimension unit* — product-neutral data, not an
ordered-command contract.

## Goals (v1)

Support the core geometry + output surface, faithfully including
running-dimension chaining:

- Transforms: `resize`, `cover`, `contain`, `inside`, `crop`, `focus`, `output`, `quality`.
- Units: pixels (bare or `px`), percent (`p`), scale (`s`), ratio (`W:H`),
  coordinates (`XxY`), and the **eight** TwicPics anchors (`top`, `bottom`,
  `left`, `right`, `top-left`, `top-right`, `bottom-left`, `bottom-right`).
  `center` is **not** a TwicPics anchor literal — it is only the default focus
  (see Units grammar).
- Full running-dimension fidelity: relative units resolve against the running
  image at execution time, not statically at parse time.
- Output negotiation via the shared `ImagePipe.Plan.Output` model (`output=auto`
  Accept-negotiated with `Vary: Accept`; explicit formats bypass negotiation;
  `quality`).
- Reuse the existing source / cache / response / safety runtime unchanged.
- A `docs/twicpics_support_matrix.md` seeded so every TwicPics transformation and
  parameter has a row and a status from day one.

## Non-goals (v1) — recognized and rejected with a clear error, documented

- Arithmetic expressions in numbers (`(25*10)`, precedence, parentheses).
- Conditional `-min` / `-max` variants (and `min` / `max` aliases).
- The **ratio** forms `resize=W:H` and `inside=W:H` (TwicPics' surface-preserving
  resize-to-ratio has no clean mapping to an existing operation — see Deferred
  items). `cover=W:H` **is** supported (it is a guided ratio crop).
- **Coordinate focus** (`focus=<XxY>` in px/percent/scale). v1 supports the eight
  focus **anchors** only. The Plan's focal guide is a 0..1 ratio, and pixel
  coordinate focus needs a runtime-resolved focal guide (the same machinery as
  relative resize units) — deferred so v1's core change stays scoped to resize
  dimensions. (Crop `@coords` are unaffected — `CropRegion` carries pixel
  coordinates natively.)
- `focus=center` as an explicit literal (center is the default focus, not a
  TwicPics anchor; revisit as a lenient extension later).
- `zoom`, `flip`, `turn`.
- `background`, `border`, `colorize`, color-blindness corrections (color chaining).
- `focus=auto` (smart / content-aware subject detection — see below).
- Video transforms (`duration`, `from`, `to`, video output codecs).
- Placeholders API, `refit-*`, `truecolor`, `download`, `noop`.
- Non-image output values (`blurhash`, `preview`, `maincolor`, `meancolor`,
  `blank`, `heif`).

Each non-goal is **recognized** by the parser and returns a `parser`-level
validation error (`parser.parse/2` → `{:error, …}`) *before* any source fetch or
cache access. ImagePipe does not silently ignore unsupported syntax.

## Reference documentation

See `docs/twicpics_support_matrix.md` for the linked index of TwicPics docs. The
load-bearing ones for v1:

- [API — writing requests](https://www.twicpics.com/docs/essentials/api.md)
- [API Transformations](https://www.twicpics.com/docs/reference/transformations.md)
- [API Parameters](https://www.twicpics.com/docs/reference/parameters.md)
- [Path Configuration](https://www.twicpics.com/docs/essentials/path-configuration.md)

## Architecture

### Request & source model

TwicPics request shape:

```
https://<host>/<path-to-image>?twic=v1/<chain>[&other=params]
```

- **Source.** `conn.path_info` (the path to the media) resolves to an
  `ImagePipe.Plan.Source`. v1 supports a single configured origin and translates
  the path into a product-neutral `%ImagePipe.Plan.Source.Path{segments: …}`.
  Multi-origin TwicPics "path configuration" prefix→origin mapping is out of
  scope for v1.
  - **Code-sharing note.** The imgproxy parser's plain-path translation lives in
    its *private* `ImagePipe.Parser.Imgproxy.Source` / `…Imgproxy.Path`
    submodules, which are **not** exported and belong to a different parser
    boundary. TwicPics must **not** reach into them (cross-parser dependency =
    boundary violation). v1 duplicates the small, product-neutral plain-path →
    `Source.Path` translation inside `TwicPics.Source`. If a third parser later
    needs the same translation, extract a shared neutral helper then.
- **Transforms.** Read the `twic` query parameter (it may appear anywhere in the
  query string), require the `v1/` prefix, then split the remainder into an
  **ordered** list of `name=args` segments.

### Module layout

All under `ImagePipe.Parser.TwicPics.*`, mirroring the imgproxy parser's layering.

| Module | Responsibility |
| --- | --- |
| `TwicPics` | `@behaviour ImagePipe.Parser`. `parse/2`, `handle_error/2`, `validate_options!/1`. Orchestrates path→source, `twic`→chain, builder. |
| `TwicPics.Path` | Extract `conn.path_info` and the `twic` query value; split / validate the `v1/` chain envelope. |
| `TwicPics.Source` | Translate the path into `%Plan.Source.Path{}` against the configured origin (product-neutral; duplicated, not borrowed from imgproxy). |
| `TwicPics.Manipulation` | Split `v1/…` into an **ordered** `[{name, raw_args}]`. v1 uses a plain `/` split (no parens yet). When arithmetic lands, this becomes a paren-aware splitter (the salvageable idea from the old `kv_parser`). |
| `TwicPics.Units` | Parse Length / Size / Crop-size / Ratio / Coordinates / Anchor into product-neutral tagged values: `{:px, n}`, `{:percent, n}`, `{:scale, f}`, `{:ratio, n, d}`, `:auto`, `:full_axis`, and Plan guide tuples. |
| `TwicPics.PlanBuilder` | Fold the ordered chain into an accumulator and emit `{:ok, Plan.t()} \| {:error, term()}` via `ImagePipe.Plan.Operation.*` constructors. |
| `TwicPics.Output` | Map `output=` and `quality=` onto `ImagePipe.Plan.Output` (last value wins). |

`handle_error/2`: v1 has no signatures, so a **single `400` clause** that renders
the error as text (mirroring imgproxy's default-error clause) is sufficient. Do
not reintroduce signature/`403` handling.

### Units grammar (v1)

- **Length** = `<number>` (pixels), `<number>px` (pixels), `<number>p` (percent),
  `<number>s` (scale). `number` is a decimal literal in v1 (no expressions).
  Scale `Ns` = the running dimension × `N` (`(1/2)s` style fractions are an
  arithmetic non-goal; `0.5s` is fine).
- **Size** (used by `resize` / `cover` / `contain` / `inside`) = `WxH`, where each
  of `W`/`H` is a Length or `-`. A single Length with no `x` sets that dimension
  and leaves the other **`:auto`** (computed to preserve aspect). Mixed units are
  legal (`10px150`, `100x50p`).
- **Crop-size** (used by `crop` only) = like Size, **but an omitted dimension or
  `-` means `1s` — the full running axis (`:full_axis`), not aspect-preserving
  auto.** Per the docs, `crop=320` ≡ `320x-` ≡ `320x1s`. This is a real semantic
  difference from Size and the builder must branch on it.
- **Ratio** = `<num>:<num>` (two strictly-positive numbers) → `{:ratio, n, d}`.
  Only `cover` consumes a ratio in v1; `resize`/`inside` ratio forms are non-goals.
- **Coordinates** = `XxY`, two Lengths → used for the `crop=…@XxY` origin (v1:
  pixel coordinates → `CropRegion`). Coordinate **focus** points are deferred; v1
  focus is anchor-only.
- **Anchor** = one of the eight named positions → a Plan guide. There is no
  `center` anchor; `center` is the default guide when no `focus` has been set.

### Chain → Plan mapping (the core behaviour)

`PlanBuilder` folds left-to-right over the chain, carrying an accumulator:

- `ops` — the ordered list of `Plan.Operation.*` produced so far,
- `guide` — the current focus guide (default `:center`),
- pending `output` / `quality` (last value wins).

`focus` produces **no operation**; it updates `guide`, which the *next*
`cover` / `crop` consumes. `crop=…@coords` resets `guide` to center (TwicPics
behaviour — verified against the docs). Ordered execution falls out of the
ordered `ops` list and the already-sequential `ImagePipe.Transform.PlanExecutor`.

| TwicPics | → Plan operation(s) |
| --- | --- |
| `resize=W` (single dim, Size) | `Resize(:fit, W, :auto)` — scale preserving aspect |
| `resize=WxH` | `Resize(:stretch, W, H)` — exact dims, may distort (= imgproxy `force`) |
| `resize=W:H` (ratio) | **Rejected** (non-goal — surface-preserving resize-to-ratio; see Deferred) |
| `cover=WxH` | `Resize(:cover, W, H, guide: guide)` — fill + crop to focus |
| `cover=W:H` (ratio) | `CropGuided(:full_axis, :full_axis, aspect_ratio: {:ratio, …}, guide: guide)` — largest matching-ratio area, no scaling |
| `contain=WxH` | `Resize(:fit, W, H)` — fits inside, may be smaller, no letterbox |
| `inside=WxH` | `Resize(:fit, W, H)` **+** `Canvas(W, H, placement: center, fill: transparent)` — letterboxed to exact dims (see *inside fill* below) |
| `inside=W:H` (ratio) | **Rejected** (non-goal; see Deferred) |
| `crop=WxH` (Crop-size) | `CropGuided(W, H, guide: guide)`; omitted dim → `:full_axis` |
| `crop=WxH@XxY` | `CropRegion(x: X, y: Y, width: W, height: H)`; resets `guide`→center |
| `focus=<anchor>` | sets `guide` (anchor tuple); no op |
| `focus=<coords>` (px/percent/scale) | **Rejected** (v1; coordinate focus deferred — needs a runtime-resolved focal guide) |
| `focus=auto` / `focus=center` | **Rejected** (non-goals) |
| `output=auto \| fmt` | `Plan.Output` mode |
| `quality=1..100` | `Plan.Output` quality |

**`inside` fill (v1 limitation).** TwicPics `inside` adds *translucent* borders
and honours a `background` parameter. v1 supports the transparent fill only
(`background` is a non-goal). When the negotiated/explicit output format has no
alpha channel (e.g. `output=jpeg`), the transparent letterbox would flatten. v1
defines this explicitly: **`inside` with a non-alpha output flattens the
letterbox to the encoder's background** (documented, tested), rather than
silently producing an undefined colour. A user-specified `inside` background
arrives with the deferred `background` work. The support-matrix row for `inside`
is therefore "⚠️ Partial — transparent fill only."

The exact `cover=W:H` (guided ratio crop) result is pinned by a decoded-dimension
/ pixel test — it is the highest-uncertainty mapping.

### Why chaining is runtime-resolved, not statically collapsed

The parser emits one `Plan.Operation` per chain segment and lets execution
resolve relative units against running state. `resize=340/resize=50p` becomes two
`Resize` ops; at execution the first sets the image to 340 wide and the second
resolves `{:percent, 50}` against the running 340 → 170. Runtime resolution is
**always correct**, for every chain — including the ones that can never be
collapsed (a bare `resize=50p`, or anything after a `cover` of an unmeasured
source). It is the v1 baseline.

This also reproduces TwicPics' shadowing example for free: `resize=50p/resize=340`
runs both ops in order and yields 340 (the second resize makes the first
irrelevant), matching the docs without any optimizer.

Static collapse (rewriting `resize=340/resize=50p` into a single `resize=170`) is
a real but **separate, deferred optimization**, not a correctness requirement —
see *Deferred items*. It is sound only for a *subset* of chains and needs a
guard: both operands must be literal **and** the intermediate dimension must be
provably fixed. The naive precondition "all dimensions are literals" is *not*
enough — if TwicPics does not upscale by default (to be confirmed by pixel
tests), then with fit semantics on a source narrower than 340, `resize=340`
yields the source width, not 340, so `50p` of it is not 170. Collapsing also has
a modest *quality* upside (one reduction resamples once; two reductions resample
twice and are slightly softer), which is the motivation to do it eventually.
Emitting ordered ops and resolving at runtime keeps the parser dumb and ships
correct behaviour now.

## Product-neutral core change — full edit-site list

Supporting relative percent/scale units on resize is **additive but multi-site**,
not a single one-line widening. (An earlier draft understated this; the review
cycle surfaced the full set.) `resize` / `cover` / `contain` / `inside` all build
`ImagePipe.Plan.Operation.Resize`, so one *concept* — a relative resize dimension
— threads through several modules.

### Semantic / Plan layer (product-neutral)

1. **`ImagePipe.Plan.Operation.Resize`** (`plan/operation/resize.ex`) — widen
   `@type dimension :: :auto | {:px, pos_integer()}` to also allow
   `{:percent, number()}` and `{:scale, number()}`.
2. **`ImagePipe.Plan.Operation.tagged_resize_dimension/1`**
   (`plan/operation.ex:~493`) — add **validated** clauses for `{:percent, v}` and
   `{:scale, v}` (require `v > 0`; reject non-positive / non-numeric). This is a
   real boundary validator: the parser's output derives from host-controlled URL
   input. It also governs `valid_resize?` / `semantic?`, which reuse it. No
   parse-time *upper* bound — oversized results are owned by the post-decode
   result limits (see Request safety).
3. **`ImagePipe.Plan.KeyData`** (`plan/key_data.ex`) — extend
   `@type geometry_value` and add `data/1` clauses for `{:percent, _}` /
   `{:scale, _}`. **Required:** today the dimension `data/1` clauses cover only
   `:auto` / `:full_axis` / `{:px, _}` / `{:ratio, _, _}` / `{:effective, _}`, so
   a relative dimension would `FunctionClauseError` at cache-key construction.
   ("Flows automatically" was wrong.)

### Execution layer — chosen approach: carry the relative unit into the executable Resize, resolve centrally

4. **`ImagePipe.Transform.Operation.Resize`** (`transform/operation/resize.ex`) —
   widen its `@type dimension` and `normalize_bound_dimension/1` (~line 142) to
   accept `{:percent, _}` / `{:scale, _}` (otherwise `FunctionClauseError`).
5. **`ImagePipe.Transform.Operation.Resize.resolve_dimensions/2`** (~line 77) —
   at the head, resolve any relative width/height to pixels via
   `ImagePipe.Transform.Geometry.to_pixels(source_width_or_height, unit)`, using
   the `source_width` / `source_height` args. This is the single resolution
   point, and it is correct for **all three** call sites because each passes the
   *running* image dimensions: `Resize.execute/2` (resize.ex:~64),
   `cover_resize_and_crop/4` (plan_executor.ex:~258), and `resize_padding_scale/3`
   (plan_executor.ex:~366, run for *every* resize via `update_execution_context`).
6. **`ImagePipe.Transform.PlanExecutor.tagged_executable_resize_dimension/1`**
   (plan_executor.ex:~295) — widen to pass `{:percent, _}` / `{:scale, _}` through
   to the executable struct unchanged (resolution now happens in
   `resolve_dimensions`). `resize_from/2` and its callers then need no arity
   change.
7. **`:auto`-mode degeneracy (document, don't fix).** `tagged_logical_pixels/1`
   (plan_executor.ex:~456) returns `:unknown` for non-`{:px,_}` dims, so an
   `:auto`-mode resize with a relative dimension routes to the `:fit` branch.
   **The TwicPics parser never emits `:auto`** (the mapping routes to explicit
   `:fit` / `:cover` / `:stretch`), so no TwicPics URL exercises this. Document
   that `:auto` + relative is defined as `:fit` and is unreachable from this
   parser; do not add dead handling.

### Decode safety

8. **`ImagePipe.Transform.DecodePlanner.requested_resize_dimension?/1`**
   (`transform/decode_planner.ex:~81`) — relative units fall through to `false`,
   so a relative-unit resize classifies as **random access** (and any chain
   containing one resolves to random overall). This is the safe, conservative
   outcome, but it is currently implicit. Per CLAUDE.md's conservative-decode
   rule, **document the invariant** ("relative-unit resizes are never treated as
   sequential-access") and **add a DecodePlanner test** pinning that a
   relative-unit resize chain plans random access.

### Verified as needing no change

- Sequential running-dimension execution — `PlanExecutor.execute_pipeline/3`
  reduces operations against a `State` carrying the running image.
- `Geometry.to_pixels/2` already handles `{:percent, n}`, `{:scale, f}`,
  `{:scale, num, denom}` (geometry.ex:~22-27); arg order is `(length, unit)`.
- Ordered pipeline structure — `Plan.pipelines` / `Pipeline.operations`.
- **Crop/inside need no core change, and v1 keeps them pixel-only.** TwicPics
  `p` / `s` on `crop` *could* map to `{:ratio, n, d}` (already resolved by
  `crop_dimension → {:scale, n, d}` and covered by `KeyData` / `DecodePlanner`)
  entirely in the parser — but to keep v1 simple, **`crop` and `inside` accept
  pixel dimensions only** (`crop` also `:full_axis` for an omitted axis); relative
  units on crop/inside are deferred. v1 widens only the **Resize** dimension, and
  full relative-unit support lives on `resize` / `cover` / `contain`. Relative
  units on `min_*` / offsets / crop are a bounded follow-on.

Existing imgproxy callers construct only `:auto` / `{:px, n}` / `{:ratio, n, d}`
resize dims and are unaffected — every change above is purely additive.

## Output negotiation

Reuse `ImagePipe.Plan.Output`:

- `output=auto` → `:automatic` (Accept-negotiated, emits `Vary: Accept`).
- `output=avif|webp|jpeg|png` → `{:explicit, format}`, bypassing negotiation.
- `quality=1..100` → `Output.quality`.
- Repeated `output=` / `quality=` — last value wins (the accumulator overwrites).
- Non-image / non-`png/jpeg/webp/avif` output values → rejected (non-goal).

## Request safety

The Plug flow already enforces parse → validate → resolve-source ordering, so the
TwicPics parser returns a `parser`-level `{:error, …}` for malformed chains,
unknown transforms, and non-goal transforms **before** any source fetch or cache
access. Source fetching, redirect / timeout / body / content-type / pixel limits
are inherited unchanged.

**Relative units and result limits (not "no new safety surface").** `{:scale, f}`
and `{:percent, n}` are a genuinely new way to request a large result that
imgproxy callers could not express. They do **not** bypass any guard: result size
is enforced post-decode by `max_result_width` / `max_result_height` /
`max_result_pixels` in the request processor (these are intentionally post-fetch —
the prefetch validator cannot know running dimensions). The parser accepts
relative units without a parse-time upper bound (only `> 0` validation); the
existing result guard owns the ceiling. v1 adds a wire test that an oversized
chained upscale (e.g. `resize=4s/resize=4s`) is rejected by the result limit.

## Boundaries

- **Add `TwicPics` to the `ImagePipe.Parser` boundary `exports`** (currently
  `[Imgproxy]`).
- **`ImagePipe.Parser.TwicPics` boundary** `deps: [ImagePipe.Format,
  ImagePipe.Parser, ImagePipe.Plan]` — note this **includes `ImagePipe.Parser`**
  (the concrete parser depends on the behaviour it implements), matching how
  `ImagePipe.Parser.Imgproxy` is actually declared. The top-level
  `ImagePipe.Parser` boundary remains `[Format, Plan]`. ("parser → plan only" was
  imprecise; the concrete-parser dep set is `{parser, plan, format}`.)
- Internal submodules are not exported. Use the top-level `ImagePipe.Format`, not
  the private `ImagePipe.Parser.Imgproxy.Format` submodule.
- **`test/image_pipe/architecture_boundary_test.exs` requires explicit edits**
  (it is hard-coded, not glob-driven for boundary declarations): add the
  `ImagePipe.Parser.TwicPics => "lib/image_pipe/parser/twicpics.ex"` entry to its
  `@boundary_files` map, update the exact-match `ImagePipe.Parser` exports
  assertion to `[Imgproxy, TwicPics]`, and add `deps` / `exports` assertions for
  the TwicPics boundary. The **source-scanning** tests (parser code must not name
  concrete `Transform.Operation.*`) *are* glob-driven over
  `lib/image_pipe/parser/**`, so they enforce "emits `Plan.Operation.*`, names no
  concrete transform" for the new files automatically.

## Configuration & wiring

Hosts mount with:

```elixir
plug ImagePipe,
  parser: ImagePipe.Parser.TwicPics,
  twicpics: [ ... origin / source config ... ],
  source: ...,
  cache: ...
```

`ImagePipe.Parser.TwicPics.validate_options!/1` validates config with
`NimbleOptions`, **raises `ArgumentError` on bad config, and returns the validated
keyword list** (matching imgproxy's contract). **`lib/image_pipe/plug.ex` requires
an explicit edit**: its `validate_parser_options/2` dispatch is hard-coded per
parser, so add a `validate_parser_options(ImagePipe.Parser.TwicPics, opts)` clause
that calls `validate_options!/1` and re-puts the validated `:twicpics` opts —
otherwise a TwicPics mount falls through the catch-all and `validate_options!/1`
is never called at init.

## Demo

The `demo/` Svelte app must exercise the new behaviour end-to-end (CLAUDE.md).
However, the demo is currently imgproxy-hardwired with **no parser-mode
abstraction** — a single URL builder spanning `processing-path.ts`,
`demo-url-state.ts`, and `App.svelte`, plus an imgproxy-only dev-server route in
`dev/simple_server.ex`. Adding a TwicPics mode is a substantial, independent
TS/Svelte subsystem, so it is tracked as a **separate follow-on spec→plan cycle**
rather than bundled with the library parser. That plan introduces a mode selector
and a TwicPics URL builder covering, at minimum:

- `resize` single-dim and `WxH`,
- `cover` with a `focus` anchor (visually distinct crop steering),
- `contain` vs `inside` (letterbox),
- `output` and `quality`,
- a **chained relative-unit example** (e.g. `resize=340/resize=50p`) so the
  running-dimension behaviour is visible,

and is gated by `mise run precommit:demo` (`vitest`, `tsgo`/`svelte-check`,
`oxfmt`, `oxlint`, `vite build`).

## Test plan

- **Units** (`TwicPics.Units`): Length unit suffixes (px/p/s), Size vs Crop-size
  (`crop=320` → `:full_axis` height, *not* aspect auto), Ratio, Coordinates,
  the eight Anchors, mixed-unit `WxH`; malformed inputs and rejected forms
  (`resize=W:H`, `focus=center`, `focus=auto`) return tagged errors.
- **Manipulation**: `v1/` prefix required; ordered segment split; duplicate /
  trailing separators; missing `twic`.
- **PlanBuilder**: ordered chain → ordered `Plan.Operation.*` (assert on the
  emitted operations); `focus` statefulness (threaded into the next cover/crop,
  reset by `crop@coords`); `output` / `quality` last-wins; non-goal transforms
  rejected at the parser boundary.
- **Core**: `Operation.resize/4` accepts and validates `{:percent, v}` /
  `{:scale, v}` (`v > 0`; non-positive rejected); `KeyData.data/1` handles
  relative dims; a focused `resolve_dimensions/2` test resolving a relative
  dimension against a supplied running length; a `DecodePlanner` test pinning that
  a relative-unit resize chain plans **random** access.
- **Wire-level Plug** (representative, real `ImagePipe.call/2`, decode the body).
  Pin the source fixture and its dimensions in each geometry case so results
  aren't accidentally clamp-dependent:
  - **Headline running-dimension fidelity:** on a source known ≥ 340px wide,
    `resize=340/resize=50p` decodes to **170px**, *and* assert the intermediate
    340 is actually reached (not clamped). Add a **3-op** case
    (`resize=340/resize=50p/resize=50p` → 85px) so "running, not source" is
    genuinely demonstrated across more than one hop, plus a bare `resize=50p`
    case (which static collapse could never produce) as the strongest fidelity
    proof.
  - `cover=WxH` with a `focus` anchor on an off-centre source — pixel comparison
    against the centred baseline proves focus steers the crop.
  - `cover=W:H` (ratio) — decoded-dimension / pixel case (highest-uncertainty
    mapping).
  - `contain=WxH` vs `inside=WxH` — decoded dimensions differ, **and** assert the
    `inside` letterbox border is transparent (alpha-capable output); plus a
    pinned `inside` + `output=jpeg` case asserting the documented flatten
    behaviour.
  - `output=avif` bypasses negotiation; `output=auto` emits `Vary: Accept`.
  - Malformed / non-goal chain fails with a **`parser`-level error before source
    fetch** (assert no source / cache access — `refute_received` the origin/cache
    messages, per the imgproxy conformance pattern).
  - Oversized chained upscale (`resize=4s/resize=4s`) rejected by the post-decode
    result limit.
  - Two semantically-equivalent requests reuse the same cache entry.
- **Property** (StreamData): a **Geometry/resolver-layer** invariant, not a
  fixture round-trip — for any running length `W` and percent `N`,
  `resolve`/`Geometry.to_pixels(W, {:percent, N})` == `round(W * N / 100)`.
  (Routing it through a `resize=M/resize=Np` URL would be ill-formed under
  enlargement clamping, so assert at the resolver where the running length is
  supplied directly. Order-insensitivity is *not* a TwicPics property — the
  dialect is order-dependent by design.)

## Deliverables

1. `ImagePipe.Parser.TwicPics.*` modules (incl. `Path`, `Source`).
2. The additive multi-site core change (Plan.Operation.Resize, Operation
   validation, KeyData, executable Resize + resolve_dimensions, PlanExecutor
   pass-through, DecodePlanner invariant + test).
3. Boundary wiring **and** the explicit `architecture_boundary_test.exs` +
   `plug.ex` edits.
4. `docs/twicpics_support_matrix.md` (seeded; mirrors the imgproxy matrix).
5. Demo TwicPics mode — **deferred to a separate follow-on plan** (see Demo).
6. Tests as above.

## Deferred / future cross-cutting items

- **Arithmetic expression engine** — port the salvageable tokenizer/parser idea
  from the old parser when expressions are in scope; upgrade `Manipulation` to a
  paren-aware splitter at the same time.
- **`resize=W:H` / `inside=W:H` ratio forms** — TwicPics resize-to-ratio preserves
  surface area (pixel count) while changing aspect; it has no clean mapping to an
  existing operation and would need a new semantic. Rejected in v1; revisit with
  its own operation design.
- **`-min` / `-max` conditional variants**, `zoom`, `flip`, `turn`.
- **Color chaining** (`background`, `border`, `colorize`, color-blindness) — also
  unlocks a user-specified `inside` background (v1 is transparent-fill-only).
- **Coordinate focus** — `focus=<XxY>` in px/percent/scale. Needs a
  runtime-resolved focal guide on the core (the Plan focal guide is currently a
  0..1 ratio); mirrors the relative resize-unit machinery. v1 is anchor-only.
- **Demo TwicPics mode** — a mode selector + TwicPics URL builder in the `demo/`
  Svelte app; its own spec→plan cycle (the demo has no parser-mode abstraction).
- **Smart focus** — `focus=auto` (and imgproxy `g:sm`, currently rejected) could
  both be satisfied later by adding a `:smart` guide backed by libvips
  attention/entropy smartcrop. Single core addition lights up both dialects.
- **`focus=center`** as a lenient extension (TwicPics has no `center` anchor).
- **Multi-origin path configuration** (prefix → origin mapping).
- **Static chain collapse / shadowing** — a Plan-rewrite optimization pass that
  folds provably-safe runs of operations (e.g. `resize=340/resize=50p` →
  `resize=170`, or dropping a shadowed earlier `resize`) into fewer operations.
  Improves both performance and quality (avoids double resampling). **Guard:**
  only collapse when every operand is a literal *and* the intermediate dimension
  is provably fixed (enlargement allowed, or source dimensions known) — literal
  operands alone are not sufficient. Runtime resolution remains the correct
  fallback for everything the pass can't prove.

## Risks & open questions

- **Exact TwicPics resize / cover-ratio semantics.** `resize=WxH` is taken as
  distort-to-fit (force, confirmed against the docs); `cover=W:H` as a guided
  ratio crop without scaling (confirmed). Both are pinned by pixel tests.
- **Default enlargement.** TwicPics does not document a default upscaling policy
  for `resize` / `cover`; the static-collapse guard and the headline test both
  depend on the real behaviour, to be confirmed by pixel tests against pinned
  fixtures.
- **`inside` background.** v1 is transparent-fill-only with a documented flatten
  on non-alpha output; full background support is deferred with color chaining.
- **`focus=center` / `resize=ratio` rejections** may surprise users porting URLs;
  accepted for v1 fidelity, revisited as noted.
