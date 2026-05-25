# CDN HTTP Cache Design

## Scope

ImagePipe should act as a cacheable image origin behind a CDN or local HTTP
cache. The CDN should cache successful transformed responses and serve fresh
entries without contacting ImagePipe. When the source identity is immutable, the
CDN should revalidate stale entries with a conditional request.

This design covers response headers and request handling for:

- `ETag`
- `Cache-Control`
- `Vary`
- `Last-Modified`
- `If-None-Match`

It doesn't replace the existing internal encoded-response cache. The internal
cache avoids recomputing inside ImagePipe. HTTP cache headers tell browsers,
CDNs, and reverse proxies how to cache ImagePipe responses.

## Current State

ImagePipe already has a deterministic internal cache key in
`ImagePipe.Cache.Key`. That key includes resolved source identity, canonical
plan operation data, output negotiation inputs, configured key headers,
configured key cookies, cachebuster data, schema version, and transform key data
version.

ImagePipe also preserves `Vary: Accept` for automatic output and stores
`vary`/`cache-control` headers in internal cache entries.

The missing CDN-facing behavior is:

- successful responses don't get a generated `ETag`;
- successful responses don't get a default `Cache-Control`;
- source adapters don't expose HTTP cache semantics;
- `Last-Modified` isn't represented;
- `If-None-Match` can't return `304 Not Modified`;
- internal cache hits can't preserve or check validators because cached
  entries don't store `etag` or `last-modified`.

## Design Goals

Keep the cache contract path-oriented and deterministic.

Prefer pre-fetch validators for immutable sources. A request with a matching
`If-None-Match` should return `304 Not Modified` before source fetch, decode,
transform, or encode. This path applies when the parsed plan, request headers,
runtime options, and resolved source identity provide all validator inputs.

Don't make mutable sources long-lived by default. A source adapter should mark a
source immutable only when its resolved identity names stable bytes or when host
configuration explicitly promises immutability.

Keep HTTP validators separate from internal cache keys. The internal cache key
identifies an ImagePipe storage entry. The `ETag` identifies a client-visible
representation.

Avoid adding a source-fetch metadata path just to support mutable revalidation.
Mutable sources can use short cache lifetimes unless an adapter can provide
freshness metadata during source resolution. A mutable source without freshness
material must not emit a generated `ETag` and must not match
`If-None-Match`.

## Source Cache Semantics

Add a small source-owned struct:

```elixir
defmodule ImagePipe.Source.CacheSemantics do
  @enforce_keys [:validator, :immutable?]
  defstruct validator: :none,
            immutable?: false,
            cache_control_override: nil,
            last_modified: nil
end
```

Add `cache_semantics` to `ImagePipe.Source.Resolved`:

```elixir
%ImagePipe.Source.Resolved{
  adapter: :path,
  source_kind: :path,
  identity: [...],
  cache: :normal,
  fetch: [...],
  cache_semantics: %ImagePipe.Source.CacheSemantics{...}
}
```

`validator` is either `{:strong, seed}` or `:none`. The seed must be
deterministic and safe to serialize. Immutable sources can use the resolved
source identity as the seed. Mutable sources must include freshness material,
such as an upstream validator or version identifier. If the adapter can't
provide byte-version material during resolution, it must use
`:none`.

`last_modified` is an optional UTC `DateTime` truncated to seconds. ImagePipe
emits it as an IMF-fixdate `Last-Modified` response header. The first
implementation doesn't check `If-Modified-Since`.

Adapter defaults:

- S3 object with `revision`: immutable. The fetch URL already includes
  `versionId`, so the resolved source names specific bytes.
- S3 object without `revision`: mutable by default. Hosts can opt into
  immutability if their bucket keys are content-addressed or never overwritten.
- File path: mutable by default and has no validator by default. Hosts can opt
  into immutability when the path space is content-addressed. Skip mutable file
  validators from `mtime` and size in the first implementation. They would add a
  stat/fetch race unless fetch uses the same opened file.
- HTTP URL: mutable by default. Hosts can opt into immutability when URLs are
  content-addressed or versioned. Mutable HTTP URLs have no generated validator
  unless the adapter later adds explicit upstream freshness metadata during
  resolution.

Each source adapter should accept:

```elixir
immutable?: boolean()
cache_control: String.t() | nil
```

`cache_control` is host policy copied through the resolved source. It's not a
source identity fact. When set, ImagePipe emits it exactly after validating that
it's a legal HTTP header value.

If a source uses `cache: :skip`, ImagePipe shouldn't emit public
cache validators or generated `Cache-Control` by default. `cache: :skip`
currently passes request headers that normal cacheable sources strip before
fetch. Those headers can affect source bytes. Hosts can opt back into HTTP cache
headers only by supplying deterministic identity and `Vary` material for every
representation-changing request input.

## Response Cache Headers

Add a pure module under the request boundary, tentatively
`ImagePipe.Request.HTTPCache`.

This module needs source cache semantics, plan key data, output selection
material, request headers, and request options. Keeping it under
`ImagePipe.Request` preserves the existing boundary direction. `ImagePipe.Response`
should send already-prepared status codes and headers.

It should compute response headers from:

- source cache semantics;
- canonical plan key data;
- output selection material;
- configured output/cache version material;
- existing response headers from output policy, such as `Vary: Accept`;
- configured representation-changing headers, when the config admits them.

The result should be a normalized header list:

```elixir
[
  {"etag", ~s("...")},
  {"cache-control", "public, max-age=31536000, immutable"},
  {"vary", "Accept"}
]
```

When `last_modified` is present:

```elixir
{"last-modified", "Mon, 25 May 2026 12:00:00 GMT"}
```

Default `Cache-Control`:

- immutable source: `public, max-age=31536000, immutable`
- mutable source: `public, max-age=300, stale-while-revalidate=3600`

The mutable default is intentionally conservative. Hosts that want a different
policy can set `cache_control` on the source adapter.

The `public` defaults apply only when the representation is independent of
user-specific request state, or when the response declares all
representation-changing request headers in `Vary` and ETag material.
Cookie-varying responses shouldn't be public by default.

## ETag Material

Don't use `ImagePipe.Cache.Key.hash` as the public `ETag`.

The internal key includes storage and origin concerns, such as schema version,
selected configured headers/cookies, and cache adapter key inputs. Those fields
are useful for safe internal reuse but too coupled for an HTTP validator.

Use separate ETag material:

```elixir
[
  etag_schema: 1,
  source: source_validator_seed,
  plan: canonical_plan_key_data,
  output: output_selection_material,
  pipeline: output_pipeline_version_material
]
```

Only generate an ETag when source cache semantics contain `{:strong, seed}`.
For `:none`, omit `ETag` and skip conditional `If-None-Match` handling.

`output_selection_material` should describe the deterministic representation
instructions:

```elixir
[
  mode: :explicit,
  selected_format: :webp,
  quality: {:quality, 82}
]
```

For automatic or best-format output when the policy can select the format before
source fetch:

```elixir
[
  mode: :best,
  accept_capability: [:avif, :webp],
  selection_policy: [name: :best_format, version: 1],
  selected_format: :avif,
  quality: :default
]
```

For future automatic quality:

```elixir
[
  quality: [
    mode: :auto,
    strategy: :dssim,
    strategy_version: 1,
    model_version: nil
  ]
]
```

If automatic quality uses ML, the model artifact version must be present. If a
quality strategy depends on libvips or codec behavior, it may change output
bytes across deploys. In that case, the strategy version or output pipeline
version must change with the deploy.

Automatic quality can still use a pre-fetch ETag when ImagePipe knows the
selected output format before source fetch. The quality algorithm must be a
deterministic function of immutable source bytes, the canonical plan, and
versioned strategy inputs. The ETag doesn't need the resolved numeric quality in
that case.

It's acceptable for two byte-identical responses to have different ETags when
their deterministic instruction material differs. It's not acceptable for the
same ETag to survive a change that may change bytes.

## Accept Normalization

Reduce `Accept` to ImagePipe's output capability model before it enters ETag or
internal cache material.

For current automatic output:

```elixir
Accept: image/avif,image/webp
```

That header and a header that prefers WebP with quality 1 and AVIF with quality
0.1 both normalize to the same selected format when ImagePipe's policy chooses
AVIF.

Don't store the raw `Accept` header in the ETag material. Store either the
selected format or the normalized capability list used by the selection policy.

ImagePipe must still emit `Vary: Accept` whenever response format selection
depends on `Accept`. CDN cache keys are URL-oriented unless configured
otherwise.

Any other request header that can affect source identity, output bytes, format
selection, or quality selection must also appear in `Vary` and ETag material.
Cookie-varying representations should stay private or opt out of generated
public HTTP caching unless the host explicitly accepts `Vary: Cookie` behavior
at the CDN.

## Pre-Fetch Conditional GET

For cacheable immutable sources with a strong source validator, ImagePipe should
compute the ETag before source fetch whenever these inputs define output
selection material:

- the parsed plan;
- source cache semantics from `Source.resolve/3`;
- normalized `Accept`;
- runtime output options;
- deterministic policy versions.

This pre-run conditional decision belongs after `Source.resolve/3` and before
`Runner.run/4`. A matching validator must skip internal cache lookup and
source fetch.

On matching `If-None-Match`, ImagePipe returns:

```http
304 Not Modified
ETag: "..."
Cache-Control: public, max-age=31536000, immutable
Vary: Accept
```

No source fetch, decode, transform, encode, internal cache lookup, or internal
cache write should occur after the match.

`If-None-Match` parsing must handle `*` and comma-separated entity tags. For
`GET` and `HEAD`, use weak comparison with ImagePipe's generated strong ETag:
`W/"abc"` and `"abc"` both match `"abc"`. The first implementation only needs
conditional behavior for methods ImagePipe already serves.

A `304 Not Modified` response must have no body and must include the cache
metadata that ImagePipe would send on the corresponding `200`: `ETag`,
`Cache-Control`, `Vary`, and `Last-Modified` when present. Don't replay
encoded-body headers such as `Content-Length`, `Content-Type`, or
`Content-Disposition` on `304`.

Source-dependent output decisions opt out of pre-fetch conditional handling in
the first implementation. This includes automatic fallback paths that need the
source format or final alpha state before choosing JPEG or PNG. Those requests
may still use internal cache hits and normal CDN freshness, but ImagePipe should
not claim a pre-fetch `304` path for them.

## Internal Cache Interaction

The internal cache should store the CDN-facing headers with successful encoded
entries.

Extend `ImagePipe.Cache.Entry.cacheable_headers/1` to accept these names:

- `vary`
- `cache-control`
- `etag`
- `last-modified`

On internal cache hit:

1. Check the cached entry and headers.
2. If the request has `If-None-Match` matching the cached `etag`, return
   `304 Not Modified` with the cache metadata header allowlist and no body.
3. Otherwise return `200` with the cached body and cached response headers.

This preserves header behavior between cache misses and cache hits.

`ImagePipe.Cache.Entry` should only check and store cacheable headers. It
shouldn't own conditional request behavior. The request runner or response
sender should branch to a delivery shape that represents `304`.

## Error Responses

Only successful encoded responses are cacheable by default.

Parser, planner, source, decode, transform, output negotiation, and encode
errors shouldn't receive public long-lived cache headers. If an error response
gets cache headers, it should use `Cache-Control: no-store`.

The first implementation doesn't need to add error caching behavior.

## Public Options

Add request options:

```elixir
http_cache: [
  immutable_cache_control: "public, max-age=31536000, immutable",
  mutable_cache_control: "public, max-age=300, stale-while-revalidate=3600",
  etag_version: 1,
  output_version: 1
]
```

Keep defaults small and explicit inside `ImagePipe.Request.Options`.

Source adapter options:

```elixir
immutable?: false,
cache_control: nil
```

For S3, if `revision` is present, the source can treat the object as immutable
even when `immutable?` isn't set.

## Test Plan

Add focused tests at the request boundary:

- immutable source emits `ETag` and long `Cache-Control`;
- mutable source emits short `Cache-Control`;
- source `cache_control` overrides defaults;
- mutable sources without validators omit `ETag` and never return `304` from
  generated validators;
- `cache: :skip` omits generated public cache headers unless explicitly opted
  back in;
- automatic output emits `Vary: Accept`;
- explicit output doesn't emit `Vary: Accept`;
- matching `If-None-Match` returns `304` before source fetch for immutable
  pre-fetch output;
- matching `If-None-Match` returns before internal cache lookup for immutable
  pre-fetch output;
- non-matching `If-None-Match` proceeds normally;
- internal cache hits preserve `etag`, `cache-control`, `vary`, and
  `last-modified`;
- internal cache hits can return `304` from stored `etag`;
- transform option order variants produce the same ETag;
- changing source revision changes ETag;
- changing output policy version changes ETag.

Add source adapter tests:

- S3 with revision marks cache semantics immutable and keeps `versionId` fetch;
- S3 without revision is mutable unless configured immutable;
- File source defaults mutable without a validator and host config can make it
  immutable;
- HTTP source defaults mutable without a validator and host config can make it
  immutable.

Add property tests for ETag material:

- raw `Accept` spelling differences that normalize to the same capability
  produce the same ETag material;
- `If-None-Match` matching handles weak tags, comma-separated tags, whitespace,
  and `*`;
- ImagePipe rejects unsupported or non-cacheable header values before response
  send;
- ETag material serialization is deterministic.

## Rollout

Build this in small steps:

1. Add source cache semantics struct and source adapter options.
2. Add request-owned HTTP cache header computation and unit tests.
3. Add pre-run conditional handling after source resolution and before
   `Runner.run/4`.
4. Attach headers to cache misses and store the same headers in internal cache
   entries in the same change.
5. Replay headers and support cached `304` on internal cache hits.
6. Document CDN behavior and source immutability configuration.

The first implementation shouldn't add post-transform conditional validation.
If deterministic instruction material can't describe a future output mode, that
mode should opt out of pre-fetch validation until the design makes its inputs
explicit and versioned.
