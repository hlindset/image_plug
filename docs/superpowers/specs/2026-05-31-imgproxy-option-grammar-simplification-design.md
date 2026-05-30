# imgproxy option grammar simplification

**Date:** 2026-05-31
**Status:** Design — awaiting review
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
- No cache-key data-version bump (parser output is unchanged; per project
  guidelines, greenfield cache shape is reshaped in place, and here it is not
  even changing).
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
}
```

Each alias maps to an ordered list of arg specs. An arg spec is:

- `{key, type}` — required, non-empty; or
- `{key, type, opts}` where `opts` may carry:
  - `default:` — value used when this (trailing) arg is absent or empty,
    making the arg optional;
  - `error:` — an option-specific error tag substituted when the value parser
    fails, for options whose diagnostic differs from the type's canonical tag.

`type` is an atom dispatched by `apply_type/2` to an existing value parser
(`:non_neg_float` → `parse_non_negative_float/1`, etc.). The value parsers are
unchanged; most already emit their own canonical error tag, so `error:` is only
needed where the option historically wraps a generic failure into a specific tag
(e.g. `background_alpha` → `:invalid_background_alpha`).

### Interpreter

`interpret_special/3` (validated by the spike, plus the two extensions above):

1. Split args into required vs optional (trailing-with-`default`).
2. Arity outside `[required_count, total_count]`, or an empty value in a
   required position → `{:error, {:invalid_option_segment, segment}}` (the
   uniform "shape is wrong" tag the bespoke parsers already return).
3. Fill absent/empty optional args from their `default`.
4. Run each value through `apply_type/2`; on failure, return the arg's `error:`
   override if present, else propagate the type parser's tag.
5. Return `{:ok, keyword_assignments}`; `parse_pipeline_option/3` wraps it as
   `{:pipeline, assignments}` exactly as before.

The interpreter does **not** grow alternative-shape (`one_of`), output-nesting,
post-combination, or fan-out constructs. That boundary is deliberate (see below).

### Options the schema absorbs

- **Spike (done):** `blur`, `sharpen`, `pixelate`, `dpr`, `brightness`,
  `contrast`, `saturation`.
- **Per-arg error override:** `background_alpha` (single arg, value failure →
  `:invalid_background_alpha`). Exercises the `error:` capability.
- **Optional-trailing-with-default:** `strip_color_profile` (optional bool,
  default `true`), `crop_aspect_ratio` (required ratio + optional enlarge bool,
  default `false`).

Target: ~10 of the ~25 special options, plus the once-written interpreter.

### Options that stay bespoke (and why)

Each carries logic a flat key→value schema cannot express without adding a
construct used by essentially one option — which would be net more complexity,
not less:

- **Output-shape transforms / nesting / constants:** `extend`,
  `extend_aspect_ratio` (bool + optional gravity tail + `extend_requested: true`
  constant), `auto_rotate`, `rotate`, `flip` (assignments nested under
  `:orientation`; `rotate` mod-90 normalization; `flip` combines two bools).
- **Nested keyword + optional colors:** `monochrome`, `duotone`.
- **Alternative shapes / fan-out:** `background` (empty | hex | `r:g:b`), `zoom`
  (1 arg fans to `zoom_x`+`zoom_y`, or 2 args).
- **Variadic sub-grammars:** `padding` (1–4 values with `:unset` holes),
  `gravity`/`crop` (anchor enum vs. focal-point vs. offset tuple),
  `filename` (percent-encoded vs. base64 variant).
- **`resize`/`size`** (the `Enum.split` + extend-gravity merge) and
  `format_quality` (pair into a map) keep their existing `parse_known_option/4`
  clauses.

### Dispatch

`parse_pipeline_option/3` (introduced in the spike) is the single entry for
non-`@option_specs` options: `@special_specs` lookup → `interpret_special/3`,
else fall through to the remaining `parse_special_option/3` clauses. One path,
two handler kinds.

The `@option_specs` regulars already run through the declarative
`parse_known_option` → `parse_field` path and are **out of scope**; unifying that
table with `@special_specs` is a possible later follow-on, not part of this work.

## Error model

| Failure | Tag |
| --- | --- |
| Wrong arity / empty required arg | `{:invalid_option_segment, segment}` |
| Value parse failure, no `error:` override | the value parser's own tag (e.g. `:invalid_non_negative_float`) |
| Value parse failure, with `error:` override | `{error_tag, value}` (e.g. `:invalid_background_alpha`) |

This matches current behavior for every converted option exactly.

## Testing

- TDD against the **existing** specs: `test/parser/imgproxy_test.exs`,
  `test/parser/imgproxy_property_test.exs`, and
  `test/image_pipe/imgproxy_wire_conformance_test.exs`. Green-to-green; no test
  rewrites except deletion of any that become redundant duplicates.
- Each converted option keeps its existing coverage; if an option's error-tag or
  arity edge isn't already asserted, add a focused parser-level case before
  converting it.
- Gate before finishing: `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`
  (via `mise exec --`).

## Boundaries / guideline compliance

- Stays entirely within `ImagePipe.Parser.Imgproxy.*` — no cross-namespace
  change, no concrete transform modules referenced, no plan-model change.
- Per CLAUDE.md test guidance: no impossible-internal-misuse tests, no
  name-policing tests, no post-migration parity pins. The interpreter is trusted
  internal dispatch; missing/unknown types in `@special_specs` are a programmer
  error and may raise rather than being guarded.

## Risks / trade-offs

- **Indirection vs. greppability.** `grep parse_blur` no longer lands on the
  logic; you read the `@special_specs` row + the interpreter. Real cost,
  accepted because the marginal cost of the next regular option drops to ~one
  table row. Mitigated by keeping the interpreter small and the bespoke set
  explicit.
- **Scope honesty.** The spike showed the clean-fit set is ~10 options, not
  "most of them" — the rest have output-shape logic that does not belong in a
  flat schema. The design caps the interpreter's capabilities deliberately
  rather than chasing every option.
