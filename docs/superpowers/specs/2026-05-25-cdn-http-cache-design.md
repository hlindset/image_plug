# CDN HTTP Cache Design

## Scope

ImagePipe should act as a cacheable image origin behind a CDN or local HTTP
cache. The CDN should cache successful transformed responses and serve fresh
entries without contacting ImagePipe. When the source identity names immutable
bytes, the CDN should revalidate stale entries with a conditional request.

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
- internal cache hits can't prepare generated validators or return
  `304 Not Modified`.

## Design Goals

Keep the cache contract path-oriented and deterministic.

Prefer pre-fetch validators for source identities that name immutable bytes. A
request with a matching `If-None-Match` should return `304 Not Modified` before
source fetch, decode, transform, or encode. This path applies when the parsed
plan, request headers, runtime options, and resolved source identity provide all
validator inputs.

Don't make mutable sources long-lived by default. A source adapter should mark a
source's bytes immutable only when its resolved identity names stable bytes or
when host configuration explicitly promises immutability.

Keep HTTP validators separate from internal cache keys. The internal cache key
identifies an ImagePipe storage entry. The `ETag` identifies a client-visible
representation.

Avoid adding a source-fetch metadata path just to support mutable revalidation.
Mutable sources can use short cache lifetimes unless an adapter can provide
freshness metadata during source resolution. A mutable source without freshness
material must not emit a generated `ETag` and must not match
`If-None-Match`.

## Plug Chain Boundaries

ImagePipe is a Plug, so the cache decision sees the `Plug.Conn` after earlier
plugs have run. Earlier plugs may authenticate the request, rewrite path
information, add request headers, load tenant state into assigns, or reject the
request before ImagePipe runs.

ImagePipe should only generate public cache headers from inputs it models
explicitly:

- the request path and query that parser code consumes;
- normalized request headers and cookies configured as cache inputs;
- source identity and source cache semantics returned by the source adapter;
- output policy and representation versions;
- existing response headers that ImagePipe owns or validates.

Plug assigns and `conn.private` are server-side state. A CDN can't vary on them
directly. When they affect source identity or output bytes, the host has three
choices. It can encode the decision into the URL, include it in resolved source
identity, or map it back to explicit `Vary` material. Otherwise it must disable
generated public caching for that route.

Existing response cache headers on the conn are host policy. ImagePipe shouldn't
overwrite an existing `Cache-Control`, `ETag`, `Vary`, or `Last-Modified`
without a decision. It should either check and preserve the host value, merge
where HTTP permits merging, or fail configuration before sending a cacheable
response.

Downstream plugs are outside ImagePipe's validator model. If a later plug can
change the response body, content encoding, `Content-Disposition`,
`Cache-Control`, `ETag`, `Vary`, cookies, or representation metadata, ImagePipe's
generated validators may no longer describe the bytes that reach the client.
For cacheable image responses, route the request so ImagePipe sends the terminal
response. If the host keeps downstream response mutation, host documentation must
state that this turns off generated HTTP cache headers.

## Source Cache Semantics

Add a small source-owned struct:

```elixir
defmodule ImagePipe.Source.CacheSemantics do
  @enforce_keys [:validator, :source_bytes_immutable?]
  defstruct validator: :none,
            source_bytes_immutable?: false,
            response_cache_control_override: nil,
            last_modified: nil
end
```

Add `cache_semantics` to `ImagePipe.Source.Resolved`:

```elixir
%ImagePipe.Source.Resolved{
  adapter: :path,
  source_kind: :path,
  identity: [...],
  internal_cache: :enabled,
  fetch: [...],
  cache_semantics: %ImagePipe.Source.CacheSemantics{...}
}
```

`source_bytes_immutable?` only describes the source bytes. It doesn't mean the
generated response is safe for a shared cache. A private avatar source can be
byte-immutable and still require `private`. It may also need no generated HTTP
cache policy when the response depends on authorization, cookies, tenant
routing, or other non-URL request state.

`validator` is either `{:strong, seed}` or `:none`. The seed must be
deterministic, canonical, and non-secret. Immutable sources can use a canonical
resolved source identity as the seed. If that identity contains credentials,
signed query parameters, temporary tokens, or filesystem details, don't log it.
The adapter must use a stable digest or redacted identity component instead.
Mutable sources must include freshness material, such as an upstream validator or
version identifier. If the adapter can't provide byte-version material during
resolution, it must use `:none`.

`last_modified` is an optional UTC `DateTime` truncated to seconds. ImagePipe
emits it as an IMF-fixdate `Last-Modified` response header. The first
implementation doesn't check `If-Modified-Since`.

Adapter defaults:

- S3 object with `revision`: source bytes immutable. The fetch URL already
  includes `versionId`, so the resolved source names specific bytes. The
  validator seed should include the adapter name and version, endpoint or bucket
  identity, key, and revision. It shouldn't rely on `versionId` being globally
  unique.
- S3 object without `revision`: mutable by default. Hosts can opt into
  immutability if their bucket keys are content-addressed or never overwritten.
- File path: mutable by default and has no validator by default. Hosts can opt
  into immutability when the path space is content-addressed. Skip mutable file
  validators from `mtime` and size in the first implementation. They would add a
  stat/fetch race unless fetch uses the same opened file. Immutable file seeds
  should use a canonical non-secret source identity, not a raw private path.
- HTTP URL: mutable by default. Hosts can opt into immutability when URLs are
  content-addressed or versioned. Mutable HTTP URLs have no generated validator
  unless the adapter later adds explicit upstream freshness metadata during
  resolution. Immutable HTTP URL seeds must not include credentials, signed
  query parameters, or temporary tokens.

Each source adapter should accept:

```elixir
source_bytes_immutable?: boolean()
cache_control: String.t() | nil
```

`cache_control` is host response policy copied through the resolved source. It's
not a source identity fact. The implementation should store it as
`response_cache_control_override` to keep that distinction visible.

When set, ImagePipe emits it only after two checks:

1. The value is safe to send as an HTTP header value.
2. ImagePipe permits the policy for this representation.

Header validation rejects CR, LF, invalid binaries, and values the configured
server adapter can't represent. Policy validation parses directives that
ImagePipe reasons about, including `public`, `private`, `no-store`, `max-age`,
`stale-while-revalidate`, and `immutable`. A `public` override requires a public
cache-safety proof or explicit configuration.

If a source uses `internal_cache: :disabled`, ImagePipe shouldn't emit public
cache validators or generated `Cache-Control` by default. `internal_cache: :disabled`
currently passes request headers that normal cacheable sources strip before
fetch. Those headers can affect source bytes. The first implementation should
not provide an opt-back-in path for `internal_cache: :disabled`. A future opt-in
must require a strong source validator and an explicit complete `Vary`
declaration for every representation-changing request input.

## Internal Source Cache Policy

The current internal cache assumes a cache key names stable output bytes. It has
no freshness check on read. It can serve a cached file-path or URL response
forever if the key still matches and the cache entry remains on disk.

Keep that contract explicit: `Source.Resolved.internal_cache: :enabled` means the
resolved source identity is safe for internal byte reuse. For a mutable source,
the identity is safe only when it includes byte-version material. Examples are
an S3 revision, content-addressed path, upstream validator, or host-provided
cachebuster that changes when bytes change.

Adapt source adapters to choose internal cache policy from source semantics:

- `internal_cache: :auto` should be the source adapter configuration default. It
  resolves to `:enabled` only when the source identity is byte-stable or includes
  byte-version material. Otherwise it resolves to `:disabled`.
- `internal_cache: :disabled` always bypasses the internal encoded-response
  cache.
- `internal_cache: :enabled` is an explicit host assertion that the resolved
  identity is safe for byte reuse. The source may be technically mutable, but the
  host promises that policy prevents mutation under the same identity or accepts
  the stale-cache risk. ImagePipe shouldn't reject this mode just because it
  can't prove immutability.

This keeps the internal cache conservative without adding a source metadata
fetch just to make mutable paths cacheable. A later implementation can add
bounded internal freshness, using `Entry.created_at` and a configured TTL to
treat old entries as misses. That would limit staleness but still wouldn't prove
freshness, so it should be an explicit host policy, not the default.

Adapter implications:

- S3 with `revision` can use `:enabled` because `versionId` is part of the fetch
  and source identity.
- S3 without `revision` should resolve `internal_cache: :auto` to `:disabled` unless
  the host marks keys as content-addressed or supplies a byte-version identity.
- File sources should resolve `internal_cache: :auto` to `:disabled` unless the host
  marks the path space as content-addressed. The first implementation shouldn't
  use `mtime` and size as byte identity unless fetch opens the same file handle
  used for the stat.
- HTTP URL sources should resolve `internal_cache: :auto` to `:disabled` unless
  the URL is content-addressed, versioned, or the adapter resolves an upstream
  validator before cache lookup.

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

ImagePipe emits `Last-Modified` as response metadata and for downstream cache
visibility. The first implementation doesn't use it as a validator. If a CDN or
client sends `If-Modified-Since`, ImagePipe returns the normal `200` path until
explicit `If-Modified-Since` support lands. After that, `If-None-Match` takes
precedence when a request sends both validators.

Generated public cache headers require an explicit safety decision:

```elixir
representation_publicly_cacheable? =
  public_route_or_source? and complete_vary_material?
```

Default generated `Cache-Control` when the representation is public-safe:

- source bytes immutable: `public, max-age=31536000, immutable`
- source bytes mutable: `public, max-age=300, stale-while-revalidate=3600`

The mutable default is intentionally conservative. Hosts that want a different
policy can set `cache_control` on the source adapter.

If public safety isn't proven, ImagePipe should omit generated public
`Cache-Control` by default. A host may explicitly configure a private policy,
such as `private, max-age=300`, for browser-side reuse. Cookie-varying responses
should stay private or opt out of generated HTTP caching unless the host
explicitly accepts `Vary: Cookie` behavior at the CDN.

If the request contains `Authorization`, ImagePipe must not emit generated
public cache headers by default. Configuration must explicitly mark the route or
source as public-cache-safe. It must also include every authorization-derived
representation-changing input in the cache and validator model.

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
  vary: representation_request_material,
  pipeline: representation_version_material
]
```

Only generate an ETag when source cache semantics contain `{:strong, seed}`.
For `:none`, omit `ETag` and skip conditional `If-None-Match` handling.

Generated ETags are instruction-derived strong validators, not body-hash ETags.
They're correct only if the material includes every byte-changing input. That
means source byte identity, transform instructions, output decisions, encoder
settings, normalized request inputs, and versioned dependencies.

Use a strong ETag, not a weak ETag, for generated validators. A weak ETag would
say the response has the same meaning but not necessarily the same bytes.
ImagePipe can treat the encoded image response as byte-identical only when the
ETag material is complete. The representation version must change whenever an
encoder, codec, libvips behavior, metadata policy, default quality, orientation
handling, color-profile behavior, animation handling, or output timestamp
behavior can change bytes.

`output_selection_material` should describe the deterministic representation
instructions:

```elixir
[
  mode: :explicit,
  selected_format: :webp,
  quality: {:quality, 82}
]
```

For automatic or best-format output, the policy should select the output format
from normalized `Accept` and configured format preference when possible. Browser
headers such as this are enough to choose AVIF or WebP before source fetch:

```http
Accept: image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8
```

That path is pre-fetch ETag eligible:

```elixir
[
  mode: :best,
  accept_capability: [:avif, :webp],
  selection_policy: [name: :best_format, version: 1],
  selected_format: :avif,
  quality: :default
]
```

Source alpha doesn't need separate ETag material when the selected target
format supports transparency. AVIF and WebP do. Alpha affects the encoded bytes,
but the source validator already represents the source bytes.

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
bytes across deploys. In that case, the strategy version or representation
version must change with the deploy. For ML-based quality, `model_version: nil`
must suppress generated ETags rather than reuse a validator across model
artifact changes.

Automatic quality can still use a pre-fetch ETag when ImagePipe knows the
selected output format before source fetch. The quality algorithm must be a
deterministic function of immutable source bytes, the canonical plan, and
versioned strategy inputs. The ETag doesn't need the resolved numeric quality in
that case.

It's acceptable for two byte-identical responses to have different ETags when
their deterministic instruction material differs. It's not acceptable for the
same ETag to survive a change that may change bytes.

Increment `etag_schema` only when the shape or interpretation of ETag material
changes. Increment `representation_version` when the encoded bytes may change
while the material shape stays the same.

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

Any non-URL request input that can affect source identity, output bytes, format
selection, or quality selection must appear in `Vary` and ETag material. If it
doesn't, ImagePipe must turn off generated public HTTP caching. This includes
tenant headers, authorization-derived routing, locale, device class, DPR, width
hints, custom source-routing headers, and configured cookies.

`Vary: *` means a cache can't reuse the response for later requests. ImagePipe
should reject it for generated public cache responses or turn off generated
public caching for that representation.

## Pre-Fetch Conditional GET

For cacheable source-byte-immutable responses with a strong source validator,
ImagePipe should compute the ETag before source fetch whenever these inputs
define output selection material:

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
`W/"abc"` and `"abc"` both match `"abc"`. ImagePipe must gate conditional
behavior to `GET` and `HEAD`.

The pre-fetch path must not treat `If-None-Match: *` as a match in the first
implementation. For `GET` and `HEAD`, `*` means any current representation
exists. Before source fetch, ImagePipe hasn't proven that the requested source
exists, that the transform can run, or that output negotiation can succeed. `*`
can return `304` on an internal cache hit because the cached successful entry
proves that a current representation exists for the internal cache key.

A `304 Not Modified` response must have no body and must include the cache
metadata that ImagePipe would send on the corresponding `200`. Use a cache
metadata allowlist:

```elixir
[
  "cache-control",
  "content-location",
  "date",
  "etag",
  "expires",
  "last-modified",
  "surrogate-control",
  "vary"
]
```

The first implementation only emits the subset ImagePipe can produce. The server
adapter normally generates `Date`. Don't replay encoded-body headers such as
`Content-Length`, `Content-Type`, or `Content-Disposition` on `304`. Avoid
representing `304` as a normal encoded response with an empty binary body. Use a
delivery shape such as `{:not_modified, headers}`.

If ImagePipe supports `HEAD`, a non-matching `HEAD` response should send the
headers that the corresponding `GET` would send, without a body. A matching
conditional `HEAD` should return `304` without a body.

HTTP rules used here come from RFC 9110:

- [`If-None-Match`](https://www.rfc-editor.org/rfc/rfc9110.html#name-if-none-match)
  uses weak comparison for `GET` and `HEAD`; `*` matches when a current
  representation exists.
- [`304 Not Modified`](https://www.rfc-editor.org/rfc/rfc9110.html#name-304-not-modified)
  carries cache metadata for the matching `200` response and no response
  content.

Source-dependent output-format decisions opt out of pre-fetch conditional
handling in the first implementation. This applies to modes where the selected
output format depends on source metadata, such as source-format preservation or
source-compatible fallback. Those requests may still use internal cache hits and
normal CDN freshness, but ImagePipe shouldn't claim a pre-fetch `304` path for
them.

## Deferred Behaviors

Keep v1 small. These omissions are intentional:

- `If-Modified-Since`: omitted for scope. ImagePipe may emit `Last-Modified` as
  metadata, but `If-None-Match` is the only conditional validator v1 acts on.
- Late ETags: omitted for scope. If ETag material or selected output format is
  only known after source fetch, decode, or transform, v1 omits the generated
  ETag for that response.
- Source metadata probing for mutable freshness: omitted for scope. Mutable
  sources without revisions use short cache headers, no generated validators, or an
  explicit host promise through `internal_cache: :enabled`.
- Alpha-specific validator material: omitted because source bytes already cover
  alpha. When the chosen output format supports transparency, alpha shouldn't
  add a separate ETag input.
- Static final-alpha inference: omitted for scope. Some transform chains can
  prove final opacity before source fetch, such as an opaque background after
  canvas-changing operations. v1 keeps source-format fallback on the existing
  runtime final-alpha path instead of adding a transform effect system.
- Stored generated ETags in the internal cache: omitted for correctness.
  ImagePipe prepares generated HTTP cache headers from current source, request,
  and policy inputs on each request.
- Pre-fetch `If-None-Match: *`: omitted for correctness. `*` can match on an
  internal cache hit, where a cached successful representation proves existence.
- Public `Vary: Cookie`: off by default. Hosts must opt into this with
  explicit cache policy.
- Surrogate keys and CDN tag purge headers: out of scope for v1. Hosts can set
  those headers outside ImagePipe if they need them.

## Internal Cache Interaction

The internal cache stores encoded response bodies. It shouldn't become the
source of truth for generated HTTP cache headers.

`ImagePipe.Request.Runner` already receives `Source.Resolved` before internal
cache lookup, so cache-hit delivery has the same source cache semantics, plan,
request headers, and runtime options as cache-miss delivery. Use those inputs to
prepare generated HTTP cache headers on every request, including internal cache
hits.

That keeps old internal entries usable after header-policy changes. It also
avoids replaying stale `ETag` or `Cache-Control` values from metadata written by
an older version.

Extend `ImagePipe.Cache.Entry.cacheable_headers/1` to accept these names:

- `vary`
- `cache-control`

These are output-owned headers that already exist today or that host policy may
set before cache storage. Generated `etag`, generated `last-modified`, and
generated `cache-control` should come from `ImagePipe.Request.HTTPCache` at
delivery time, not from the cached entry.

On internal cache hit:

1. Check and normalize the cached entry headers.
2. Prepare generated HTTP cache headers from current source semantics, plan,
   request headers, and options.
3. Merge cached output headers with generated HTTP cache headers. Generated
   headers must not overwrite explicit host policy without the conflict rules
   described in "Plug Chain Boundaries."
4. If the request has `If-None-Match` matching the prepared `etag`, return
   `304 Not Modified` with the cache metadata header allowlist and no body.
   `If-None-Match: *` can match here because the cache entry proves the current
   representation exists.
5. Otherwise return `200` with the cached body and merged response headers.

This preserves header behavior between cache misses and cache hits.

`ImagePipe.Cache.Entry` should only check and store cacheable headers. It
shouldn't own conditional request behavior. The request runner or response
sender should branch to a delivery shape that represents `304`.

The internal cache key doesn't need to include `etag_schema` or
`representation_version` just to protect generated headers, because those
headers come from current request inputs on hit. It only needs those versions if
they also affect encoded bytes. In that case they belong in the existing
canonical key data for output or transform material.

## Error Responses

Only successful encoded responses are cacheable by default.

Parser, planner, source, decode, transform, output negotiation, and encode
errors shouldn't receive generated HTTP cache headers. Explicit error-policy
headers, if a host or later layer sets them, are outside this design.

The first implementation shouldn't add error caching behavior.

## Public Options

Add request options:

```elixir
http_cache: [
  immutable_cache_control: "public, max-age=31536000, immutable",
  mutable_cache_control: "public, max-age=300, stale-while-revalidate=3600",
  etag_version: 1,
  representation_version: 1,
  public_cache?: false
]
```

Keep defaults small and explicit inside `ImagePipe.Request.Options`.

Source adapter options:

```elixir
source_bytes_immutable?: false,
internal_cache: :auto,
cache_control: nil
```

For S3, if `revision` is present, the source can treat the object as immutable
even when `source_bytes_immutable?` isn't set.

## Test Plan

Add focused tests at the request boundary:

- source-byte-immutable public-safe response emits `ETag` and long
  `Cache-Control`;
- public-safe mutable source emits short `Cache-Control`;
- non-public-safe source omits generated public `Cache-Control`;
- request with `Authorization` doesn't get generated public cache headers by
  default;
- source `cache_control` overrides defaults only after header and policy
  validation;
- mutable sources without validators omit `ETag` and never return `304` from
  generated validators;
- `internal_cache: :auto` resolves to `:enabled` for source-byte-immutable
  identities;
- `internal_cache: :auto` resolves to `:disabled` for mutable identities without
  byte-version material;
- `internal_cache: :enabled` accepts mutable identities without byte-version
  material as an explicit host policy promise;
- `internal_cache: :disabled` omits generated HTTP cache headers;
- automatic output emits `Vary: Accept`;
- explicit output doesn't emit `Vary: Accept`;
- configured header-varying output includes that header in `Vary`;
- representation-changing headers missing from `Vary` turn off generated public
  caching or fail configuration;
- cookie-varying output doesn't get public defaults;
- matching `If-None-Match` returns `304` before source fetch for
  source-byte-immutable pre-fetch output;
- matching `If-None-Match` returns before internal cache lookup for
  source-byte-immutable pre-fetch output;
- non-matching `If-None-Match` proceeds normally;
- malformed `If-None-Match` doesn't match;
- weak request tags match generated strong ETags for `GET` and `HEAD`;
- non-`GET` and non-`HEAD` requests don't use conditional response handling;
- `If-None-Match: *` doesn't trigger pre-fetch `304`;
- `If-None-Match: *` can trigger cached `304` on internal cache hit;
- `304` responses include only the cache metadata allowlist and no body;
- `304` responses don't include `Content-Type`, `Content-Length`, or
  `Content-Disposition`;
- when ImagePipe supports `HEAD`, `HEAD` cache misses emit the same cache
  headers as `GET` without a body;
- when ImagePipe supports `HEAD`, matching conditionals return `304` without a
  body;
- internal cache hits preserve cached output headers such as `vary`;
- internal cache hits prepare generated `etag`, `cache-control`, and
  `last-modified` from current request inputs;
- internal cache hits can return `304` from the prepared `etag`;
- transform option order variants produce the same ETag;
- changing source revision changes ETag;
- changing `etag_schema` changes ETag;
- changing representation version changes ETag;
- old internal cache entries don't replay stale generated ETags after
  representation version changes.

Add source adapter tests:

- S3 with revision marks source bytes immutable and keeps `versionId` fetch;
- S3 without revision is mutable and skips internal cache under
  `internal_cache: :auto` unless configured source-byte-immutable;
- File source defaults mutable without a validator and host config can mark
  source bytes immutable;
- HTTP source defaults mutable without a validator and host config can mark
  source bytes immutable;
- source validator seeds redact or digest secret identity material.

Add property tests for ETag material:

- raw `Accept` spelling differences that normalize to the same capability
  produce the same ETag material;
- `If-None-Match` matching handles weak tags, comma-separated tags, and
  whitespace;
- ImagePipe rejects unsupported or non-cacheable header values before response
  send;
- ImagePipe rejects `Cache-Control` overrides containing CR or LF;
- ImagePipe rejects invalid `Vary` values or turns off generated public caching;
- duplicate `Vary` values merge deterministically;
- `Vary: *` turns off generated public caching;
- ETag material serialization is deterministic.

## Rollout

Build this in small steps:

1. Add source cache semantics struct and source adapter options.
2. Add request-owned HTTP cache header computation and unit tests.
3. Add pre-run conditional handling after source resolution and before
   `Runner.run/4`.
4. Attach generated headers to cache misses while continuing to store only
   cacheable output headers in internal cache entries.
5. Recompute generated headers and support cached `304` on internal cache hits.
6. Document CDN behavior and source immutability configuration.

The first implementation shouldn't add post-transform conditional validation.
If deterministic instruction material can't describe a future output mode, that
mode should opt out of pre-fetch validation until the design makes its inputs
explicit and versioned.
