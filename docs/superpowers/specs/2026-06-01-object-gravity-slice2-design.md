# Object-oriented gravity — Slice 2 (`objw` per-class weights): design

**Status:** reviewed design, ready for implementation planning. Revised after a
parallel four-reviewer pass (architecture/boundaries, weight math/canonicalization,
imgproxy parser compat, cache-key/test-strategy) — accepted feedback folded in:
complete reshape-site list, single-home canonicalization fixed point, weights-map
serialization determinism, variable-arity parser path, and expanded test plan.

**Depends on:** Slice 1 (general object gravity) — landed in `240d11a`
("General object gravity (Slice 1): multi-class `g:obj` via a Composite
detector"). Slice 2 is purely additive on top of Slice 1's Composite/routing and
`{:detect, …}` guide; it requires no rework of Slice 1.

**Supersedes:** the pre-spec notes in
`docs/superpowers/specs/2026-05-31-object-gravity-slice2-notes.md`. Those notes
captured the scoping thinking; this document is the reviewed design. Where they
differ, this document wins — notably the guide shape (a sparse, normalized weight
map keyed by `:default`) and the decision to commit `weight·√area` without a
dev-only formula toggle.

## Scope

Add imgproxy's per-class object weighting to object gravity:

- `gravity:objw:%class1:%weight1:…:%classN:%weightN` — per-class weights, in both
  the `g:` (gravity) and `c:W:H:` (crop) forms, consistent with Slice 1's dual
  `resize_guide` / `tagged_gravity` mapping.
- The `all` pseudo-class as a **baseline/default** weight, e.g.
  `objw:all:2:face:3` = "every detected class weight 2, faces overridden to 3".
- Default weight is `1` (matches imgproxy).

**Out of scope:** `objects_position` and any further imgproxy object-gravity
surface beyond `obj` / `objw`.

### `obj` and `objw` both filter; `all` broadens

> **Correction (2026-06-01):** The original "always detect-all" reading of
> imgproxy's `objw` was wrong. imgproxy describes `objw` as "the same as
> `gravity:obj` but with custom weights". Both `obj` and `objw` use their named
> classes as a detection filter (the spec). The `all` pseudo-class is what
> broadens detection to every object. The design below has been corrected
> accordingly.

This distinction drives the whole design. In Slice 1, `obj:face` does two jobs:
it **filters** detection to the `face` class *and* targets the crop. imgproxy's
`objw` works the same way: `objw:face:3` filters to faces (spec `["face"]`) and
applies a weight. The `all` pseudo-class is what broadens detection to everything
— `objw:all:1:face:3` means "detect *everything*, weight faces 3×".

Consequence: **"what to detect" (the spec) and "how to weight each class" (the
weights) are orthogonal axes.** `objw` derives its spec from the named classes
exactly as `obj` does; `all` collapses the spec to `:all`. Named non-`all`
classes populate both the spec and the weight map. Multi-element spec lists arise
from either `obj:person:face` or `objw:person:2:face:3` (no `all` present).

## Plan guide shape

The detect guide carries weights as a nested tuple, keeping the outer
`{:detect, _}` arity stable so sites that only ask "is this a detect guide?" do
not change:

```elixir
{:detect, {spec, weights}}

spec    :: :all | nonempty_list(String.t())          # unchanged from Slice 1
weights :: %{optional(:default) => number(), optional(String.t()) => number()}
```

### Weight map: sparse and canonical

- **Empty map = uniform.** Every Slice 1 guide migrates mechanically to
  `{:detect, {spec, %{}}}` (all weights 1).
- `:default` (atom key) is present only when the baseline is moved off 1 (i.e. the
  user wrote `all:N`, `N ≠ 1`). Class names are string keys, present only when the
  class weight differs from the **effective default**. The `:default` atom cannot
  collide with a hypothetical class literally named `"default"` (string key).
- A per-class entry equal to the effective default is dropped (trivial
  canonicalization so equivalent URLs converge).

We do **not** normalize across the default (no dividing class weights through by
the default to force `:default => 1`). We keep the numbers the user typed. A
uniform global weight scalar is mathematically inert in the centroid — it cancels
from numerator and denominator — so `objw:all:6:car:2` and `objw:all:3:car:1`
produce the *same crop* but *different* cache keys. That minor key redundancy is
accepted in exchange for faithful, integer-friendly values and honest telemetry.

#### Canonicalization algorithm (single home, fixed order)

The drop rules are order-sensitive ("effective default" depends on whether
`:default` is still present), so the algorithm is pinned exactly, computed in
**one place** — the parser/plan builder is the **sole** canonicalizer:

1. Let `eff = weights[:default] || 1`.
2. Drop every class entry whose value equals `eff`.
3. Drop `:default` iff `eff == 1`.

The result is idempotent and total. **`key_data` does not re-canonicalize** — it
serializes the already-canonical map (sorting only). An implementation property
test asserts (a) idempotence and (b) that `key_data` serialization is a no-op on
canonicalization given canonical input, so the parser and cache layers cannot
drift. This converts canonicalization soundness from "holds if both layers agree"
to "holds by construction."

**Why this is cache-safe.** The crop is a pure function of the weight-resolution
function `w(label) = Map.get(weights, label, Map.get(weights, :default, 1))`. Both
drop rules only remove entries that are *already redundant under that exact
resolution*, so the canonical map resolves every label identically to the
pre-canonical map. Therefore *same canonical map ⟹ identical `w(label)` for every
label ⟹ identical crop* — there is no "different pixels, same key" collapse. The
only redundancy is the benign direction (same crop, different key), e.g.
`objw:all:6:car:2` vs `objw:all:3:car:1`, or a weight named for a class no detector
emits (`objw:all:1:unicorn:5` ≡ `obj:all` in pixels but keyed distinctly — expected,
not a bug; the vocabulary-free parser cannot reject unknown classes).

### Grammar → guide mapping

| URL gravity          | `spec`               | `weights`                      |
| -------------------- | -------------------- | ------------------------------ |
| `obj` / `obj:all`    | `:all`               | `%{}`                          |
| `obj:face`           | `["face"]`           | `%{}`                          |
| `obj:person:face`    | `["person", "face"]` | `%{}`                          |
| `objw:face:3`        | `["face"]`           | `%{"face" => 3}`               |
| `objw:face:1`        | `["face"]`           | `%{}` (≡ `obj:face`)           |
| `objw:person:2:face:3` | `["person", "face"]` | `%{"person" => 2, "face" => 3}` |
| `objw:all:1:face:3`  | `:all`               | `%{"face" => 3}`               |
| `objw:all:2`         | `:all`               | `%{default: 2}`                |
| `objw:all:3:car:1`   | `:all`               | `%{default: 3, "car" => 1}`    |
| `objw:all:3:car:3`   | `:all`               | `%{default: 3}`                |
| `objw` (no pairs)    | —                    | **parse error** (reject)       |

**Key consequence of the filtering model:** `objw:face:3` (spec `["face"]`) and
`objw:all:1:face:3` (spec `:all`) are **NOT equivalent** — the first gates
detection to faces only; the second detects everything with a face boost. The
only weight-only equivalence (same spec *and* same effective weights) is
`objw:face:1` ≡ `obj:face`.

`objw:all:2` (baseline-only) is uniform-at-2, the same crop as `obj:all` but a
distinct key.

### How weights reach the centroid (carrier)

The executable `Crop` struct has **no weights field today**, and we add none. The
detect guide already rides on the executable `gravity` field as `{:detect, spec}`
([crop.ex:150](../../../lib/image_pipe/transform/operation/crop.ex)); we extend it
to `{:detect, {spec, weights}}`. `execute/2` destructures `weights` at the detect
path and passes it to `focal_from_regions`, *then* rewrites `gravity` to the
computed `{:fp, x, y}` focal point (as today). Weights are consumed before gravity
is overwritten, so no struct field is needed — weights flow exactly where `spec`
already flows.

### Reshape in place (greenfield) — complete site list

The guide shape changes from `{:detect, spec}` to `{:detect, {spec, weights}}`,
which touches **every** producer, validator, unwrapper, and consumer of the detect
guide. The full set (verified against the landed Slice 1 code):

- **Typespecs:** `lib/image_pipe/plan/operation/crop_guided.ex`, `resize.ex`, and
  the executable `lib/image_pipe/transform/operation/crop.ex` gravity typespec
  (~`:127`).
- **Guide validator:** `lib/image_pipe/plan/operation.ex` — `smart_guide/1`
  (~`:679–690`) validates the guide at construction; its `{:detect, :all}` /
  `{:detect, classes}` clauses must accept the nested tuple, else every `obj`/`objw`
  request fails construction with `{:error, :guide}`.
- **Parser/plan builder:** `lib/image_pipe/parser/imgproxy/plan_builder.ex` —
  `object_detect_guide/2` (was `/1`) takes classes **and** weights and emits the
  canonical `{:detect, {spec, weights}}`; shared by `resize_guide` (fill) and
  `tagged_gravity` (crop) so the paths cannot diverge. This module is the **sole
  canonicalizer** (see Canonicalization algorithm).
- **Guide unwrapper:** `lib/image_pipe/transform/plan_executor.ex` —
  `tagged_executable_gravity({:detect, …})` (~`:466`) forwards the guide onto the
  executable `Crop` struct; must forward the nested tuple intact.
- **`detect_classes/1`:** `lib/image_pipe/plan.ex` (~`:90–105`) — must match
  `{:detect, {spec, _weights}}` and reduce over `spec` only. **Weights never affect
  the spec, gating, or detector identity.** (The current `{:detect, classes}` clause
  would otherwise bind `classes = {spec, weights}` and crash the `classes ++ acc`.)
- **Cache key:** `lib/image_pipe/plan/key_data.ex` — `guide_data/1` (~`:198–201`)
  serializes the **already-canonical** weights map (see Cache key for the exact
  shape).
- **Centroid:** `lib/image_pipe/transform/operation/crop.ex` —
  `focal_from_regions/3` gains the weights map (new arity), and the detect call
  sites that invoke it (`detect_crop_with_module/5` ~`:334` and the cover/face path
  ~`:266`) thread the same weights. `run_detect/5` (~`:347`) gains the resolved
  weights for telemetry.

## Parser grammar

`objw:%c1:%w1:…:%cN:%wN` is **variable-arity** (unbounded repeating class/weight
pairs). It therefore **cannot** use the declarative `@special_specs` mechanism
(`option_grammar.ex`), which is strictly fixed-arity. `objw` is added as new
clauses in the same **bespoke** path `obj` already uses — and `obj` has **four**
entry points, all of which need `objw` siblings or the relevant form silently
falls through to `:invalid_option_segment`:

- `parse_gravity(["obj" | …])` — the `g:` gravity form.
- `parse_crop_gravity(["obj" | …])` — the 3-arg crop-gravity form.
- the inline `parse_crop([w, h, "obj" | …])` clause — the `c:W:H:obj:…` form.
- the resulting guide flows through `object_detect_guide/2` (shared by
  `resize_guide` and `tagged_gravity`), so fill and crop cannot diverge there.

- The parser stays **vocabulary-free**: it carries class *strings* and *weights*,
  never enumerating a model's classes. The `all` → `:default` translation (an
  imgproxy keyword → product-neutral role name) happens at this boundary.
- **Pair structure & malformed input.** Tokens are positional class/weight pairs.
  Reject, with a clear parse error, at the parser boundary: odd token count
  (unpaired class), an empty class token, and a missing/empty/non-numeric weight.
  Reuse the existing `parse_positive_float/1` (`{:invalid_positive_float, value}`)
  for weight values and the `obj`-path arity error (`:invalid_option_segment`) for
  pairing. Bare `objw` (no pairs) is a reject.
- **No decimal/class ambiguity.** Disambiguation is *positional*, not lexical: a
  weight is always parsed as a number in the weight slot, a class is always an
  opaque string in the class slot. The colon delimiter makes `2.5` a single token,
  and COCO-style class labels are never bare numerals, so `2.5` can never be
  mistaken for a class.
- **Weight values: positive numbers, decimals allowed (`2.5` is legal), `≤ 0`
  rejected at parse with a clear error.** Rationale:
  - A negative weight is nonsense for a centroid (it would push the crop *away*,
    unboundedly).
  - Zero means "exclude this class", which is already expressible via the `obj:`
    filter form; supporting it here would create two syntaxes for the same crop
    and a `default: 0` that cannot participate in the weight model.
  - Decimals: imgproxy's weight value type is **undocumented** (the docs show only
    integer examples, and object detection is a closed-source Pro feature, so its
    parser cannot be inspected). Accepting decimals is therefore a **deliberate,
    possibly-superset choice**, not a verified compat claim. It does not break any
    documented imgproxy URL, and decimals are a genuinely useful lever at zero
    internal cost (the centroid is float math regardless). Recorded here as a
    known, intentional divergence.

## Weighted centroid (`focal_from_regions`)

The focal point is the pull-weighted centroid of the in-image detected boxes:

```
focal = Σ(pullᵢ · centerᵢ) / Σ(pullᵢ)
pullᵢ = classWeight(labelᵢ) · √areaᵢ
```

`classWeight` resolves a region's `label` against the weights map with a single
total fallback:

```elixir
classWeight(label, weights) =
  Map.get(weights, label, Map.get(weights, :default, 1))
```

This covers every edge unambiguously: empty map → every label resolves to `1`
(uniform, the Slice 1 migration); a `label` not in the map → falls to `:default`,
else `1`; a `label: nil` region → same fallback (no guard needed). The Composite
detector already preserves each region's `label` (Slice 1 guarantee), so no
detector change is needed to weight per class.

`focal_from_regions` gains the weights map as a new argument and both detect call
sites pass the **same** map (the guided path and the cover/face path), so they
cannot diverge.

### Formula: committed to `weight·√area` (no toggle)

The formula is **committed**, documented, and isolated in one private function so
the seam survives even though we ship a single formula. We do **not** build a
dev/test-only formula toggle. The choice is justified by analysis plus the
mandatory face-boost pixel test (below), which is the empirical check.

Why `√area` over the alternatives:

- **`weight·area` (today's equal-weight basis):** area grows as *size²*, so a
  class weight is nearly inert. A face is ~1/15 the *area* of the body containing
  it, so a 3× face weight (3 vs 15) still loses. The `objw` knob would ship
  cosmetic.
- **`weight` only (area ignored):** a tiny incidental object gets a full vote and
  hijacks the crop in cluttered scenes — a small background person counts equally
  with a dominant foreground car. Predictably wrong in the common case.
- **`weight·√area` (chosen):** `√area` tracks the box's *linear* size, undoing the
  squaring. The face becomes ~1/4 of the body instead of 1/15, so a modest weight
  is a real, responsive lever — yet size still matters, so a genuinely dominant
  object keeps winning. The middle path: weights are usable *and* "bigger object
  wins" survives.

### Worked behavior — nested scene (face ⊂ person ⊂ car)

With car low-mid (`y≈0.55`, `√area≈346`), person mid (`y≈0.45`, `√area≈194`), face
high (`y≈0.25`, `√area≈59`):

| Request                | Resulting focal y | Behavior                                   |
| ---------------------- | ----------------- | ------------------------------------------ |
| `obj:face` (filter)    | 0.25              | car/person not considered — lands on face  |
| `obj:all` (uniform)    | 0.49              | car dominates; face barely registers       |
| `objw:all:1:face:3`    | 0.45              | gentle, real upward nudge toward the face  |
| `objw:all:1:face:8`    | 0.39              | firmer pull — each weight unit moves it     |

### Honest default consequence

With uniform weights (`obj:all`), the **biggest** box wins — a portrait biases
toward the `person` box, not the face, under *any* formula. Face-centric crops use
either `obj:face` (filter: "only faces matter") or an `objw` face boost (bias:
"faces count more, but the big object still counts"). A small face inside a *huge*
object needs a larger boost than the same face inside a tight portrait, because the
size gap is larger; `√area` compresses that gap into a responsive dial rather than
an on/off switch, but it does not erase it.

### Riders

- `min_score` stays a **filter** (drop low-confidence detections at the
  threshold), not a weight multiplier. Folding score into the formula would add a
  third invisible factor that makes crops hard to reason about.
- Slice 1's uniform-area regions flow through the *same* function (empty weight map
  → all weights 1 → `√area`). We unify on one formula everywhere rather than
  keeping a separate pure-`area` path. This slightly changes how multiple
  equal-weight regions combine vs Slice 1's pure `area` (a small far region no
  longer so completely loses to a large near one). Greenfield, acceptable.

## Cache key

Weights change pixels, so they are key material. `guide_data/1` serializes the
detect guide as `[type: :detect, classes: <:all | sorted list>, weights: <map>]` —
i.e. the weights ride as a **map value**, not a list of pairs.

**Determinism trap (must follow):** `Cache.Key.canonicalize/1` deep-sorts *maps*
and *keyword lists* by key, but a bare list of `{string, number}` pairs is **not**
a keyword list (string keys aren't atoms) and would be left in insertion order →
nondeterministic key. So weights **must** be emitted as a `%{}` map (which
`canonicalize/1` reorders by Erlang term order — atoms before binaries, total and
stable), or be explicitly pre-sorted before encoding. Emitting a raw pair list is
the one shape to avoid.

- Equal weights expressed in different URL order → **same** key.
- Different weights → **different** key.
- `objw:all:6:car:2` vs `objw:all:3:car:1` → different keys despite identical
  crops (accepted redundancy; see "sparse and canonical" above).

The weights ride inside the operation's `:guide` field, which already flows through
`plan_material → pipelines → KeyData.data` and into the hash/ETag, so weights become
part of response identity with no extra plumbing. Detector identity is orthogonal
(weights are a request axis, not a detector axis) and unchanged.

No key-data version bump: greenfield, reshape the canonical key data and update
tests in place (per the repo's cache guideline).

## Telemetry

The `[:transform, :detect]` span metadata gains a `weights:` key carrying the
**resolved** canonical weight map (post-parse, the same `%{:default => …,
"class" => …}` that drives the centroid), alongside the existing `classes:`.

Weights are product-neutral and derived entirely from the public request (not a
path, signature, or filename), so they are safe to emit by default — they are not
the sensitive category the telemetry guidelines guard against. The default Logger
surfaces `weights:` next to `classes:`. Emitting the *resolved* map (not the raw
URL text) means telemetry reflects what actually drove the crop. `run_detect/5`'s
signature/call site gains the resolved weights so the span can carry them.

## Demo

Add per-class weight controls and URL state to the `demo/` Svelte app so the new
behavior is exercisable end-to-end, keeping the demo in sync with the transform
change (per the repo's demo guideline).

## Docs

- `docs/content-aware-gravity.md`: document `objw`, the `weight·√area` formula and
  its rationale, and the filter-vs-weight distinction (`obj:` filters, `objw`
  weights over everything).
- `docs/imgproxy_support_matrix.md`: flip the `objw` row from "out (Slice 2)" to
  supported.

## Tests

- **Parser:** `objw:%class:%weight:…` grammar, `:default` baseline + per-class
  override, order-insensitivity, both `g:` and `c:` forms. Malformed rejection —
  `≤ 0`, odd arity (unpaired class), empty class token, missing/non-numeric weight,
  bare `objw`. Assert the **user-visible outcome** (rejection / HTTP failure before
  source/cache access), **not** the private error-string text.
- **Request-boundary pixel test (mandatory):** decode the response body and prove a
  face weight boost *actually moves the crop* — `objw:all:1:face:3` vs `obj:all`
  produce different crops, biased toward the face — using the injected
  `ImagePipe.Test.FakeDetector` (configurable multi-box labeled result) for
  determinism (per Slice 1's harness). This is the empirical check that vindicates
  `√area`.
- **`c:W:H:` crop form:** the `g:` pixel test covers only the `resize_guide` path.
  Add a crop-form check that `objw` weights reach the `tagged_gravity` path — at
  minimum a parser/planner assertion that `c:` carries the same `{spec, weights}`
  guide, ideally one representative crop-form wire result — so fill and crop can't
  silently diverge.
- **No-geometry form (required):** `objw:all:1:face:3` with no resize/crop → `200`,
  mirroring the Slice 1 `g:obj:car` no-geometry test.
- **Cache key:** weights are key material — different weights → different key;
  reordered-equal weights → same key. Plus a **wire-level cache-reuse** test: two
  semantically-equal `objw` URLs (reordered pairs, and the `face:3` ≡ `all:1:face:3`
  canonicalization) hit the same key → second request is a cache hit / no second
  source fetch.
- **Canonicalization property test:** idempotence of the drop-rule fixed point, and
  that `key_data` serialization is a no-op on already-canonical input (parser and
  cache layers cannot drift).
- **`√area` regression guard:** the formula change alters Slice 1's equal-weight
  multi-region crops (pure `area` → `√area`). Pin the new equal-weight behavior with
  a focused 2+ region centroid/pixel test, and audit existing Slice 1 focal-coordinate
  assertions for the shift, so the change is intentional-and-asserted.
- **Telemetry:** assert `weights:` appears in `[:transform, :detect]` metadata
  (matching the Slice 1 logger-test precedent).
- No formula-toggle test exists (there is no toggle).

Keep wire-level compatibility tests representative, not exhaustive: option-order
equivalence, `Accept` negotiation where relevant, representative geometry results,
request-safety failures before source/cache access. Leave grammar edge cases and
combinatorial coverage in parser, planner, cache-key, and property tests.

## Open questions

None. All four scoping questions are resolved: guide shape (sparse `{spec,
weights}` tuple, `:default`-keyed), weight grammar (positive numbers incl.
decimals, `≤ 0` rejected), formula (`weight·√area`, committed, no toggle), and
telemetry (resolved weights on the detect span).
