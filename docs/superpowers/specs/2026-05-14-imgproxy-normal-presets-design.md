# Imgproxy Normal Presets Design

Date: 2026-05-14

## Scope

This slice adds normal imgproxy processing URL preset support to
`ImagePlug.Parser.Imgproxy`. It excludes presets-only mode, info endpoint
presets, preset file loading, environment-variable parity, and adding transform
or output options only because a preset references them.

The compatibility target is imgproxy's normal processing URL behavior:

- `preset` and `pr` parse one or more preset names in one option segment.
- Configured named presets expand into normal processing options.
- A configured `default` preset applies automatically to every normal
  processing request before URL options.
- Presets may reference other presets.
- Recursive preset references are rejected before cache lookup or origin fetch.
- Presets may contain pipeline separators (`-`) when their semantics can be
  merged into ImagePlug's existing pipeline groups.

Source references used for this design:

- `/Users/hlindset/src/image_plug/local/imgproxy-docs/usage/presets.mdx`
- `/Users/hlindset/src/image_plug/local/imgproxy-docs/usage/processing.mdx`
- `/Users/hlindset/src/image_plug/local/imgproxy-docs/features/chained_pipelines.mdx`
- `/Users/hlindset/src/image_plug/local/imgproxy-docs/configuration/options.mdx`
- `/Users/hlindset/src/image_plug/local/imgproxy-master/options/parser/presets.go`
- `/Users/hlindset/src/image_plug/local/imgproxy-master/options/parser/processing_options.go`
- `/Users/hlindset/src/image_plug/local/imgproxy-master/options/parser/url_options.go`
- `/Users/hlindset/src/image_plug/local/imgproxy-master/options/parser/apply.go`

The local imgproxy chained-pipelines docs are marked Pro and describe presets
containing `-`. The local non-Pro source tree does not include that parser
behavior: the current `options/parser/presets.go` parser rejects `-` because
`options/parser/url_options.go` treats a segment without an argument separator
as the start of the source URL. This design deliberately follows the documented
Pro chained-pipeline compatibility behavior because the requested ImagePlug
slice explicitly includes preset definitions containing `-` when they can map
cleanly to existing pipeline groups.

## Architecture

Presets remain parser-layer compatibility syntax. Expansion happens after
signature verification and before source identity resolution, cache lookup, or
origin fetch. Expanded output is the same parser request model that direct URL
options already produce, and `ImagePlug.Parser.Imgproxy.PlanBuilder` continues
to produce a product-neutral `ImagePlug.Plan`.

No preset name is stored in `ImagePlug.Plan`, runtime state, output
negotiation, transform state, or cache data. Cache keys continue to be built
from resolved origin identity, canonical plan fields, configured vary inputs,
and normalized automatic-output data. Equivalent requests that differ only by
using a preset versus spelling out the expanded options should produce the same
cache key.

The parser boundary may gain parser-owned modules such as
`ImagePlug.Parser.Imgproxy.Presets`, but runtime, cache, origin, response, and
transform boundaries must not depend on imgproxy preset structs or names.

## Configuration

Add `:presets` under the existing `:imgproxy` parser options:

```elixir
ImagePlug.init(
  parser: ImagePlug.Parser.Imgproxy,
  root_url: "https://origin.example",
  imgproxy: [
    presets: %{
      "default" => "rt:fill/el:1",
      "thumb" => "rs:fit:120:120",
      "sharp-thumb" => "pr:thumb/q:82",
      "responsive" => "w:900/-/w:450"
    }
  ]
)
```

Accepted preset definitions are string-keyed maps from non-empty preset names
to non-empty slash-separated normal processing option strings. Values use the
current ImagePlug imgproxy grammar: option segments are separated by `/`, option
arguments are separated by `:`, pipeline groups are separated by `-`, and
recognized no-argument processing options such as `ar` and `fl` keep the same
meaning they have in direct ImagePlug imgproxy URLs.

This slice deliberately does not support imgproxy's
`IMGPROXY_PRESETS`, `IMGPROXY_PRESETS_SEPARATOR`, `IMGPROXY_PRESETS_PATH`,
or preset env/file loading behavior. It also does not support custom argument
separators.

Configuration validation should tokenize preset definitions at
`ImagePlug.init/1` time so malformed preset definitions and preset graph cycles
fail at startup. It should reject:

- non-map `:presets`
- non-binary or empty preset names
- non-binary or empty preset values
- preset values containing malformed preset syntax, such as empty `preset`/`pr`
  arguments or other shapes that cannot be represented as option groups
- recursive preset references, including cycles that involve `default`

Validation should not reject a preset only because it contains a non-preset
option that is currently unsupported by ImagePlug. Unsupported non-preset
options are rejected only when that preset is used and the expanded option flows
through the same parser path as direct URL options. This intentionally differs
from local imgproxy startup validation, which applies all configured presets at
startup. ImagePlug is a greenfield library with a smaller supported API surface;
unused compatibility presets should not force support or startup failure for
options ImagePlug does not yet implement.

## Parsing And Expansion

`preset` and `pr` are recognized parser options, not transform operations. They
accept one or more non-empty preset names:

```text
preset:thumb
pr:thumb:sharp
```

When a normal processing request is parsed:

1. Verify the signature.
2. Split option segments from the source path.
3. Start the request option accumulator with an automatic expansion of
   `default` if a preset named `default` is configured.
4. Parse URL option segments left to right.
5. When a `preset` or `pr` segment is encountered, expand each referenced
   preset in argument order at that point in the current pipeline context.
6. Build `ImagePlug.Parser.Imgproxy.ParsedRequest`.
7. Build `ImagePlug.Plan`.

Automatic `default` expansion uses the same group-aware merge model as an
explicit preset at the beginning of the first URL pipeline group. If
`default=w:900/-/w:450`, then `/w:100/-/h:200/plain/...` semantically expands
as `/w:100/-/w:450/h:200/plain/...`: the first URL group can override the first
default group, and later default groups are queued at the start of later URL
groups or become trailing groups if the URL has fewer groups.

Unknown preset names return a parser error such as `{:unknown_preset, name}`.
Direct and indirect recursion return a parser error such as
`{:recursive_preset, path}`, where `path` describes the cycle encountered.
These parser errors render as existing 400 parser failures and occur before
origin or cache side effects.

Runtime expansion should still track the active preset stack even though
configuration validation rejects cycles. That keeps `parse/2` robust if future
callers provide already-tokenized preset data or bypass `ImagePlug.init/1`.

Unsupported options inside a used preset are handled exactly like unsupported
options in a URL. For example, a used `sharp=sharpen:0.7` preset remains a 400
parser failure until ImagePlug supports `sharpen` as a product-neutral
operation. The preset feature does not silently ignore unsupported options.

## Pipeline Merge Semantics

ImagePlug should support preset definitions containing pipeline separators when
it can match imgproxy's documented merge rules:

- A preset is applied to the pipeline where it is used.
- A preset may contain chained pipelines.
- Chained pipelines from the preset and from the URL are merged.

The expansion model is group-aware rather than raw string substitution. A preset
definition is parsed into one or more groups separated by `-`. When the preset
is used in the current URL group, its first group is applied to the current
pipeline accumulator. Later preset groups are queued to merge with subsequent
URL groups. A queued preset group is applied at the start of the next URL group,
before that URL group's own option segments, so later URL assignments can
override preset assignments in the same group. If queued preset groups remain
after the URL options end, they become trailing pipeline groups.

This matches the imgproxy documentation example. Given:

```text
test=width:300/height:300/-/width:200/height:200/-/width:100/height:200
```

and:

```text
width:400/-/preset:test/width:500/-/width:600
```

the semantic expansion is:

```text
width:400/-/width:500/height:300/-/width:600/height:200/-/width:100/height:200
```

Within each merged pipeline group, ImagePlug's existing conflict resolution
continues to apply: aliases normalize to canonical fields, and later
assignments in that group win. Global fields such as output format, quality,
cachebuster, expiration, filename, and response disposition remain global and
continue to resolve by last assignment across groups.

Empty groups created by leading, trailing, or repeated `-` separators retain the
current ImagePlug behavior: empty pipeline groups are ignored unless there are
queued preset groups to merge.

## Error Handling

Preset errors are parser errors. They use the existing `handle_error/2` path and
return HTTP 400 for normal parser failures.

Required failures:

- Missing preset name in `preset` or `pr` returns
  `{:invalid_option_segment, segment}`.
- Unknown preset returns `{:unknown_preset, name}`.
- Direct recursion, such as `a=pr:a`, returns
  `{:recursive_preset, ["a", "a"]}` or an equivalent cycle-bearing error.
- Indirect recursion, such as `a=pr:b` and `b=pr:a`, returns
  `{:recursive_preset, ["a", "b", "a"]}` or an equivalent cycle-bearing error.
- Unsupported options in a used preset return the same unsupported option errors
  as direct URL usage.
- Parser and planner validation failures return before origin fetch and cache
  lookup.

ImagePlug intentionally differs from current upstream imgproxy on recursion:
local imgproxy code warns and skips recursive re-entry, while this slice rejects
recursive preset references because the requested ImagePlug contract requires a
pre-side-effect rejection.

## Test Plan

Add focused ExUnit coverage for parser behavior:

- `preset` and `pr` expand configured named presets.
- `pr:thumb:sharp` applies multiple presets in order.
- `default` applies automatically before URL options.
- URL options can override fields set by `default`.
- Presets can reference other presets.
- Unknown presets fail before plan construction.
- Direct and indirect recursive presets fail.
- Unsupported options inside a used preset fail with parser errors.
- Presets with pipeline separators merge with URL pipeline groups using the
  imgproxy documented example.
- Empty pipeline groups keep current behavior around preset queues.

Add request-safety coverage:

- Unknown or recursive preset requests return before cache lookup and origin
  fetch.
- A used preset containing unsupported options returns before cache lookup and
  origin fetch.

Add cache-key coverage:

- A request using a preset and an equivalent request spelling out the expanded
  options produce identical cache key data and hash for the same origin
  identity.
- Cache key data does not contain configured preset names.
- `cachebuster` remains the explicit way to vary cache keys for changed preset
  definitions that would otherwise expand to the same canonical plan.

Update docs:

- `docs/imgproxy_support_matrix.md`: mark normal processing named presets,
  multiple preset arguments, default preset, recursion rejection, and pipeline
  preset merging as supported or partial as appropriate. Keep presets-only mode,
  info endpoint presets, file loading, and environment-variable parity out of
  scope or missing.
- `docs/imgproxy_path_api.md`: document configuration shape, `preset`/`pr`
  grammar, default expansion, pipeline merge behavior, error behavior, and cache
  key semantics.

## Non-Goals

- Presets-only mode.
- Info endpoint presets.
- Preset file loading.
- Environment-variable parity.
- Custom argument separators.
- Runtime/cache representation of preset names.
- Transform or output support for currently unsupported imgproxy options merely
  because a preset references them.
- Product-specific preset concepts in `ImagePlug.Plan`.

## Open Decisions

No open design decisions remain for this slice. Implementation details such as
exact private module names and exact parser error tuple names may vary, but the
public behavior above should be preserved.
