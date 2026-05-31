# Object-oriented gravity — Slice 2 (`objw` weights): design notes

**Status:** pre-spec notes only — NOT a reviewed spec. Slice 2 gets its own
brainstorm → spec → parallel-review → plan cycle once Slice 1 lands. This file
captures the design thinking we did while scoping Slice 1 so it isn't lost.

**Depends on:** Slice 1 (general object gravity) —
`docs/superpowers/specs/2026-05-31-object-gravity-slice1-design.md`. Slice 2 is
purely additive on top of the Composite/routing + `{:detect, …}` guide that Slice
1 builds; it requires no rework of Slice 1.

## Scope

Add imgproxy's per-class weighting to object gravity:

- `gravity:objw:%class1:%weight1:…:%classN:%weightN` — per-class weights.
- The `all` pseudo-class as a **baseline/default** weight, e.g.
  `objw:all:2:face:3` = "everything weight 2, faces overridden to weight 3".
- Default weight is `1` (imgproxy).

Out of scope (still): `objects_position` and any further imgproxy object-gravity
surface beyond `obj`/`objw`.

## Why `all` is a baseline, and why face ∈ all matters

Slice 1 settled that `all` / bare `obj` includes faces (the union of every
configured detector's classes). That decision is what makes `objw`'s override
model coherent: `objw:all:2:face:3` reads as "default weight 2 for every detected
class, with `face` overridden to 3". If faces were excluded from `all`, that
syntax would be ambiguous (is `face` an addition or an override?). So `objw`
parses to a weight map like `%{default: 2, "face" => 3}` applied per detected
region by its `label`.

## The weighted-centroid formula (the core open decision)

Slice 1 keeps the existing **equal-weight `area`** centroid in
`focal_from_regions` unchanged. Slice 2 introduces a *class-weighted* centroid.
The formula choice is the crux, because it decides whether a class weight can
actually move the crop. Three candidates, evaluated against concrete scenes:

**Scenario A — portrait, one person.** RT-DETR emits a large `person` box; YuNet a
small `face` box inside it (face area ≈ 1/10–1/20 of person). This is the headline
`objw:all:1:face:3` case ("favor the face").

**Scenario B — clutter: a dominant `car` with a tiny background `person`.** Plain
weights.

| Formula | Scenario A (boost face) | Scenario B (dominant car) | Verdict |
| --- | --- | --- | --- |
| `weight · area` | face stays outvoted — 3×(1/15) still loses to the person box, so the weight is **inert** for its headline use | car correctly dominates | faithful to today, but `objw` face-boosting is cosmetic |
| **`weight · √area`** (recommended) | √ shrinks the gap to ~1/4, so 3× pulls the focal point onto the face — **weight works** | car's √area still ~6× the background person → car still wins | best balance: "size matters" *and* weights are a real lever |
| `weight` only (area-ignored) | face=3 vs person=1 → snaps to face | car and tiny background person count **equally** → focal dragged to an incidental object — **wrong crop** | predictable but predictably wrong in clutter |

**Lean:** `weight · √area`. It preserves the sane "dominant object wins" default
(Scenario B) while making class weights a usable lever for the face-vs-body case
(Scenario A). `weight · area` ships an `objw` knob that's inert for its most
natural use; `weight`-only gives incidental small objects a full vote and produces
bad crops in cluttered scenes (the common case).

**Honest default consequence:** with all weights at 1 (plain `obj:all`), a portrait
biases toward the larger `person` box, not the face — under *any* formula. Face-
centric crops use `obj:face` (Slice 1) or an `objw` face boost (Slice 2).

**How the choice is made:** settle `weight·area` vs `weight·√area` vs `weight`-only
by **dev-loop experimentation on real images**, behind a **dev/test-only toggle**
(the same way `SimpleServer` is dev/test-only and never compiles into prod). The
toggle is removed before merge — it is **never** a public/plug option (a formula
knob would be cache-key-affecting, validated, documented contract surface for a
question we're only answering once). Isolate the weight in one private function so
the three strategies are swappable during the experiment, then bake the winner and
delete the others.

**Riders:**
- `min_score` stays a **filter** (drop low-confidence detections at the threshold),
  not a weight multiplier — folding score into the formula adds a third invisible
  factor that makes crops hard to reason about.
- Adopting `weight·√area` also slightly changes how *multiple equal-weight faces*
  combine vs Slice 1's pure `area` (a small far face no longer so completely loses
  to a large near one). Greenfield, acceptable; unify on one formula everywhere
  rather than keeping two.

## Threading weights: grammar → plan → focal

- **Parser (imgproxy):** add `objw:%class:%weight:…` grammar (alongside the Slice 1
  `obj` grammar). Map to a product-neutral guide carrying weights. Like Slice 1,
  the parser stays vocabulary-free — it carries class *strings* and *weights*, never
  enumerating a model's classes; `all` stays the baseline sentinel.
- **Plan guide reshape:** Slice 1's `{:detect, :all} | {:detect, [classes]}` becomes
  weight-carrying. Options to decide in the Slice 2 spec: a third tuple element
  (`{:detect, spec, weights}`) or a small struct (`{:detect, %Detect{spec, weights}}`).
  Greenfield → reshape `CropGuided`/`Resize`/`crop.ex`/`key_data`/`detect_classes`
  in place (and bump nothing — cache key data reshapes in place per the repo's
  greenfield cache guideline). Weights go into the cache key (they change pixels).
- **`focal_from_regions`:** apply `weight(label) · f(area)` per region, where
  `weight(label)` resolves against the parsed weight map (`label`-keyed, with the
  `all`/default baseline) and `f` is the chosen area function. The merged regions
  already retain their `label` (Slice 1 guarantees this), so no Composite change is
  needed to weight per class.

## Surfaces to update (Slice 2)

- Parser grammar + mapping for `objw` (both `g:` and `c:W:H:` forms, consistent
  with Slice 1's dual `resize_guide`/`tagged_gravity` mapping).
- Plan guide shape + `key_data` (weights are key material) + `detect_classes` (it
  must still report the class set / `:all` for gating and identity).
- `focal_from_regions` weighted centroid + the dev-only formula toggle.
- Telemetry: the per-model/detect spans may carry the effective weight map
  (product-neutral; weights are derived from the public request).
- Demo: per-class weight controls + URL state.
- Docs: `content-aware-gravity.md`, `imgproxy_support_matrix.md` (flip the `objw`
  row from "out (Slice 2)" to supported).

## Tests (Slice 2)

- Parser: `objw:%c:%w:…` grammar, `all` baseline + per-class override, order-
  insensitivity, both `g:`/`c:` forms.
- A request-boundary **pixel** test proving a face weight boost *actually moves the
  crop* (decode body; `objw:all:1:face:3` vs `obj:all` differ, biased toward the
  face) — using an injected fake detector for determinism, per Slice 1's harness.
- Cache key: weights are key material (different weights → different key; equal
  weights in different URL order → same key).
- The formula-experiment toggle is dev/test-only and removed before merge — no test
  pins it.

## Open questions for the Slice 2 brainstorm

- Final guide shape (tuple vs struct) for carrying weights.
- Exact `f(area)` (confirm `√area` empirically; consider a tunable exponent only if
  experimentation demands it — default to no new knob).
- Whether the per-model telemetry span should surface the resolved weights.
