# TwicPics-compatible parser — design

- **Status:** Approved (brainstorming) — ready for implementation planning
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
directly with no Plan. It was removed when the native (now imgproxy-compatible) path API landed. We are
**not** porting it wholesale. We keep its lessons (a clean units grammar, a
paren-aware key/value splitter, position-tracked error reporting) and rewrite the
transform mapping against today's `Plan.Operation.*` constructors.

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
force them into the imgproxy parser's order-insensitive contract. The Plan only
gains the ability to carry a *relative dimension unit* — product-neutral data,
not an ordered-command contract.

## Goals (v1)

Support the core geometry + output surface, faithfully including
running-dimension chaining:

- Transforms: `resize`, `cover`, `contain`, `inside`, `crop`, `focus`, `output`, `quality`.
- Units: pixels (bare or `px`), percent (`p`), scale (`s`), ratio (`W:H`),
  coordinates (`XxY`), anchors (`center`, `top`, `bottom`, `left`, `right`,
  `top-left`, `top-right`, `bottom-left`, `bottom-right`).
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
- `zoom`, `flip`, `turn`.
- `background`, `border`, `colorize`, color-blindness corrections (color chaining).
- `focus=auto` (smart / content-aware subject detection — see below).
- Video transforms (`duration`, `from`, `to`, video output codecs).
- Placeholders API, `refit-*`, `truecolor`, `download`, `noop`.
- Non-image output values (`blurhash`, `preview`, `maincolor`, `meancolor`,
  `blank`, `heif`).

Each non-goal is **recognized** by the parser and returns a validation error
*before* any source fetch or cache access. ImagePipe does not silently ignore
unsupported syntax.

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

- **Source.** `conn.path_info` (the path to the media) resolves to a
  `ImagePipe.Plan.Source` using the **same host-configured origin mechanism the
  imgproxy parser uses for its path source** — no TwicPics-specific source
  semantics in v1. Multi-origin TwicPics "path configuration" prefix→origin
  mapping is out of scope for v1.
- **Transforms.** Read the `twic` query parameter (it may appear anywhere in the
  query string), require the `v1/` prefix, then split the remainder into an
  **ordered** list of `name=args` segments.

### Module layout

All under `ImagePipe.Parser.TwicPics.*`, mirroring the imgproxy parser's layering
(`parser → plan` only):

| Module | Responsibility |
| --- | --- |
| `TwicPics` | `@behaviour ImagePipe.Parser`. `parse/2`, `handle_error/2`, `validate_options!/1`. Extract path→source, extract `twic`→chain, drive the builder. |
| `TwicPics.Manipulation` | Split `v1/…` into an ordered `[{name, raw_args}]`. v1 uses a plain `/` split (no parens yet). When arithmetic lands, this becomes a paren-aware splitter (the salvageable idea from the old `kv_parser`). |
| `TwicPics.Units` | Parse Length / Size / Ratio / Coordinates / Anchor into product-neutral tagged values: `{:px, n}`, `{:percent, n}`, `{:scale, f}`, `{:ratio, n, d}`, and Plan guide tuples. |
| `TwicPics.PlanBuilder` | Fold the ordered chain into an accumulator and emit `{:ok, Plan.t()} \| {:error, term()}` via `ImagePipe.Plan.Operation.*` constructors. |
| `TwicPics.Output` | Map `output=` and `quality=` onto `ImagePipe.Plan.Output`. |

### Units grammar (v1)

- **Length** = `<number>` (pixels), `<number>px` (pixels), `<number>p` (percent),
  `<number>s` (scale). `number` is a decimal literal in v1 (no expressions).
- **Size** = `WxH`, where each of `W`/`H` is a Length or `-` (auto). A single
  Length with no `x` sets width with auto height.
- **Ratio** = `<num>:<num>` (two strictly-positive numbers) → `{:ratio, n, d}`.
- **Coordinates** = `XxY`, two Lengths → focus point.
- **Anchor** = one of the nine named positions → a Plan guide.

### Chain → Plan mapping (the core behaviour)

`PlanBuilder` folds left-to-right over the chain, carrying an accumulator:

- `ops` — the ordered list of `Plan.Operation.*` produced so far,
- `guide` — the current focus guide (default `:center`),
- pending `output` / `quality`.

`focus` produces **no operation**; it updates `guide`, which the *next*
`cover` / `crop` consumes. `crop=…@coords` resets `guide` to center (TwicPics
behaviour). Ordered execution falls out of the ordered `ops` list and the
already-sequential `ImagePipe.Transform.PlanExecutor`.

| TwicPics | → Plan operation(s) |
| --- | --- |
| `resize=W` (single dim) | `Resize(:fit, W, :auto)` — scale preserving aspect |
| `resize=WxH` | `Resize(:stretch, W, H)` — exact dims, may distort (= imgproxy `force`) |
| `cover=WxH` | `Resize(:cover, W, H, guide: guide)` — fill + crop to focus |
| `cover=W:H` (ratio) | `CropGuided(:full_axis, :full_axis, aspect_ratio: {:ratio, …}, guide: guide)` — largest matching-ratio area, no scaling |
| `contain=WxH` | `Resize(:fit, W, H)` — fits inside, may be smaller, no letterbox |
| `inside=WxH` | `Resize(:fit, W, H)` **+** `Canvas(W, H, placement: center, fill: transparent)` — letterboxed to exact dims |
| `crop=WxH` | `CropGuided(W, H, guide: guide)` |
| `crop=WxH@XxY` | `CropRegion(x: X, y: Y, width: W, height: H)`; resets `guide`→center |
| `focus=coords \| anchor` | sets `guide` (`{:focal, x, y}` or anchor tuple); no op |
| `output=auto \| fmt` | `Plan.Output` mode |
| `quality=1..100` | `Plan.Output` quality |

Exact resize-with-ratio and cover-ratio semantics are pinned by parser + pixel
tests against the TwicPics docs rather than assumed.

### Why chaining is runtime-resolved, not statically collapsed

The parser emits one `Plan.Operation` per chain segment and lets execution
resolve relative units against running state. `resize=340/resize=50p` becomes two
`Resize` ops; at execution the first sets the image to 340 wide and the second
resolves `{:percent, 50}` against the running 340 → 170. Runtime resolution is
**always correct**, for every chain — including the ones that can never be
collapsed (a bare `resize=50p`, or anything after a `cover` of an unmeasured
source). It is the v1 baseline.

Static collapse (rewriting `resize=340/resize=50p` into a single `resize=170`) is
a real but **separate, deferred optimization**, not a correctness requirement —
see *Deferred items*. It is sound only for a *subset* of chains and needs a
guard: both operands must be literal **and** the intermediate dimension must be
provably fixed. The naive precondition "all dimensions are literals" is *not*
enough — with fit semantics and no enlargement on a source narrower than 340,
`resize=340` yields the source width, not 340, so `50p` of it is not 170.
Collapsing also has a modest *quality* upside (one reduction resamples once;
two reductions resample twice and are slightly softer), which is the motivation
to do it eventually. Emitting ordered ops and resolving at runtime keeps the
parser dumb and ships correct behaviour now; the optimizer can fold provably-safe
runs later.

## Product-neutral core change (small, additive)

Because `resize` / `cover` / `contain` / `inside` all build
`ImagePipe.Plan.Operation.Resize`, one type-widening covers them all:

1. **`ImagePipe.Plan.Operation.Resize`** — widen
   `@type dimension :: :auto | {:px, pos_integer()}` to also allow
   `{:percent, number()}` and `{:scale, number()}`.
2. **`ImagePipe.Plan.Operation.tagged_resize_dimension/1`**
   (`lib/image_pipe/plan/operation.ex`, ~line 493) — add `{:ok, …}` clauses for
   `{:percent, v}` and `{:scale, v}`.
3. **`ImagePipe.Transform.PlanExecutor`** — where it currently tags resize
   dimensions for execution (`tagged_executable_resize_dimension/1`,
   `lib/image_pipe/transform/plan_executor.ex`, ~line 295, which only matches
   `:auto` / `{:px, v}`), resolve relative dimensions against the **running**
   `State` image via `ImagePipe.Transform.Geometry.to_pixels/2`, threading the
   per-axis running length (width for width, height for height). Equivalent
   alternative: carry the relative unit into the executable
   `Transform.Operation.Resize` and resolve inside `resolve_dimensions/2`, which
   already receives `source_width` / `source_height`.

What already exists and needs **no** change:

- Sequential running-dimension execution — `PlanExecutor.execute_pipeline/3`
  reduces operations against a `State` that carries the running image.
- Percent / scale arithmetic — `Geometry.to_pixels/2` already handles
  `{:percent, n}`, `{:scale, f}`, `{:scale, num, denom}`.
- Ordered pipeline structure — `Plan.pipelines` / `Pipeline.operations`.
- Cache-key inclusion — relative dims flow through canonical plan fields
  automatically.

Existing imgproxy callers construct only `:auto` / `{:px, n}` dimensions and are
unaffected — the change is purely additive.

**Crop needs no core change.** TwicPics `p` / `s` on `crop` map to
`{:ratio, n, d}`, which `PlanExecutor` already resolves against the running image
(`crop_dimension → {:scale, n, d}`). v1 only widens the **Resize** dimension.
Whether `min_*`, offsets, or crop coordinates should also accept relative units
is a bounded follow-on, not a v1 blocker.

## Output negotiation

Reuse `ImagePipe.Plan.Output`:

- `output=auto` → `:automatic` (Accept-negotiated, emits `Vary: Accept`).
- `output=avif|webp|jpeg|png` → `{:explicit, format}`, bypassing negotiation.
- `quality=1..100` → `Output.quality`.
- Non-image output values (`blurhash`, `preview`, etc.) → rejected (non-goal).

## Request safety

No new safety surface. The Plug flow already enforces parse → validate → resolve
ordering, so the TwicPics parser returns `{:error, …}` for malformed chains,
unknown transforms, and non-goal transforms **before** any source fetch or cache
access. Source fetching, redirect / timeout / body / content-type / pixel limits
are inherited unchanged.

## Boundaries

- Add `TwicPics` to the `ImagePipe.Parser` boundary `exports`.
- `ImagePipe.Parser.TwicPics` boundary `deps: [ImagePipe.Plan, ImagePipe.Format]`
  (parser → plan only), matching imgproxy. Internal submodules are not exported.
- Architecture test (`test/image_pipe/architecture_boundary_test.exs`): the
  TwicPics parser emits semantic `Plan.Operation.*` and names **no** concrete
  `Transform.Operation.*` module, and references no parser-internal structs from
  outside the parser layer.

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
`NimbleOptions`, reusing the imgproxy origin-config shape where it maps cleanly.
The Plug `init/1` validates parser options before any request is served.

## Demo

Per CLAUDE.md, the `demo/` Svelte app must exercise the new behaviour
end-to-end. Add a TwicPics mode (controls + URL state) that builds `?twic=v1/…`
URLs for the v1 transform set, including a chained relative-unit example so the
running-dimension behaviour is visible in the demo.

## Test plan

- **Units** (`TwicPics.Units`): Length unit suffixes (px/p/s), Size with `-`
  auto, Ratio, Coordinates, Anchor; malformed inputs return tagged errors.
- **Manipulation**: `v1/` prefix required; ordered segment split; duplicate /
  trailing separators; missing `twic`.
- **PlanBuilder**: ordered chain → ordered `Plan.Operation.*` (assert on the
  emitted operations); `focus` statefulness (threaded into the next cover/crop,
  reset by `crop@coords`); `output` / `quality`; non-goal transforms rejected.
- **Core**: `Operation.resize/4` accepts `{:percent, n}` / `{:scale, f}`;
  `PlanExecutor` resolves relative resize dims against the running image
  (focused unit test on the resolution step).
- **Wire-level Plug** (representative, real `ImagePipe.call/2`, decode the body):
  - **Headline:** `resize=340/resize=50p` decodes to **170px** wide — proves
    runtime running-dimension resolution.
  - `cover=WxH` with a `focus=` anchor — pixel comparison against a centered
    baseline to prove focus steers the crop.
  - `contain=WxH` vs `inside=WxH` — decoded dimensions differ (letterbox).
  - `output=avif` bypasses negotiation; `output=auto` emits `Vary: Accept`.
  - Malformed / non-goal chain fails **before** source fetch (assert no source
    access).
  - Two semantically-equivalent requests reuse the same cache entry.
- **Property** (StreamData): relative-unit chaining equivalence — for known M, N,
  `resize=M/resize=Np` yields `round(M * N / 100)`. (Note: order-insensitivity is
  *not* a TwicPics property — the dialect is order-dependent by design.)

## Deliverables

1. `ImagePipe.Parser.TwicPics.*` modules.
2. The additive `Plan.Operation.Resize` / `Operation` / `PlanExecutor` core change.
3. Boundary wiring + architecture test.
4. `docs/twicpics_support_matrix.md` (seeded; mirrors the imgproxy matrix).
5. Demo TwicPics mode.
6. Tests as above.

## Deferred / future cross-cutting items

- **Arithmetic expression engine** — port the salvageable tokenizer/parser idea
  from the old parser when expressions are in scope; upgrade `Manipulation` to a
  paren-aware splitter at the same time.
- **`-min` / `-max` conditional variants**, `zoom`, `flip`, `turn`.
- **Color chaining** (`background`, `border`, `colorize`, color-blindness).
- **Smart focus** — `focus=auto` (and imgproxy `g:sm`, currently rejected) could
  both be satisfied later by adding a `:smart` guide backed by libvips
  attention/entropy smartcrop. Single core addition lights up both dialects.
- **Multi-origin path configuration** (prefix → origin mapping).
- **Static chain collapse / shadowing** — a Plan-rewrite optimization pass that
  folds provably-safe runs of operations (e.g. `resize=340/resize=50p` →
  `resize=170`, or dropping a shadowed earlier `resize`) into fewer operations.
  Improves both performance and quality (avoids double resampling). **Guard:**
  only collapse when every operand is a literal *and* the intermediate dimension
  is provably fixed (enlargement allowed, or source dimensions known) — literal
  operands alone are not sufficient (fit + no-enlarge on a small source makes the
  intermediate source-dependent). Runtime resolution remains the correct
  fallback for everything the pass can't prove.

## Risks & open questions

- **Exact TwicPics resize/cover-ratio semantics.** `resize=WxH` is taken as
  distort-to-fit (force); `cover=W:H` as a guided ratio crop without scaling.
  Both are pinned by pixel tests against the docs during implementation; adjust
  the mapping if the docs disagree.
- **`focus=auto` rejection ergonomics.** Auto is TwicPics' *default* focus and
  common in the wild; rejecting it may surprise users porting URLs. Acceptable
  for v1 (consistent with `g:sm`), revisited with smart focus.
- **Relative units beyond resize.** Deliberately scoped out of v1; revisit if
  real URLs need relative `min_*` / offsets.
