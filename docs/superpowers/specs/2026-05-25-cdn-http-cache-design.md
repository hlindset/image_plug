# CDN HTTP Cache Design

## Scope

ImagePipe should work as an image origin behind a CDN or local HTTP cache. The
CDN caches successful transformed responses by URL and serves fresh entries
without contacting ImagePipe.

V1 covers:

- `Cache-Control`
- `ETag`
- `Vary: Accept`
- `If-None-Match`

V1 doesn't cover source freshness probing, `Last-Modified`,
`If-Modified-Since`, arbitrary request-header variation, Client Hints, or
post-transform validators. "Deferred Behaviors" names these omissions so they
stay explicit.

This doesn't replace the existing internal encoded-response cache. The
internal cache avoids recomputing inside ImagePipe. HTTP cache headers tell
browsers, CDNs, and reverse proxies how to cache ImagePipe responses.

## Current State

ImagePipe already has a deterministic internal cache key in
`ImagePipe.Cache.Key`. That key includes resolved source identity, canonical
plan operation data, output negotiation inputs, configured key headers,
configured key cookies, cachebuster data, schema version, and transform key data
version.

`Plan.expires` doesn't exist yet. If ImagePipe adds it for signed URL
compatibility, it should be a parser-level request validity timestamp, not HTTP
cache freshness. A parser should reject expired URLs before source resolution,
but generated `Cache-Control` must not derive `max-age` from `Plan.expires`.

ImagePipe already emits `Vary: Accept` for automatic output and stores selected
response headers in internal cache entries.

The missing CDN-facing behavior is:

- successful responses don't get a generated `ETag`;
- successful responses don't get a generated `Cache-Control`;
- source adapters don't expose enough source byte identity for HTTP validators;
- `If-None-Match` can't return `304 Not Modified`;
- internal cache hits can't prepare generated ETags or return
  `304 Not Modified`.

## Design Goals

Keep the cache contract path-oriented and deterministic.

Generated public HTTP caching is for public image routes. ImagePipe shouldn't
try to make authenticated, per-user, per-tenant, cookie-selected, or arbitrary
header-selected image behavior CDN-cacheable in v1. If host code outside the
image request model changes image bytes, use `http_cache: :disabled`.

Prefer pre-fetch ETags for source identities that name stable bytes. A request
with a matching `If-None-Match` should return `304 Not Modified` before source
fetch, decode, transform, encode, or internal cache lookup.

Keep HTTP validators separate from internal cache keys. The internal cache key
identifies an ImagePipe storage entry. The `ETag` identifies a client-visible
representation.

Don't add a source metadata request just to support mutable revalidation.
Mutable sources can still use the internal cache when the host explicitly
promises stable byte reuse, but v1 generated ETags require a strong byte
identity known during source resolution.

## Plug Chain Boundaries

ImagePipe is a Plug, so the cache decision sees the `Plug.Conn` after earlier
plugs have run. Earlier plugs may authenticate the request, rewrite path
information, add request headers, load host state into assigns, or reject the
request before ImagePipe runs.

ImagePipe should only generate shared-cache headers when `http_cache` is
`:enabled`. That mode is a host promise about the route. The request should
already suit a CDN cache key. The URL, source resolution, output negotiation,
and ImagePipe options should determine the image bytes.

ImagePipe doesn't forward incoming `Cookie` headers to source requests and does
not put raw cookies into generated HTTP cache material. A browser request cookie
doesn't change generated cache behavior by itself. If earlier host code uses a
cookie, authorization state, tenant state, assigns, or `conn.private` to choose
source identity or output bytes, generated public caching is out of scope for
that route.

Downstream plugs are outside ImagePipe's ETag model. If a later plug can change
the response body, content encoding, `Content-Disposition`, `Cache-Control`,
`ETag`, `Vary`, cookies, or other representation metadata, ImagePipe's generated
ETags may no longer describe the bytes that reach the client. For generated
HTTP caching, route the request so ImagePipe sends the terminal response.

Existing response cache headers are host policy. ImagePipe must not overwrite an
existing `Cache-Control` or `ETag`. For `Vary`, ImagePipe may merge `Accept`
into an existing value when automatic output depends on `Accept`. If an
existing or generated `Vary` contains `*`, v1 suppresses generated public cache
headers for that response.

If the response has `Set-Cookie`, v1 suppresses generated public cache headers.
That shouldn't occur on a normal public image route, but the rule keeps the
failure mode conservative.

Provider and parser modules don't set HTTP cache policy. Future parser-level
fields such as `Plan.expires`, plus URL cachebuster values, affect request
validity and cache keys, not response `Cache-Control`.

## Source Cache Semantics

Add a small source-owned struct:

```elixir
defmodule ImagePipe.Source.CacheSemantics do
  @enforce_keys [:byte_identity, :stable?]
  defstruct byte_identity: :none,
            stable?: false
end
```

Add `cache_semantics` to `ImagePipe.Source.Resolved`:

```elixir
%ImagePipe.Source.Resolved{
  adapter: :path,
  source_kind: :path,
  identity: [...],
  http_cache: :inherit,
  internal_cache: :enabled,
  fetch: [...],
  cache_semantics: %ImagePipe.Source.CacheSemantics{...}
}
```

`stable?` means the resolved source identity names stable bytes. This can come
from a versioned identity, a content-addressed path space, or host configuration
that promises bytes don't change under the same identity. It isn't an HTTP cache
policy by itself.

`byte_identity` is either `{:strong, seed}` or `:none`.

The source resolver sets `byte_identity`. Hosts can force ETag creation by
configuring the source as `stable?: true`. The adapter should then derive a
strong byte identity from the resolved source identity. Don't add a separate
`force_etag?: true` option. The host promise is about source stability, and the
ETag follows from that.

The seed must be deterministic, canonical, and non-secret. A resolved source
identity may contain credentials, signed query parameters, temporary tokens, or
private filesystem details. In that case, the adapter must use a stable digest
or redacted identity component instead of exposing raw material in logs or
diagnostics.

Adapter defaults:

- S3 object with `revision`: stable. The fetch URL already includes
  `versionId`, so the resolved source names specific bytes. The byte identity
  seed should include adapter name and version, endpoint or bucket identity, key,
  and revision. Don't rely on `versionId` being globally unique.
- S3 object without `revision`: not stable by default. Hosts can set
  `stable?: true` for content-addressed keys or write-once buckets.
- File path: not stable by default. Hosts can set `stable?: true` when the path
  space is content-addressed or write-once. V1 shouldn't use `mtime` and size as
  byte identity; that adds a stat/fetch race unless fetch uses the same opened
  file.
- HTTP URL: not stable by default. Hosts can set `stable?: true` for
  content-addressed or versioned URLs. Mutable upstream HTTP validators are
  deferred.

Each source adapter should accept:

```elixir
stable?: boolean()
http_cache: :inherit | :disabled | :enabled
internal_cache: :auto | :enabled | :disabled
```

`http_cache` on `Source.Resolved` is the source adapter's response-cache
override. `:inherit` uses the request option. `:disabled` and `:enabled`
override the request option for that resolved source.

Resolve the effective mode with source precedence:

```elixir
case resolved.http_cache do
  :inherit -> request_options.http_cache.mode
  override -> override
end
```

Source-level `http_cache: :enabled` is the force switch for generated HTTP cache
headers on that source. It still requires byte identity. When the host promises
that source bytes are stable by policy, configure `stable?: true`. The adapter
then derives `byte_identity: {:strong, seed}` from the resolved source identity.
With both `stable?: true` and `http_cache: :enabled`, ImagePipe can generate the
long `Cache-Control` and ETag. `http_cache: :enabled` alone doesn't force
cacheable headers when `byte_identity` is `:none`, when the response has
`Set-Cookie`, or when another v1 suppression rule applies.

## Internal Source Cache Policy

The current internal cache assumes a cache key names stable output bytes. It has
no freshness check on read. It can serve a cached file-path or URL response
forever if the key still matches and the cache entry remains on disk.

Keep that contract explicit: `Source.Resolved.internal_cache: :enabled` means
the resolved source identity is safe for internal byte reuse.

`internal_cache: :auto` should be the source adapter configuration default. It
resolves to `:enabled` when the resolved source identity is stable or includes
explicit byte-version material. Otherwise it resolves to `:disabled`.

`internal_cache: :disabled` always bypasses the internal encoded-response cache.

`internal_cache: :enabled` is an explicit host assertion that the resolved
identity is safe for byte reuse. The source may be technically mutable, but the
host promises that policy prevents mutation under the same identity or accepts
the stale-cache risk. ImagePipe shouldn't reject this mode just because it
can't prove stability.

Adapter implications:

- S3 with `revision` can use `:enabled` because `versionId` is part of the fetch
  and source identity.
- S3 without `revision` should resolve `internal_cache: :auto` to `:disabled`
  unless the host marks keys as stable.
- File sources should resolve `internal_cache: :auto` to `:disabled` unless the
  host marks the path space as stable.
- HTTP URL sources should resolve `internal_cache: :auto` to `:disabled` unless
  the URL is content-addressed, versioned, or marked stable by the host.

## Response Cache Headers

Add a pure module under the request boundary, tentatively
`ImagePipe.Request.HTTPCache`.

This module needs source cache semantics, plan key data, output selection
material, request headers, and request options. Keeping it under
`ImagePipe.Request` preserves the existing boundary direction.
`ImagePipe.Response` should send already-prepared status codes and headers.

An explicit mode controls generated HTTP cache headers:

- `:disabled`: emit no generated `Cache-Control` or `ETag`. Preserve explicit
  host headers that already exist on the conn.
- `:enabled`: emit generated public shared-cache headers when byte identity
  material is complete.

For v1, `:enabled` with `byte_identity: {:strong, seed}` emits generated public
cache headers:

```elixir
[
  {"cache-control", "public, max-age=31536000, immutable"},
  {"etag", ~s("ip1-...")}
]
```

When automatic output uses `Accept`, the response also carries:

```elixir
{"vary", "Accept"}
```

The request or mount options should configure the default `Cache-Control`.
V1 has one generated cache-control value. Mutable short public caching stays
deferred.

If `http_cache: :enabled` but `byte_identity` is `:none`, v1 emits
`Cache-Control: no-store` and no generated `ETag`, unless a host already set
`Cache-Control`. This avoids a half-cacheable mutable path where the CDN can
store bytes but ImagePipe can't produce a validator.

Don't merge `Cache-Control` values. Directives can conflict, such as `private`
with `public`, or two different `max-age` values. If a host already set
`Cache-Control`, preserve it and suppress generated `Cache-Control`.
If the selected or existing `Cache-Control` contains `no-store`, suppress the
generated ETag.

## ETag Material

Don't use `ImagePipe.Cache.Key.hash` as the public `ETag`.

The internal key includes storage and origin concerns. Those fields are useful
for safe internal reuse but too coupled for an HTTP validator.

Use separate ETag material:

```elixir
[
  etag_schema: 1,
  source: source_byte_identity_seed,
  plan: canonical_plan_key_data,
  output: output_selection_material,
  accept: normalized_accept_material,
  representation: representation_version
]
```

For explicit output with no `Accept` dependency, use `accept: []`.

Only generate an ETag when:

- the effective `http_cache` mode is `:enabled`;
- `byte_identity` is `{:strong, seed}`;
- ImagePipe can select output before source fetch;
- automatic quality, if used later, has complete deterministic version material;
- the response doesn't already have an `ETag`;
- the selected cache policy isn't `no-store`.

V1 conditional handling only uses ImagePipe-generated ETags. ImagePipe keeps
existing host ETags but doesn't interpret them for `If-None-Match`.

V1 only expects strong byte identity from source identities that name stable
bytes. Future adapters may provide strong byte identity for mutable sources when
source resolution obtains byte-version freshness material before fetch. A weak
upstream validator, such as an HTTP `W/"..."` ETag, must not become
`{:strong, seed}` unless the adapter has other material that proves source byte
identity.

Generated ETags are instruction-derived strong validators, not body-hash ETags.
They're correct only if the material includes every byte-changing input:
source byte identity, transform instructions, output decisions, encoder
settings, normalized `Accept`, and versioned dependencies.

Serialize ETag material with a deterministic encoder supported by ImagePipe's
supported Erlang/OTP versions, then hash it with SHA-256. Don't expose raw
material in the header. The visible tag shape should include a schema prefix:

```http
ETag: "ip1-<base64url-sha256>"
```

Use a strong ETag, not a weak ETag, for generated ETags. A weak ETag would say
the response has the same meaning but not necessarily the same bytes. The
representation version must change whenever an encoder, codec, libvips behavior,
metadata policy, default quality, orientation handling, color-profile behavior,
animation handling, or output timestamp behavior can change bytes.

It's acceptable for two byte-identical responses to have different ETags when
their deterministic instruction material differs. It isn't acceptable for the
same ETag to survive a change that may change bytes.

Increment `etag_schema` only when the shape or interpretation of ETag material
changes. Increment `representation_version` when the encoded bytes may change
while the material shape stays the same.

## Accept Normalization

Reduce `Accept` to ImagePipe's output capability model before it enters ETag or
internal cache material.

For current automatic output:

```http
Accept: image/avif,image/webp
```

That header and a header that prefers WebP with quality `1` and AVIF with
quality `0.1` both normalize to the same selected format when ImagePipe's policy
chooses AVIF.

Don't store the raw `Accept` header in ETag material. Store either the selected
format or the normalized capability list used by the selection policy.

ImagePipe must emit `Vary: Accept` whenever response format selection depends
on `Accept`. CDN cache keys are URL-oriented unless configured otherwise.

V1 doesn't support generated public caching for arbitrary request headers that
change source identity or output bytes. This includes image profile headers,
locale, device class, tenant headers, and custom source-routing headers. Use
`http_cache: :disabled` for those routes.

Client Hints such as `DPR`, `Width`, `Viewport-Width`, `Sec-CH-DPR`, and
`Sec-CH-Width` are out of scope for v1 generated public caching. They're
client-controlled headers. Supporting them later requires a bounded model:
explicit opt-in, accepted header names, normalization or clamping,
`Vary` emission, CDN cache-key documentation, and ETag material that uses the
normalized value.

## Pre-Fetch Conditional GET

For requests whose effective `http_cache` mode is `:enabled` and whose source
semantics contain strong byte identity, ImagePipe should compute the ETag before
source fetch whenever these inputs define output selection material:

- parsed plan;
- source cache semantics from `Source.resolve/3`;
- normalized `Accept`;
- runtime output options;
- deterministic policy versions.

This pre-run conditional decision belongs after `Source.resolve/3` and before
`Runner.run/4`. A matching ETag must skip internal cache lookup and source
fetch.

On matching `If-None-Match`, ImagePipe returns:

```http
304 Not Modified
ETag: "ip1-..."
Cache-Control: public, max-age=31536000, immutable
Vary: Accept
```

`Vary: Accept` appears only when automatic output depends on `Accept`.

No source fetch, decode, transform, encode, internal cache lookup, or internal
cache write should occur after the match.

`If-None-Match` parsing must handle comma-separated entity tags. For `GET`, use
weak comparison with ImagePipe's generated strong ETag: `W/"abc"` and `"abc"`
both match `"abc"`. ImagePipe must gate conditional behavior to methods it
serves as cacheable image reads. V1 defers HEAD support unless the current Plug
path already serves HEAD.

V1 ignores `If-None-Match: *`. Before source fetch, ImagePipe hasn't proven
that the requested source exists, that the transform can run, or that output
negotiation can succeed. A later version can add the wildcard path if a real
caller needs it.

A `304 Not Modified` response must have no body and must include the cache
metadata that ImagePipe would send on the corresponding `200`. Use a small cache
metadata allowlist:

```elixir
[
  "cache-control",
  "date",
  "etag",
  "expires",
  "vary"
]
```

The server adapter normally generates `Date`. Don't replay encoded-body
headers such as `Content-Length`, `Content-Type`, or `Content-Disposition` on
`304`. Avoid representing `304` as a normal encoded response with an empty
binary body. Use a delivery shape such as `{:not_modified, headers}`.

HTTP rules used here come from RFC 9110:

- [`If-None-Match`](https://www.rfc-editor.org/rfc/rfc9110.html#name-if-none-match)
  uses weak comparison for `GET` and `HEAD`; `*` matches when a current
  representation exists.
- [`304 Not Modified`](https://www.rfc-editor.org/rfc/rfc9110.html#name-304-not-modified)
  carries cache metadata for the matching `200` response and no response
  content.

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

These are output-owned or host-owned headers that may already exist before
cache storage. Generated `etag` and generated `cache-control` should come from
`ImagePipe.Request.HTTPCache` at delivery time, not from the cached entry.

On internal cache hit:

1. Check and normalize the cached entry headers.
2. Prepare generated HTTP cache headers from current source semantics, plan,
   request headers, and options.
3. Merge cached output headers with generated HTTP cache headers. Generated
   headers must not overwrite explicit host policy.
4. If the request has `If-None-Match` matching the prepared `etag`, return
   `304 Not Modified` with cache metadata headers and no body.
5. Otherwise return `200` with the cached body and merged response headers.

This preserves header behavior between cache misses and cache hits.

`ImagePipe.Cache.Entry` should only check and store cacheable headers. It should
not own conditional request behavior. The request runner or response sender
should branch to a delivery shape that represents `304`.

The internal cache key doesn't need to include `etag_schema` just to protect
generated headers, because those headers come from current request inputs on
hit. It only needs `representation_version` if that version also affects encoded
bytes. In that case the version belongs in the existing canonical key data for
output or transform material.

## Error Responses

Only successful encoded responses are cacheable by default.

Parser, planner, source, decode, transform, output negotiation, and encode
errors shouldn't receive generated HTTP cache headers. Explicit error-policy
headers, if a host or later layer sets them, are outside this design.

The first implementation shouldn't add error caching behavior.

## Options

Add request options:

```elixir
http_cache: [
  mode: :disabled,
  cache_control: "public, max-age=31536000, immutable",
  representation_version: 1
]
```

Keep defaults small and explicit inside `ImagePipe.Request.Options`.
Keep `etag_schema` as an implementation constant, not a request option.

Source adapter options:

```elixir
stable?: false,
internal_cache: :auto,
http_cache: :inherit
```

For S3, if `revision` is present, the source can treat the object as stable even
when `stable?` isn't set.

## Deferred Behaviors

These omissions are intentional. Don't reintroduce them during implementation
review without a new design note:

- `Last-Modified` and `If-Modified-Since`: v1 acts only on `If-None-Match`.
- Mutable short public caching: v1 generated public cache headers require strong
  byte identity.
- Source metadata probing for mutable freshness: v1 doesn't issue `HEAD`,
  `stat`, or upstream metadata requests just to build validators.
- Source-provided response `Cache-Control`: v1 policy comes from ImagePipe
  request or mount options, not parser/provider/source output.
- Arbitrary request-header `Vary`: v1 only generates `Vary: Accept` for
  automatic output.
- Late ETags: if ETag material or selected output format is only known after
  source fetch, decode, or transform, v1 omits the generated ETag.
- Alpha-specific ETag material: source bytes already cover alpha when the chosen
  output format supports transparency.
- Static final-alpha inference: v1 keeps source-format fallback on the existing
  runtime final-alpha path instead of adding a transform effect system.
- `If-None-Match: *`: v1 ignores the wildcard form.
- HEAD response support: out of scope unless the current Plug path already
  serves HEAD.
- Cookie-varying public output: ImagePipe ignores incoming request cookies for
  generated HTTP caching and source fetches. Hosts that use cookies to choose
  image bytes should use `http_cache: :disabled`.
- Client Hints for generated public caching: unsigned headers such as `DPR`,
  `Width`, and `Sec-CH-Width` can fragment a CDN cache if clients vary them.
- Surrogate keys and CDN tag purge headers: hosts can set those headers outside
  ImagePipe if they need them.

## Test Plan

Add focused tests at the request boundary:

- `http_cache: :disabled` emits no generated `Cache-Control` or `ETag`;
- stable `http_cache: :enabled` response emits `ETag` and configured
  `Cache-Control`;
- `http_cache: :enabled` with `byte_identity: :none` emits
  `Cache-Control: no-store` and no generated `ETag`;
- request `Cookie` doesn't enter generated `Vary`, ETag material, or source
  fetches;
- response with `Set-Cookie` disables generated public cache headers in v1;
- automatic output emits `Vary: Accept`;
- explicit output doesn't emit `Vary: Accept`;
- Client Hints don't enter generated public cache headers, `Vary`, or ETag
  material in v1;
- `Plan.expires` doesn't change generated `Cache-Control`;
- `cachebuster` remains URL/cache-key material, not response cache policy;
- matching `If-None-Match` returns `304` before source fetch for output with a
  strong byte identity;
- matching `If-None-Match` returns before internal cache lookup for output with a
  strong byte identity;
- non-matching `If-None-Match` proceeds normally;
- malformed `If-None-Match` doesn't match;
- weak request tags match generated strong ETags for `GET`;
- non-cacheable methods don't use conditional response handling;
- `If-None-Match: *` doesn't trigger `304` in v1;
- `304` responses include only cache metadata and no body;
- `304` responses don't include `Content-Type`, `Content-Length`, or
  `Content-Disposition`;
- internal cache hits preserve cached output headers such as `vary`;
- internal cache hits prepare generated `etag` and `cache-control` from current
  request inputs;
- internal cache hits can return `304` from the prepared `etag`;
- internal cache hits recompute ETags with the current representation version;
- existing host `ETag` suppresses generated ETag;
- ImagePipe preserves existing host `ETag`, but it doesn't trigger generated
  `304` handling in v1;
- existing host `Cache-Control` suppresses generated `Cache-Control`;
- existing host `Cache-Control: no-store` suppresses generated ETags;
- existing `Vary` merges with generated `Accept`;
- existing `Vary: *` turns off generated public headers in v1;
- transform option order variants produce the same ETag;
- changing source revision changes ETag;
- changing the implementation `etag_schema` constant changes ETag;
- changing representation version changes ETag;
- old internal cache entries don't replay stale generated ETags after
  representation version changes.

Add source adapter tests:

- S3 with revision marks the source stable and keeps `versionId` fetch;
- S3 without revision isn't stable and skips internal cache under
  `internal_cache: :auto` unless configured stable;
- File source defaults to not stable and host config can mark it stable;
- HTTP source defaults to not stable and host config can mark it stable;
- byte identity seeds redact or digest secret identity material.

Add property tests for ETag material:

- raw `Accept` spelling differences that normalize to the same capability
  produce the same ETag material;
- raw `Accept` spelling differences that normalize to the same selected output
  produce the same internal cache output material;
- `If-None-Match` matching handles weak tags, comma-separated tags, and
  whitespace;
- ETag material serialization is deterministic.

## Rollout

Build this in small steps:

1. Add source cache semantics struct and source adapter options.
2. Add request-owned HTTP cache header computation and unit tests.
3. Add pre-run conditional handling after source resolution and before
   `Runner.run/4`.
4. Add generated-header delivery for cache misses and cache hits in one deploy.
   Cache hits should recompute generated headers from current request inputs;
   internal cache entries should continue to store only cacheable output headers.
   Splitting this across rolling deploys can produce nodes with different header
   behavior.
5. Add cached `304` handling after generated headers are available on hits.
6. Document how to enable `http_cache: :enabled`, how to mark sources stable,
   expected CDN cache-key settings, and stable-versus-mutable source behavior.

The first implementation shouldn't add post-transform conditional validation.
If deterministic instruction material can't describe a future output mode, that
mode should opt out of pre-fetch validation until the design makes its inputs
explicit and versioned.
