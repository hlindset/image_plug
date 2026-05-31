# imgproxy option grammar simplification

**Date:** 2026-05-31
**Status:** Design — reviewed (two parallel subagent cycles + catalog analysis), scope finalized
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

Make adding a regular imgproxy option a small, low-risk, data-shaped change, and
centralize arity/empty-arg/error handling so it is implemented once. This is a
compatibility parser tracking an external product's option catalog, so the
dominant future cost is safely adding more options.

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

## Scope (finalized: 8 options)

Two earlier review cycles plus an analysis of imgproxy's full unimplemented
option catalog (below) settled the scope:

- **Convert the 7 single-required-arg pipeline options** — `blur`, `sharpen`,
  `pixelate`, `dpr`, `brightness`, `contrast`, `saturation` — via a declarative
  `@special_specs` table + `interpret_special/3`. (Already done in a working-tree
  spike: 174 parser/property/wire tests green, credo `--strict` clean,
  `--warnings-as-errors` compile.)
- **Convert `strip_color_profile`/`scp`** via a separate minimal
  single-optional-boolean facility (`@optional_boolean_specs` +
  `interpret_optional_boolean/3`), shaped so the future boolean cluster
  (`raw`, `enforce_thumbnail`, `preserve_hdr`) is a one-row addition each.
- **`crop_aspect_ratio`/`car` is NOT converted.** Its leading-required +
  optional-trailing shape is the only thing that would force absent-vs-empty
  range logic into a shared interpreter; for a single option that is not worth
  the complexity. It stays bespoke unchanged.
- **`background_alpha` stays bespoke** — its arity/empty failures use the
  option-specific `{:invalid_background_alpha, args}` tag (pinned by tests), not
  the uniform `{:invalid_option_segment}`.

## Catalog-informed rationale

Why this scope, from imgproxy's documented processing-option catalog (sources:
docs.imgproxy.net/usage/processing, /generating_the_url). Of the **unimplemented**
options, bucketed by the parsing mechanism each needs:

| Bucket | Mechanism needed | Count | Non-Pro |
| --- | --- | --- | --- |
| A. Fixed-arity (`max_bytes`, `dpi`, `page`, `watermark_size`, …) | none — a `@special_specs` row | 15 | 5 |
| B. Single optional-boolean (`raw`, `enforce_thumbnail`, `preserve_hdr`, `disable_animation`) | `@optional_boolean_specs` row | 4 | 3 |
| C. Multi optional-trailing (`adjust`, `trim`, `unsharp_masking`, `gradient`, `*_options`) | a general multi-optional interpreter | 9 | 1 (`trim`) |
| D. Irregular (`watermark`, `style`, `skip_processing`, detections) | bespoke | ~14 | 3 |

This is the justification for the design:

- **Bucket A (15 options) is the real payoff of the schema** and needs no new
  mechanism — each is a future one-line `@special_specs` row. This is why the
  table approach is worth adopting at all.
- **Bucket B is a genuine but small non-Pro cluster (3 future + `scp` now).** A
  *minimal* single-optional-boolean facility serves it cheaply; a general
  `default:`/range interpreter would be overkill. Hence the dedicated tiny table
  rather than extending `interpret_special/3`.
- **Bucket C is overwhelmingly Pro (8 of 9)** and its one non-Pro member
  (`trim`) is heterogeneously typed. A general multi-optional interpreter is
  deferred until/unless the Pro encoding/color options are prioritized — added
  then, with real data points, per the project's "add it when the caller
  appears" discipline.

## Approach

### `@special_specs` — fixed-arity options (spike, done)

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
`{:ok, keyword_assignments}`. An unknown `type` atom raises via `apply_type/2`'s
missing clause, by design (trusted internal dispatch).

### `@optional_boolean_specs` — single optional booleans (new, minimal)

```elixir
@optional_boolean_specs %{
  "strip_color_profile" => {:strip_color_profile, true},
  "scp"                 => {:strip_color_profile, true},
  # future one-liners: "raw" => {:raw, false},
  #   "enforce_thumbnail" => {:enforce_thumbnail, false},
  #   "preserve_hdr" => {:preserve_hdr, true}
}
```

`interpret_optional_boolean({key, default}, args, segment)` — exactly three cases,
reproducing the current `parse_strip_color_profile/2` behavior:

- `[]` (option present, no value) → `{:ok, [{key, default}]}`.
- `[value]` with `value != ""` → `parse_boolean(value)`, propagating
  `{:invalid_boolean, value}` on failure.
- anything else (`[""]`, `[_, _ | _]`) → `{:error, {:invalid_option_segment, segment}}`.

No arity range arithmetic, no absent-vs-empty distinction beyond these three
clauses. Adding a future boolean option is one table row; its default is a
pre-parsed literal. `apply_type` is not involved (the handler calls
`parse_boolean/1` directly).

### Dispatch

`parse_pipeline_option/3` (introduced in the spike) is the single entry for
non-`@option_specs` options. Lookup order:

1. `@special_specs` → `interpret_special/3`
2. `@optional_boolean_specs` → `interpret_optional_boolean/3`
3. fall through to the remaining bespoke `parse_special_option/3` clauses

One dispatch path, three handler kinds. Each table is small and single-purpose.

### Options that stay bespoke (and why)

`background_alpha` (option-specific arity tag), `crop_aspect_ratio` (leading-req +
optional, would force range logic for one option), `auto_rotate`/`rotate`/`flip`
(nest under `:orientation`; `rotate` mod-90 transform; `flip` two-bool collapse;
all have zero-arg forms), `extend`/`extend_aspect_ratio` (bool + gravity
sub-grammar + injected constant), `monochrome`/`duotone` (nested keyword +
optional colors), `background`/`zoom` (alternative shapes / fan-out),
`padding`/`gravity`/`crop`/`filename` (variadic sub-grammars), and `resize`/`size`
+ `format_quality` (existing `parse_known_option/4` clauses).

### Spec-table divergence, deliberately

After this change the parser has small declarative tables —
`@option_specs`/`parse_field` (resize/format/quality family),
`@special_specs`/`apply_type` (fixed-arity specials), and
`@optional_boolean_specs` (optional booleans) — each purpose-clear. They are not
unified now: forcing `resize`/`size`'s irregular merge into a shared table would
be over-generalization. Unify only if a third regular-option family appears or a
table needs another's capability. Documented so the divergence is a bounded,
known decision, not silent drift.

## Error model

| Failure | Tag |
| --- | --- |
| Fixed-arity: wrong arity / empty arg | `{:invalid_option_segment, segment}` |
| Fixed-arity: value parse failure | value parser's own tag (`:invalid_non_negative_float`, `:invalid_positive_float`, `:invalid_adjustment`, …) |
| Optional-boolean: `scp` / `scp:1` / `scp:0` | success (`true` / parsed bool) |
| Optional-boolean: `scp:` / `scp:1:2` | `{:invalid_option_segment, segment}` |
| Optional-boolean: `scp:bad` | `{:invalid_boolean, "bad"}` (from `parse_boolean/1`) |

Matches current behavior for all 8 converted options exactly.

## Testing

Treat the existing suites as the spec; convert green-to-green. Primary spec files:

- `test/parser/imgproxy/option_grammar_test.exs` — **primary**: exact
  `{:ok, {:pipeline, [...]}}` tuples + error tags, incl. the
  `invalid_pipeline_arity_segments/0` arity table.
- `test/parser/imgproxy/options_test.exs`, `.../plan_builder_test.exs` — plan-layer
  pins (e.g. brightness/contrast/saturation, dpr).
- `test/parser/imgproxy_test.exs`, `.../imgproxy_property_test.exs`,
  `test/image_pipe/imgproxy_wire_conformance_test.exs` — wire/behavior contracts.

**Pins to add at the `OptionGrammar.parse/1` boundary _before_ converting** (each
confirmed genuinely missing at that boundary in review):

- `dpr`: `dpr:0` → `{:error, {:invalid_positive_float, "0"}}` and a fractional
  success (`dpr:1.5`). Type semantics currently unpinned.
- `strip_color_profile`/`scp`: bare `scp` → `{:ok, {:pipeline, [strip_color_profile: true]}}`;
  `scp:0`/`scp:1` → flat bool; `scp:` → `{:invalid_option_segment, ...}`;
  `scp:bad` → `{:invalid_boolean, "bad"}`. (Wire tests exercise `scp:0`/`scp:1`
  only; the bare/default-true and empty/invalid edges are unpinned at `parse/1`.)
- `brightness`/`contrast`/`saturation`: tighten existing out-of-range assertions
  from loose `{:error, _}` to the exact `{:invalid_adjustment, value}` tag.

**One property to add:** alias-equivalence over the converted long/short pairs
(`blur`/`bl`, `sharpen`/`sh`, `pixelate`/`pix`, `brightness`/`br`, `contrast`/`co`,
`saturation`/`sa`, `strip_color_profile`/`scp`) — `parse(long:v) == parse(short:v)`
over valid and invalid `v`, mirroring the existing `zoom`/`z` property. No
arity-fuzz property: the explicit arity table covers edges.

**Tests not to write / not to delete:**

- New cases are forward contract pins at `parse/1` (tagged tuples are public
  contract). No old-vs-new parity/characterization harnesses.
- No name-policing: do not assert `function_exported?` on deleted `parse_blur/2`
  etc. The `parse/1`-level suites are the sole proof.
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
  architecture-test changes needed.
- Interpreters are trusted internal dispatch; arity/empty checks validate
  untrusted URL input (a real boundary), not impossible internal misuse.

## Risks / trade-offs

- **Indirection vs. greppability.** `grep parse_blur` no longer lands on the
  logic; you read the table row + the interpreter. Accepted: the marginal cost of
  the next fixed-arity option (15 of them in the catalog) drops to one table row.
- **Three small tables.** Each is single-purpose and tiny; bounded by the
  documented unify-trigger. Preferred over one mixed table or over deepening
  `interpret_special/3` with optional-range logic.
- **Deferred mechanisms.** `crop_aspect_ratio`'s leading-req+optional shape and
  bucket C's multi-optional-trailing options are intentionally not built now;
  the catalog shows bucket C is Pro-heavy, so the trigger to build a general
  multi-optional interpreter is "the Pro encoding/color options get prioritized."
