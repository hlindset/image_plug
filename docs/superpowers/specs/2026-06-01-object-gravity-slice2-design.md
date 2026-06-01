# Object-oriented gravity — Slice 2 (`objw` per-class weights): design

**Status:** reviewed design, ready for implementation planning.

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

### `obj` filters; `objw` weights over everything

This distinction drives the whole design. In Slice 1, `obj:face` does two jobs:
it **filters** detection to the `face` class *and* targets the crop. imgproxy's
`objw` does **not** filter — `objw:all:1:face:3` means "detect *everything*,
weight faces 3×"; unlisted classes still count at the default weight. That is why
imgproxy needs the `all` baseline keyword: `objw` considers every class, so it
needs a way to set the default for the classes you did not name. If `objw`
filtered to its named classes, `all` would be meaningless.

Consequence: **"what to detect" (the spec) and "how to weight each class" (the
weights) are orthogonal axes.** `objw` always detects *all* classes (`spec:
:all`); its named classes populate the weight map, never the spec. Multi-element
spec lists arise only from the Slice 1 `obj:` filter form (`obj:person:face`).

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

### Grammar → guide mapping

| URL gravity        | `spec`               | `weights`                  |
| ------------------ | -------------------- | -------------------------- |
| `obj` / `obj:all`  | `:all`               | `%{}`                      |
| `obj:face`         | `["face"]`           | `%{}`                      |
| `obj:person:face`  | `["person", "face"]` | `%{}`                      |
| `objw:face:3`      | `:all`               | `%{"face" => 3}`           |
| `objw:all:1:face:3`| `:all`               | `%{"face" => 3}`           |
| `objw:all:3:car:1` | `:all`               | `%{default: 3, "car" => 1}`|
| `objw:all:3:car:3` | `:all`               | `%{default: 3}`            |

`objw:face:3` and `objw:all:1:face:3` are equivalent and canonicalize to the same
guide.

### Reshape in place (greenfield)

- `lib/image_pipe/plan/operation/crop_guided.ex`, `resize.ex` — guide typespec.
- `lib/image_pipe/parser/imgproxy/plan_builder.ex` — `object_detect_guide/1`
  emits the `{spec, weights}` payload; shared by the fill (`resize_guide`) and
  crop (`tagged_gravity`) paths.
- `lib/image_pipe/plan.ex` — `detect_classes/1` reads `spec` from the new tuple.
- `lib/image_pipe/plan/key_data.ex` — serialize the weights map.
- `lib/image_pipe/transform/operation/crop.ex` — `focal_from_regions/3`.

## Parser grammar

Add `objw` parsing alongside `obj` in
`lib/image_pipe/parser/imgproxy/option_grammar.ex`, mirroring Slice 1's dual
gravity/crop entry points so the fill and crop paths cannot diverge.

- The parser stays **vocabulary-free**: it carries class *strings* and *weights*,
  never enumerating a model's classes. The `all` → `:default` translation (an
  imgproxy keyword → product-neutral role name) happens at this boundary.
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

`classWeight` resolves a region's `label` against the weights map, falling back to
the `:default` baseline (or `1` when `:default` is absent). The Composite detector
already preserves each region's `label` (Slice 1 guarantee), so no detector change
is needed to weight per class.

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

Weights change pixels, so they are key material. `key_data` serializes the
canonical weights map — the `:default` entry (when present) plus class entries
sorted by class name — into the detect guide's key data, alongside the existing
`spec` serialization (`:all` sentinel or sorted class list).

- Equal weights expressed in different URL order → **same** key.
- Different weights → **different** key.
- `objw:all:6:car:2` vs `objw:all:3:car:1` → different keys despite identical
  crops (accepted redundancy; see "sparse and canonical" above).

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
URL text) means telemetry reflects what actually drove the crop.

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
  override, order-insensitivity, both `g:` and `c:` forms, `≤ 0` rejection.
- **Request-boundary pixel test (mandatory):** decode the response body and prove a
  face weight boost *actually moves the crop* — `objw:all:1:face:3` vs `obj:all`
  produce different crops, biased toward the face — using the injected
  `ImagePipe.Test.FakeDetector` for determinism (per Slice 1's harness). This is
  the empirical check that vindicates `√area`. Cover the no-geometry form
  separately if applicable.
- **Cache key:** weights are key material — different weights → different key;
  reordered-equal weights → same key.
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
