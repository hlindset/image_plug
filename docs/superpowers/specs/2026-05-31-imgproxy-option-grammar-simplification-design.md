# imgproxy option grammar simplification

**Date:** 2026-05-31
**Status:** Design — reviewed (parallel subagent cycle applied), awaiting user sign-off
**Scope:** `lib/image_pipe/parser/imgproxy/option_grammar.ex` (internal refactor only)

## Problem

`OptionGrammar` parses imgproxy processing-option segments (`rs:fill:300:200`,
`bl:5`, `br:20`, …). The largest concentration of duplication is in the
`parse_special_option/3` family: ~25 dispatch clauses, most of the form
`when name in [...] -> parse_xxx(args, segment)`, each delegating to a bespoke
`parse_xxx/2` that re-implements the same skeleton — match arity, reject empty
args, run each arg through a value parser, fall back to
`{:error, {:invalid_option_segment, segment}}`.

The grammar itself is trivial (`String.split(segment, ":")`); a parser-combinator
library such as NimbleParsec would not help, because there is no character-level
or recursive structure to parse. The cost is **semantic interpretation per
option**, and it is paid again by hand for every option.

## Goal

Make adding a regular imgproxy option a small, low-risk, data-shaped change, and
centralize arity/empty-arg/error handling so it is implemented once. This is a
compatibility parser tracking an external product's option catalog, so the
dominant future cost is safely adding more options, not reading the file once.

## Non-goals

- No change to observable behavior. Every status, header, decoded pixel result,
  and **error tag** the parser produces today must be byte-for-byte preserved.
  The existing test suites are the specification.
- No NimbleParsec / external parser dependency.
- No cache-key data-version bump (parser output is unchanged; canonical plan
  fields and thus cache keys are unaffected — confirmed in review).
- No demo changes (no options added, removed, or reparameterized).
- No new public API. `OptionGrammar.parse/1`'s return contract is unchanged, so
  `options.ex`, `plan_builder.ex`, and the wire layer are untouched.

## Approach

A declarative spec table plus one generic interpreter for the options that fit a
flat shape, with genuinely irregular options left as explicit bespoke parsers.

This was validated by a spike (already in the working tree) that converted the
seven single-arg pipeline options — `blur`, `sharpen`, `pixelate`, `dpr`,
`brightness`, `contrast`, `saturation` — with all 174 parser/property/wire tests
green, credo `--strict` clean, and `--warnings-as-errors` compile.

### Data model

```elixir
@special_specs %{
  "blur" => [{:blur, :non_neg_float}],
  "bl"   => [{:blur, :non_neg_float}],
  # ...
  "strip_color_profile" => [{:strip_color_profile, :bool, default: true}],
  "scp"                 => [{:strip_color_profile, :bool, default: true}],
  "crop_aspect_ratio" => [{:crop_aspect_ratio, :non_neg_float},
                          {:crop_aspect_ratio_enlarge, :bool, default: false}],
  # ...car aliases
}
```

Each alias maps to an ordered list of arg specs. An arg spec is:

- `{key, type}` — required, non-empty; or
- `{key, type, default: value}` — optional **trailing** arg. `value` is an
  already-parsed literal (e.g. `true`, `false`), used directly **without** going
  through `apply_type` (so `default: true`, not `default: "true"`).

`type` is an atom dispatched by `apply_type/2` to an existing value parser
(`:non_neg_float` → `parse_non_negative_float/1`, `:bool` → `parse_boolean/1`,
etc.). The value parsers are unchanged; each already emits its own canonical
error tag, so there is **no per-option error-tag override** in this design (the
earlier `error:` idea was dropped — its only candidate, `background_alpha`, is
not convertible; see bespoke list).

New `apply_type/2` entries required by this change: `:bool` → `parse_boolean/1`.
(The seven spike options already use `:non_neg_float`, `:positive_float`,
`:non_neg_int`, `:adjustment`.)

### Interpreter

`interpret_special/3`:

1. Let `required` = count of args without `default:`, `total` = all args.
2. **Arity:** if `length(args)` is outside `[required, total]` →
   `{:error, {:invalid_option_segment, segment}}`.
3. **Required positions:** an empty value (`""`) in any *required* position →
   `{:error, {:invalid_option_segment, segment}}`.
4. **Optional positions — absent vs. empty are distinct:**
   - *absent* (position beyond the provided arity) → contribute the spec's
     pre-parsed `default:` value directly (do **not** call `apply_type`).
   - *present* (within provided arity), including an explicit empty `""` →
     treated as a provided value: empty → `{:invalid_option_segment, segment}`;
     non-empty → run through `apply_type`.
5. Run each present value through `apply_type/2`; on failure, propagate the value
   parser's own tag.
6. Return `{:ok, keyword_assignments}`; `parse_pipeline_option/3` wraps it as
   `{:pipeline, assignments}` exactly as before.

This absent-vs-empty distinction is load-bearing: it reproduces the bespoke
behavior where `scp` → `true` but `scp:` → error, and `car:1.5` defaults enlarge
to `false` but `car:1.5:` → error.

The interpreter introduces no runtime validation of the `@special_specs` shape
itself (e.g. that defaulted args are trailing). That is a programmer-error
invariant covered by the green test suite, not a runtime guard — consistent with
the project's "trust internal producers, reserve raises for programmer error"
guideline. An unknown `type` atom raises via `apply_type/2`'s missing clause, by
design.

### Options the schema absorbs (9 total)

- **Spike (done):** `blur`, `sharpen`, `pixelate`, `dpr`, `brightness`,
  `contrast`, `saturation` — single required arg, type's canonical error tag.
- **Optional-trailing-with-default:** `strip_color_profile` (optional `:bool`,
  default `true`; bare `scp` → `true`, `scp:` → error), `crop_aspect_ratio`
  (required `:non_neg_float` ratio + optional `:bool` enlarge, default `false`;
  flat 1:1 mapping to its two output keys).

### Options that stay bespoke (and why)

Each carries logic a flat key→value schema cannot express:

- **`background_alpha`** — *not convertible.* Its arity/empty failures return the
  option-specific `{:invalid_background_alpha, args}` (pinned by
  `option_grammar_test.exs`), not the interpreter's uniform
  `{:invalid_option_segment, segment}`. Preserving that would require a
  whole-option error override used by exactly one option — net more complexity.
- **`auto_rotate`, `rotate`, `flip`** — assignments nest under `:orientation`
  (a shape consumed uniformly downstream in `options.ex`, so the nesting itself
  is shared by 3 options). They stay bespoke not because nesting is rare but
  because each also carries logic the flat interpreter lacks: `rotate` does
  mod-90 validation + `normalize_rotation/1` (a post-parse transform), `flip`
  collapses two bools into a `:both/:horizontal/:vertical/nil` enum (a
  post-combine), and all three support a zero-arg form (every arg optional, not
  trailing-optional). Nesting never travels alone here.
- **`extend`, `extend_aspect_ratio`** — bool + optional gravity sub-grammar +
  an injected `extend_requested: true` constant, entangled together.
- **`monochrome`, `duotone`** — nested keyword output + optional colors with
  remapped error tags.
- **`background` (empty | hex | r:g:b), `zoom` (1-arg fan-out | 2-arg)** —
  alternative arg shapes / fan-out. The two don't share an alternation strategy,
  so a `one_of` combinator would serve two unrelated cases — deliberately not
  added.
- **`padding` (1–4 values with `:unset` holes), `gravity`/`crop` (anchor enum vs.
  focal-point vs. offset tuple), `filename` (percent vs. base64).**
- **`resize`/`size`** (`Enum.split` + extend-gravity merge) and `format_quality`
  (pair into a map) keep their existing `parse_known_option/4` clauses.

### Dispatch

`parse_pipeline_option/3` (introduced in the spike) is the single entry for
non-`@option_specs` options: `@special_specs` lookup → `interpret_special/3`,
else fall through to the remaining `parse_special_option/3` clauses. One path,
two handler kinds.

### Two spec tables, deliberately

After this change the parser has **two** declarative arg-spec interpreters:
`@option_specs` + `parse_field/2` (for the resize/format/quality/etc. family),
and `@special_specs` + `apply_type/2` (this change). They are the same idea in
two vocabularies (`field` vs `type`, `skip_empty:` vs `default:`) with two error
models. Unifying them now would force `resize`/`size`'s irregular merge into a
shared table — over-generalization this design otherwise avoids — so they stay
separate. To limit drift:

- Align naming where cheap so the two read as dialects of one idea.
- Unify only when a third regular-option family appears, or when `@option_specs`
  needs a `default:`-equivalent. Documented here so the divergence is a known,
  bounded decision rather than silent.

## Error model

| Failure | Tag |
| --- | --- |
| Wrong arity / empty required arg / empty *present* optional arg | `{:invalid_option_segment, segment}` |
| Value parse failure | the value parser's own tag (e.g. `:invalid_non_negative_float`, `:invalid_positive_float`, `:invalid_adjustment`) |

This matches current behavior for **the nine converted options** exactly.
Options whose bespoke parsers use option-specific arity/empty tags (e.g.
`background_alpha`) are excluded from conversion precisely because they don't fit
this uniform model.

## Testing

Treat the existing suites as the spec; convert green-to-green. Primary spec files
(the design's original list omitted the most important one):

- `test/parser/imgproxy/option_grammar_test.exs` — **primary**: pins exact
  `{:ok, {:pipeline, [...]}}` tuples and error tags for these options, including
  the `invalid_pipeline_arity_segments/0` arity table.
- `test/parser/imgproxy/options_test.exs`, `.../plan_builder_test.exs` — pin
  `car`, `dpr`, brightness/contrast/saturation at the plan layer.
- `test/parser/imgproxy_test.exs`, `.../imgproxy_property_test.exs`,
  `test/image_pipe/imgproxy_wire_conformance_test.exs` — wire/behavior contracts.

**Pins to add at the `OptionGrammar.parse/1` boundary _before_ converting** (each
closes an un-asserted behavior the refactor could otherwise silently change):

- `dpr`: `dpr:0` → `{:error, {:invalid_positive_float, "0"}}` and a fractional
  success (`dpr:1.5`). Type semantics are currently unpinned.
- `crop_aspect_ratio`: both `car:<ratio>` (1-arg, enlarge defaults `false`) and
  `car:<ratio>:<bool>` (2-arg) → exact `{:pipeline, [...]}` keyword lists; plus
  ratio failure (`car:nope`) and the empty-trailing edge `car:1.5:` →
  `{:invalid_option_segment, ...}`.
- `strip_color_profile`: bare `scp`/`strip_color_profile` (no args) →
  `{:ok, {:pipeline, [strip_color_profile: true]}}`; plus `scp:` →
  `{:invalid_option_segment, ...}` and `scp:bad` → error.
- `brightness`/`contrast`/`saturation`: tighten existing out-of-range assertions
  from `{:error, _}` to the exact `{:invalid_adjustment, value}` tag.

**One property to add:** alias-equivalence over the converted long/short pairs
(`blur`/`bl`, `sharpen`/`sh`, `pixelate`/`pix`, `brightness`/`br`, `contrast`/`co`,
`saturation`/`sa`, `crop_aspect_ratio`/`crop_ar`/`car`) — `parse(long:v) ==
parse(short:v)` over valid and invalid `v`, mirroring the existing `zoom`/`z`
property. No arity-fuzz property: the explicit arity table already covers edges.

**Tests not to write / not to delete:**

- New cases are forward contract pins at `parse/1` (tagged tuples are public
  contract). No old-vs-new parity/characterization harnesses; no `*_characterization_test.exs`.
- No name-policing: do not assert `function_exported?` on the deleted
  `parse_blur/2` etc. The `parse/1`-level suites are the sole proof.
- **Do not delete coverage as "redundant."** The arity table and cases like
  `bga:0.0 → {:ratio, 0, 10}` are the sole pin for their edge. The only permitted
  deletions are parity/characterization pins the spike may have introduced, and a
  redundancy claim must name the specific other test covering the identical
  input→output.
- All new pins drive through `parse/1`; never hand-build `%CropRequest{}` or
  assignment keyword lists as inputs.

Gate before finishing: `mix format --check-formatted`,
`mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`
(via `mise exec --`).

## Boundaries / guideline compliance

- Stays entirely within `ImagePipe.Parser.Imgproxy.*` — no cross-namespace
  change, no concrete transform modules referenced, no plan-model change. No
  architecture-test changes needed.
- The interpreter is trusted internal dispatch; arity/empty checks validate
  untrusted URL input (a real boundary), not impossible internal misuse.

## Risks / trade-offs

- **Indirection vs. greppability.** `grep parse_blur` no longer lands on the
  logic; you read the `@special_specs` row + the interpreter. Accepted because
  the marginal cost of the next regular option drops to ~one table row.
- **Modest absorbed set.** After review, the clean-fit set is 9 options (7 spike
  + `scp` + `crop_aspect_ratio`); `background_alpha` and all output-shape /
  sub-grammar / fan-out options stay bespoke. The interpreter's capabilities are
  capped at fixed-required + optional-trailing-with-default deliberately.
- **Dual interpreters.** Two declarative tables coexist (see "Two spec tables").
  Bounded by the documented unify-trigger.
