# imgproxy option grammar simplification

**Date:** 2026-05-31
**Status:** Design — reviewed (three parallel subagent cycles + catalog analysis), scope finalized
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
option**, paid again by hand for every option.

## Goal

Collapse the repeated per-option skeleton for the options that share it, so the
parsing rule lives as data in one place and the arity/empty/error handling is
implemented once. This is a compatibility parser tracking an external product's
option catalog, so reducing the per-option boilerplate has compounding value.

## Non-goals

- No change to observable behavior. Every status, header, decoded pixel result,
  and **error tag** the parser produces today must be byte-for-byte preserved.
  The existing test suites are the specification.
- No NimbleParsec / external parser dependency.
- No cache-key data-version bump (parser output unchanged; canonical plan fields
  and thus cache keys are unaffected — confirmed in review).
- No demo changes (no options added, removed, or reparameterized).
- No new public API. `OptionGrammar.parse/1`'s return contract is unchanged, so
  `options.ex`, `plan_builder.ex`, and the wire layer are untouched.

## Scope (finalized: 7 options)

Three review cycles plus an analysis of imgproxy's unimplemented option catalog
settled the scope deliberately narrow:

- **Convert the 7 single-required-arg pipeline options** — `blur`, `sharpen`,
  `pixelate`, `dpr`, `brightness`, `contrast`, `saturation` — to a declarative
  `@special_specs` table + `interpret_special/3`. These share the exact same
  skeleton and all reuse value parsers that already exist, so the conversion is
  pure deduplication of proven-identical code.
- **Everything else stays bespoke**, including options that *look* close but
  aren't pure-fit:
  - `strip_color_profile`/`scp` — a single *optional* boolean. Converting it
    would mean building a new optional-boolean facility (table + interpreter +
    dispatch branch) whose only current consumer is `scp`, justified by future
    options that don't exist yet. Its existing bespoke clause is already minimal
    and correct; it stays until a real second caller appears (see Deferred work).
  - `crop_aspect_ratio`/`car` — leading-required + optional-trailing; the only
    shape that would force absent-vs-empty range logic into a shared interpreter.
  - `background_alpha` — arity/empty failures use the option-specific
    `{:invalid_background_alpha, args}` tag (pinned by tests), not the uniform
    `{:invalid_option_segment}`.

The 7-option conversion already exists in the working tree (the spike): 174
parser/property/wire tests green, credo `--strict` clean, `--warnings-as-errors`
compile. The remaining work in this change is **locking tests** (below), not new
production logic.

## Approach (the spike, already implemented)

```elixir
@special_specs %{
  "blur" => [{:blur, :non_neg_float}],
  "bl"   => [{:blur, :non_neg_float}],
  # sharpen, pixelate, dpr, brightness, contrast, saturation
}
```

Each alias maps to an ordered list of `{key, type}` required, non-empty args.
`type` is dispatched by `apply_type/2` to an existing value parser
(`:non_neg_float`, `:positive_float`, `:non_neg_int`, `:adjustment`). The value
parsers are unchanged and each emits its own canonical error tag, so no
per-option error override is needed.

`interpret_special/3`: arity mismatch or empty value →
`{:error, {:invalid_option_segment, segment}}`; otherwise run each value through
`apply_type/2`, propagating the parser's own error tag on failure; return
`{:ok, keyword_assignments}`, which `parse_pipeline_option/3` wraps as
`{:ok, {:pipeline, assignments}}`. An unknown `type` atom raises via
`apply_type/2`'s missing clause, by design (trusted internal dispatch).

Dispatch via `parse_pipeline_option/3`: `@special_specs` lookup →
`interpret_special/3`, else fall through to the existing bespoke
`parse_special_option/3` clauses. One path, two handler kinds.

## Catalog-informed rationale (and an honest bound on the payoff)

Of imgproxy's **unimplemented** processing options (sources:
docs.imgproxy.net/usage/processing, /generating_the_url), bucketed by the parsing
mechanism each would need:

| Bucket | Mechanism | Count | Non-Pro |
| --- | --- | --- | --- |
| A. Fixed-arity (`max_bytes`, `dpi`, `page`, `watermark_size`, …) | a `@special_specs` row + whatever else the option needs | 15 | 5 |
| B. Single optional-boolean (`raw`, `enforce_thumbnail`, `preserve_hdr`, `disable_animation`) | an optional-boolean facility | 4 | 3 |
| C. Multi optional-trailing (`adjust`, `trim`, `unsharp_masking`, `gradient`, `*_options`) | a general multi-optional interpreter | 9 | 1 (`trim`) |
| D. Irregular (`watermark`, `style`, `skip_processing`, detections) | bespoke | ~14 | 3 |

**Honest bound (review correction):** the `@special_specs` table collapses only
the *grammar-parsing* step. A genuinely new bucket-A option may still need a new
`apply_type` clause + value parser (e.g. an enum like `resizing_algorithm`), a
struct field on `PipelineRequest`/`Effects`, and a `plan_builder` operation — and
`interpret_special/3` currently only emits pipeline-scoped assignments, so a
non-pipeline option (`max_bytes`, `page`) can't use it without first adding scope
routing (the `@option_specs` path has `scoped_assignments/2` for this;
`@special_specs` does not). So the schema is worth adopting for the recurring
grammar-skeleton dedup it provides on pipeline options with existing value types
— not because 15 options become free one-liners. The 7 converted options are
exactly that pre-wired, pipeline-scoped, existing-type set.

## Deferred work (documented, not built)

- **Optional-boolean facility (bucket B).** When the first real future boolean
  option (`enforce_thumbnail` / `preserve_hdr`; `disable_animation` is Pro) is
  prioritized, add a minimal single-optional-boolean handler and migrate `scp`
  into it in the same change. `raw` is *not* a clean member — in imgproxy it
  switches response mode (serve source bytes), so its parse-grammar surface
  understates the planner/output work it needs; classify it then, with its real
  shape in hand. Building this now for `scp` alone is premature (per the same
  "add it when the caller appears" discipline used to defer bucket C).
- **Multi-optional interpreter (bucket C).** Deferred. Two independent triggers,
  not one: (a) the Pro encoding/color options (`adjust`, `unsharp_masking`,
  `*_options`, …) get prioritized, or (b) `trim` — the lone non-Pro, commonly-used
  member — is requested. `trim` is heterogeneously typed (float threshold, color,
  two booleans), so even then a general facility needs per-arg type+default specs.
- **Gravity sub-grammar consolidation.** `parse_gravity` (the `g:` path) and
  `parse_crop_gravity` (the crop path) are two parallel implementations of the
  same gravity grammar (both handle `sm`, `fp`, anchor separately, with different
  output shapes) — the exact "two parallel implementations of one grammar" this
  change collapses for fixed-arity options. Consolidating them into one shared
  gravity-tail parser is a natural follow-on. Trigger: a feature that touches
  gravity in both paths — notably smart object cropping (`obj`/object-detection
  gravity), which applies to both `g:obj:…` and crop's gravity argument and would
  otherwise be implemented (and drift) twice. Not in scope here (gravity isn't one
  of the converted options); flagged so the obj work has a consolidation target on
  record rather than rediscovering the duplication.

## Error model

| Failure | Tag |
| --- | --- |
| Wrong arity / empty arg | `{:invalid_option_segment, segment}` |
| Value parse failure | value parser's own tag (`:invalid_non_negative_float`, `:invalid_positive_float`, `:invalid_non_negative_integer`, `:invalid_adjustment`) |

Matches current behavior for all 7 converted options exactly. (Verified case-by-
case in review across every arity/emptiness shape.)

## Testing

The 7-option conversion is already green against the existing suites. This change
adds **locking pins** at the `OptionGrammar.parse/1` boundary that were found
missing — they pin behavior the conversion relies on but that no test currently
asserts at the grammar boundary:

Primary spec files: `test/parser/imgproxy/option_grammar_test.exs` (exact
`{:ok, {:pipeline, [...]}}` tuples + error tags, incl. the
`invalid_pipeline_arity_segments/0` arity table); `.../options_test.exs`,
`.../plan_builder_test.exs` (plan-layer pins); the wire suites for behavior.

Pins to add (each confirmed genuinely absent at `parse/1` in review):

- `dpr`: `dpr:0` → `{:error, {:invalid_positive_float, "0"}}` and a fractional
  success `dpr:1.5`. Type semantics are pinned nowhere today (only the arity
  table covers `dpr`/`dpr:`/`dpr:1:2`); a mis-typed `:non_neg_float` would slip
  through.
- `brightness`/`contrast`/`saturation`: **tighten** the existing out-of-range
  assertions (`imgproxy_test.exs` ~1290, `request_safety_test.exs` ~194) from the
  loose `{:error, _}` to the exact `{:invalid_adjustment, value}` tag. This is a
  tightening of existing loose coverage, not net-new coverage.

One property to add: alias-equivalence over the 7 converted long/short pairs
(`blur`/`bl`, `sharpen`/`sh`, `pixelate`/`pix`, `brightness`/`br`, `contrast`/`co`,
`saturation`/`sa`) — `parse(long:v) == parse(short:v)` over valid and invalid `v`,
mirroring the existing `zoom`/`z` property. No arity-fuzz property: the explicit
arity table covers edges. (No `scp` pair — `scp` is unchanged.)

Tests not to write / not to delete:

- New cases are forward contract pins at `parse/1` (tagged tuples are public
  contract). No old-vs-new parity/characterization harnesses.
- No name-policing: do not assert `function_exported?` on the deleted
  `parse_effect_float/3` / `parse_dpr/2` / `parse_adjustment/3` / `parse_pixelate/2`.
  The `parse/1`-level suites are the sole proof.
- Do not delete coverage as "redundant"; only permitted deletions are
  parity/characterization pins the spike may have introduced, and a redundancy
  claim must name the specific other test covering the identical input→output.
- All new pins drive through `parse/1`; never hand-build internal structs as
  inputs.

Gate before finishing: `mix format --check-formatted`,
`mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`
(via `mise exec --`).

## Boundaries / guideline compliance

- Stays entirely within `ImagePipe.Parser.Imgproxy.*` — no cross-namespace
  change, no concrete transform modules referenced, no plan-model change. No
  architecture-test changes needed. (Product-neutrality/namespace compliance
  confirmed in review.)
- The interpreter is trusted internal dispatch; arity/empty checks validate
  untrusted URL input (a real boundary), not impossible internal misuse.

## Risks / trade-offs

- **Indirection vs. greppability.** `grep parse_blur` no longer lands on the
  logic; you read the `@special_specs` row + the interpreter. Accepted for the
  recurring grammar-skeleton dedup; the bound above keeps the claimed payoff
  honest.
- **Deliberately narrow.** Only the 7 pure-fit options convert. `scp`, `car`,
  `background_alpha`, and all bucket B/C/D options stay bespoke, with documented
  triggers for when the optional-boolean and multi-optional facilities should be
  built. This is the conservative reading the review cycles converged on.
