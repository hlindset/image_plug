# IIIF tiles & sizes — deep-zoom viewer interop (Phase 4)

**Issue:** [#256](https://github.com/hlindset/image_pipe/issues/256) · **Blocked-on (done):** [#253](https://github.com/hlindset/image_pipe/issues/253) Phase 2 (merged in [#270](https://github.com/hlindset/image_pipe/pull/270))

## Goal

Make `ImagePipe.Parser.IIIF` a usable **IIIF image server for deep-zoom viewers** (OpenSeadragon, Mirador, Universal Viewer). Today's `info.json` omits `tiles`/`sizes`, so viewers fall back to naïve or no tiling. This phase:

1. Emits a `tiles` scheme and a `sizes` list in `info.json`, computed from source dimensions.
2. Verifies that the tiled `{region}/{size}/0/default.jpg` requests a real viewer fires are served correctly (pixel-verified).
3. Does a perf pass on the tile access pattern (shrink-on-load reuse) and documents caching follow-up.

## Scope decisions (from brainstorming)

- **Tiling config:** start with a single `tile_size` option (default **512** — OpenSeadragon/Cantaloupe norm); scale factors and `sizes` derived automatically. Granular config (tile_width/height, explicit scale_factors/sizes, minSize) is a tracked follow-up.
- **Viewer integration test:** an Elixir **viewer-simulation** gate (no browser). A real-OpenSeadragon demo page in the fiddle is a tracked follow-up (the fiddle has no IIIF demo yet).
- **Perf pass:** verify shrink-on-load reuse for the tile pattern and document; the memory high-water benchmark and info/derivative caching are tracked follow-ups.

## Background: what the algorithm must match

Ground truth (researched, citable):

- **IIIF Image API 3.0 spec** — `tiles[]` = `{type?: "Tile", width (req), height (opt, defaults to width), scaleFactors (req)}`; `sizes[]` = `{type?: "Size", width (req), height (req)}`. scaleFactors are "positive integers by which to divide the full size". The spec mandates no generation algorithm.
- **Cantaloupe** (`InformationFactory` / `ImageInfoUtil`, the dominant reference server) — defines the de-facto "usual way":
  - `scaleFactors`: power-of-2 `2^0 … 2^maxRF`. `maxRF` = number of halvings of the **short side** until it drops **below `minSize` (64px)**. (Loop: `d = min(W,H); for i: d /= 2; if d < 64 → maxRF = i`.)
  - `sizes`: one `{round(W/sf), round(H/sf)}` per scale factor (`Math.round`, half-up — *not* floor; verified `1500/16 → 94`. Elixir `round/1` rounds half **away from zero**, which for positive dimensions is identical to Java half-up — the `Tiling` module will carry a one-line note saying so), ordered **smallest-first, full-size last**.
  - `tiles`: one entry `{width: min(T,W), height: min(T,H), scaleFactors}` for an untiled source (both dims emitted). **Mechanism note:** Cantaloupe derives the tile dimension from a *separate* `minTileSize` (default 512) independent of any request, not from a single user knob; our design uses one `tile_size` knob (default 512) to set the advertised tile dim directly. The numbers coincide at the default, but the support-matrix doc must record this as a **divergence in mechanism**, not "matches Cantaloupe."
- **OpenSeadragon** (`iiiftilesource.js` `getTileUrl`) — for v3, requests `{id}/{region}/{size}/0/default.jpg` where:
  - `region` is in **full-image source coords**: `x = col·(tileW·sf)`, `y = row·(tileH·sf)`, `w/h` clamped to `imageW − x` / `imageH − y` (edge tiles request a smaller region, never overshoot). Uses `full` only when the tile *is* the whole image.
  - region origin uses a **rounded** intermediate, not a hand-simplified `tileW·sf`: `iiifTileSize = round(tileW / scale)` where `scale = 0.5^(maxLevel−level) = 1/sf`; `x = col·iiifTileSize`, `w = min(iiifTileSize, W − x)`. (For power-of-two `sf` + integer `tileW`, `round(tileW/scale) == tileW·sf` exactly — but the sim test must replicate the `round(tileW/scale)` step verbatim, not the simplification.)
  - `size` uses the **`w,h` form** (`max` only for exact full image), where `w = min(tileW, levelW − col·tileW)`, `levelW = ceil(W/sf)`. Never uses `!w,h`.
  - **Two whole-image branches.** (1) The single-tile branch fires whenever `levelW < tileW && levelH < tileH` (true for the *coarse* levels of a typical source — e.g. levels 0–2 of 1500×1200/512): region `full`, size `max` only if the level *is* full-res else the downscaled `w,h` (e.g. `full/375,300`). This `full` + downscaled-`w,h` shape is the **dominant** coarse-level request, not a rare case. (2) The tiled branch's `(0,0)` edge case where the single tile spans the whole image → also `full`.
  - `maxLevel = round(log2(max(scaleFactors)))`; OSD adopts `sizes` as `levelSizes` only if it passes **all** of: `len(sizes) == maxLevel+1`, `len(scaleFactors) == len(sizes)`, and for every level **both** `round(W/size.width) == sf` **and** `round(H/size.height) == sf` (scale-factor order inverted). If any check fails OSD silently falls back to `ceil(W·scale)` — still functional, but our sizes are then ignored. We verify adoption on representative fixtures (see Testing); it is *not* a universal property (see the property-test note).

The existing endpoint already supports `regionByPx` + `sizeByWh` (→ `:stretch`, exact dims), rotation `0`, `default.jpg` — i.e. **every request OSD fires is already serviceable**. Phase 4 adds info.json emission + verification; no request-path changes.

## Worked example

Source 1500×1200, `tile_size: 512`:

```json
"tiles": [{ "width": 512, "height": 512, "scaleFactors": [1, 2, 4, 8, 16] }],
"sizes": [
  { "width": 94,  "height": 75 },
  { "width": 188, "height": 150 },
  { "width": 375, "height": 300 },
  { "width": 750, "height": 600 },
  { "width": 1500,"height": 1200 }
]
```

(short side 1200 → 600,300,150,75,**37.5<64** at i=4 → maxRF=4; `1500/16 = 93.75 → round 94`.)

## Architecture

### Data flow (correction vs naïve placement)

`tiles`/`sizes` depend on **source pixel dimensions**, unknown at parse time (`PlanBuilder.info_plan/3` runs before any decode). They must be computed at **render** time from `SourceInfo`:

1. `IIIF.parse/2` (info branch) → `PlanBuilder.info_plan/3` adds `tile_size` to the `params` map (alongside the existing `id`, `level`, `offers`, `formats`, `qualities`). No dims here.
2. `RenderRunner.run/3` decodes the source header → builds `%SourceInfo{}` → calls `InfoRenderer.render(%RenderContext{info}, params, opts)`.
3. `Info.document/2` calls `Tiling.tiles_and_sizes(w, h, params.tile_size)` with `w,h = SourceInfo.display_dimensions(info)` (orientation-corrected), then maps the result onto the IIIF JSON string keys.

> While adding `tile_size`, fix the pre-existing drift in `info_plan/3`'s `@doc`, which references `max_width`/`max_height`/`max_area` opts that the `@schema` does not define.

### New unit: `ImagePipe.Parser.IIIF.Tiling`

Pure module (no I/O, no deps beyond stdlib). Lives under the `ImagePipe.Parser.IIIF.*` namespace → inside the existing IIIF parser boundary (`deps: [Format, Parser, Plan, Renderer]`), no boundary change. Returns **product-neutral atom-keyed** data; `Info.document/2` owns the IIIF JSON string-key vocabulary (so the math module stays dialect-agnostic and reusable by the configurable-tiling follow-up):

```elixir
@spec tiles_and_sizes(pos_integer(), pos_integer(), pos_integer()) ::
        %{
          scale_factors: [pos_integer(), ...],
          tile: %{width: pos_integer(), height: pos_integer()},
          sizes: [%{width: pos_integer(), height: pos_integer()}, ...]
        }
def tiles_and_sizes(width, height, tile_size)
```

- `scale_factors/2` → `[1, 2, …, 2^maxRF]` (private; `@min_size 64`; `round/1` for the ladder).
- `sizes/2` → smallest-first `[%{width: …, height: …}, …]`, `round/1` per dim, one per scale factor.
- `tile/3` → `%{width: min(T,W), height: min(T,H)}`.

`Info.document/2` stringifies: `"tiles" => [%{"width" => tile.width, "height" => tile.height, "scaleFactors" => scale_factors}]`, `"sizes" => Enum.map(sizes, &%{"width" => &1.width, "height" => &1.height})`.

**Why isolated:** one clear purpose (the pyramid math), unit-testable against Cantaloupe's exact numbers, keeps `Info.document/2` thin, and is the natural home when the follow-up adds configurable tiling.

### Config surface

`iiif.ex` `@schema` gains `tile_size: [type: :pos_integer, default: 512]`. Validated at `Plug.init/1` (existing `validate_options!/1`). No info.json conformance lie: `tile_size` only shapes the advertised tiling, which the endpoint genuinely serves.

### Info.document change

Insert `"tiles"` and `"sizes"` keys (spec root-level placement). `extraFeatures` unchanged — `regionByPx`/`sizeByWh` are already listed; `tiles`/`sizes` are core info.json properties, not feature flags.

## Edge cases

- **Source ≤ tile_size in a dim:** `tiles` width/height clamp to the source dim (e.g. 300×200 → tile `300×200`); OSD treats it as single-tile. Correct.
- **Tiny source (short side ≤ 64):** `maxRF = 0` → `scaleFactors [1]`, `sizes [{W,H}]`, one tile = full image.
- **Orientation:** use `display_dimensions/1` (EXIF 5–8 swap), consistent with the existing `width`/`height` emission.
- **Edge tiles (right/bottom):** clamped region + rounded-up size; the endpoint's `sizeByWh` (`:stretch`) returns exact requested dims.

## Testing

### `Tiling` unit + property tests (`test/parser/iiif/tiling_test.exs`)
- **Pin Cantaloupe reference values:** `1500×1200/512 → scale_factors [1,2,4,8,16]`, `sizes [94×75,188×150,375×300,750×600,1500×1200]` (proves `round`, not floor/ceil — `1500/16=93.75→94`, floor would give 93), `tile 512×512`.
- **Edge examples:** `300×200/512` (tile clamps to `300×200`, sf `[1,2]`), `64×64/512` (sf `[1]`), `1×1/512` (sf `[1]`, one size `1×1`), and an extreme aspect (`2000×65` → short side 65 → sf `[1]`).
- **Property (StreamData over W,H,T, bounded `max_runs` ~100–200 — pure math, no I/O):** the *safe* invariants only —
  - `scale_factors` are powers of two, strictly increasing, starting at 1;
  - `len(sizes) == len(scale_factors)` **and** the emitted `tiles[0].scaleFactors` equals the standalone `scale_factors` list;
  - `sizes` is strictly **ascending by width** (safe: `sf` strictly decreases ⇒ `round(W/sf)` strictly increases for `W ≥ 1`); do **not** assert strict-ascending on height (adjacent levels can tie for tiny `H`);
  - largest size `== {W, H}` (because `sf=1`);
  - `tile.width == min(T,W)`, `tile.height == min(T,H)`;
  - each `sizes[i] == {round(W/sf_i), round(H/sf_i)}`.
  - **Do NOT** assert the `round(W/size.width) == sf` round-trip as a universal property — it is **false** for some valid inputs (e.g. round-then-inverse-round can land on `sf±1`), and OSD treats `sizes` as an optional hint that it falls back from gracefully. (Adoption is verified on fixtures below, not as a property.)
- **Tautology self-check (mandated by the repo's equivalence-test discipline, cf. `sequential_access_test.exs`):** assert that a deliberately **floor**-computed sizes list (and a wrong scale-factor ladder) is **rejected** by the same predicates the property uses — proving the invariants can actually fail, so a passing property isn't vacuous.
- **No guard-rejection tests:** `Tiling` is only ever called with `pos_integer` dims (producer: `SourceInfo`) and a `:pos_integer`-validated `tile_size`. Per the validation guidelines, do not add tests that `Tiling` rejects 0/negative input — that would be an impossible-misuse test.

### OSD `levelSizes` adoption — fixture assertion (in `tiling_test.exs`)
Assert that for the representative sources (e.g. 1500×1200/512, and one orientation-swapped source) the emitted `sizes` pass OSD's *full* adoption check: `len(sizes) == maxLevel+1`, `len(scaleFactors) == len(sizes)`, and for every level **both** `round(W/size.width) == sf` and `round(H/size.height) == sf`. Document that typical sources are adopted; pathological aspect ratios fall back to OSD's computed `ceil(W·scale)` and still render.

### Wire test — info.json (`test/parser/iiif_wire_test.exs`)
- Extend the existing info.json contract test: assert `tiles`/`sizes` present, well-formed, and match the computed values for the fixture source.
- Assert a **non-default `tile_size`** config flows through to the emitted `tiles[0].width`.
- **Orientation:** assert that an EXIF 5–8 source computes `tiles`/`sizes` from the *swapped* (display) dims — the existing suite already covers the analogous `width`/`height` swap.

### Viewer-simulation gate (`test/parser/iiif/openseadragon_sim_test.exs`)
The deterministic stand-in for "a real viewer". **The OSD-replica is the *stimulus generator*; an independent crop-then-resize is the *oracle* — they must not share code.**
1. `GET …/info.json` through `ImagePipe.call/2`; parse `tiles`/`sizes`/`width`/`height`.
2. Replicate OSD's `getTileUrl` **verbatim** (documented inline in the test), including the `iiifTileSize = round(tileW/scale)` region step, `levelW = ceil(W/sf)`, edge clamping (`min(tileSize, W−x)`) and round-up size, and OSD's `levelSizes` adoption decision. Cover **both** branches explicitly:
   - the **single-tile** branch `levelW < tileW && levelH < tileH` (coarse levels) → asserts `region=full` + a downscaled `w,h` size (e.g. `full/375,300`) **or** `max` when the level is full-res — this is the *dominant coarse-level shape* and must be a named assertion, not just one grid iteration;
   - the **tiled** branch → `x,y,w,h` regions with clamped edges.
3. Fire requests through `ImagePipe.call/2`; assert `200` + decoded pixel dims == requested `size`. **Cost control:** walk the *full* `cols×rows` grid (status + dims only) at just **one or two** scale factors; reserve heavyweight pixel decode for the representative tiles in step 4.
4. **Pixel oracle (independent, representative, not exhaustive):** for an **interior** tile, a **right-edge** tile, a **bottom-edge** tile, and the **bottom-right corner** tile (both-axis clamp), at a low and a high scale factor — decode the served body and compare against a baseline produced by an **independent** crop-then-resize of the source (direct `Image.crop`/`Image.thumbnail`/libvips primitives in the test — **not** `ImagePipe.call/2` or the IIIF region/size planner, or the test would agree with itself). Use the existing `decoded_image/1` + `get_pixel!` sampling style. Assert the edge/corner tiles' decoded dims are the **clamped** value, not the full `tile_size`.

This proves the full info.json → viewer-request → served-tile loop without a browser. A real-OSD page is a follow-up. (Content negotiation is unaffected — the existing `Accept`/`Vary` info.json contracts already cover it; no new negotiation test.)

### Tests deliberately *not* written
Per project test guidelines: no impossible-internal-misuse tests (incl. no `Tiling` guard-rejection), no module-existence/exports policing, no characterization pins, no private-implementation-string tests. `Tiling` is exercised through its real callers (`Info.document` + the wire/sim tests) and its own unit/property tests.

## Perf pass

Tile workloads = many small region+downscale requests against one large source. Investigate and **document honestly** (mirroring the "no materialization" discipline — a correctness-verified, perf-*characterized*-as-found claim, not an unmeasured guarantee):

1. Read `ImagePipe.Transform.DecodePlanner` + `Chain` to determine whether a high-scaleFactor tile (region crop + downscale) engages shrink-on-load.
2. **Test the producer directly, not a telemetry hook.** `DecodePlanner.open_options/5` is a pure function returning the decode load keyword list (with `:shrink`/`:scale` when shrink-on-load fires; consumed at `request/processor.ex:81`). There is **no** telemetry event carrying this decision, and inventing one solely so a test can observe a private decode choice would violate the telemetry contract + "no private-implementation tests" guidelines. Instead, call `open_options/5` with an IIIF tile-shaped chain (a `%CropRegion{}` + a downscaling `%Resize{}` at a deep scale factor) and assert the returned options — pinning the **actual** behavior, whatever it is today.
3. If shrink-on-load **does** engage, the test asserts the expected `:shrink`/`:scale`. If it does **not** for region+resize, the test asserts the current (no-shrink) options and the docs say so plainly — the optimization then becomes the perf follow-up, not a silent efficiency claim.
4. Document findings in the support matrix + the issue; file the info/derivative caching + memory high-water benchmark (the true end-to-end perf signal) as a follow-up.

## Docs

`docs/iiif_3_support_matrix.md`:
- **Surface:** new "Tiling (`tiles` / `sizes`)" subsection under info.json — the algorithm (Cantaloupe-faithful scaleFactors stop rule + `round` sizes), `tile_size` config, worked example, **and the deliberate mechanism divergence**: a single `tile_size` knob sets the advertised tile dim directly, whereas Cantaloupe derives it from a separate request-independent `minTileSize`; numbers coincide at the 512 default. Note `round/1` matches Java half-up for positive dims, and that the IIIF implementation-notes edge round-up (`+s-1`) is an equivalent formulation of OSD's edge math for power-of-two scale factors (the sim test follows OSD, the binding client).
- **Stage/order:** a note in the pipeline/HTTP section that tiled region+size requests reuse the existing region-crop + shrink-on-load path (no IIIF-specific stage).
- **Behavioral/pixel:** viewer-sim gate under Verification.

## Follow-up issues to file

1. **Configurable IIIF tiling** — `tile_width`/`tile_height`, explicit `scale_factors`/`sizes`, configurable `minSize`; the Tiling module already isolates the math.
2. **Fiddle OpenSeadragon demo + headless pan/zoom check** — a real-viewer page in the fiddle, optional Playwright gate.
3. **IIIF info-response / derivative caching + tile-pattern memory high-water benchmark** — turn the deferred perf claim into a measured one.

## Out of scope

Arbitrary rotation, mirroring, bitonal-as-feature, extra output formats (Phase 5 `extraFeatures`). Caching beyond what the perf pass requires.
