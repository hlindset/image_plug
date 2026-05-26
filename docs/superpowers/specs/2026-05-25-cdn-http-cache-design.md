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

`Plan.expires` already exists on `ImagePipe.Plan`, but it has no runtime cache
effect. Keep it that way for HTTP cache policy. It's a parser-level request
validity timestamp, not HTTP cache freshness. A parser may reject expired URLs
before source resolution, but generated `Cache-Control` must not derive
`max-age` from `Plan.expires`.

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

Provider and parser modules don't set HTTP cache policy. Parser-level fields
such as `Plan.expires`, plus URL cachebuster values, affect request validity
and cache keys, not response `Cache-Control`.

## Source Cache Semantics

Add a small source-owned struct:

```elixir
defmodule ImagePipe.Source.CacheSemantics do
  @enforce_keys [:byte_identity, :stable?]
  defstruct @enforce_keys
end
```

Enforce the fields because each adapter must make the byte-identity
decision explicit.

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

Add `cache_semantics` to `Source.Resolved.@enforce_keys` so adapters can't omit
it.

`stable?` means the resolved source identity names stable bytes. This can come
from a versioned identity, a content-addressed path space, or host configuration
that promises bytes don't change under the same identity. It isn't an HTTP cache
policy by itself.

`byte_identity` is either `{:strong, seed}` or `:none`.

The source resolver sets `byte_identity`. Hosts can force ETag creation by
configuring the source as `stable: :trusted`. The adapter should then derive a
strong byte identity from the resolved source identity. The host promise is
about source stability, and the ETag follows from that.

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
  `stable: :trusted` for content-addressed keys or write-once buckets.
- File path: not stable by default. Hosts can set `stable: :trusted` when the path
  space is content-addressed or write-once. V1 shouldn't use `mtime` and size as
  byte identity; that adds a stat/fetch race unless fetch uses the same opened
  file.
- HTTP URL: not stable by default. Hosts can set `stable: :trusted` for
  content-addressed or versioned URLs. Mutable upstream HTTP validators are
  deferred. HTTP byte identity must not reuse raw signed query parameters or
  temporary credentials. If the stable identity needs query material, use a
  canonical redacted value or a digest over stable components.

Each source adapter should accept:

```elixir
stable: :auto | :trusted
http_cache: :inherit | :disabled | :enabled
internal_cache: :auto | :enabled | :disabled
```

`stable: :auto` lets the adapter mark sources stable only when it can prove byte
stability from the resolved identity. `stable: :trusted` is the host promise
that source bytes are stable by policy.

Adapters map the config values to resolved semantics like this:

- `stable: :auto` plus adapter-proven stability resolves to `stable?: true`.
- `stable: :auto` without adapter-proven stability resolves to `stable?: false`.
- `stable: :trusted` resolves to `stable?: true`.

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
that source bytes are stable by policy, configure `stable: :trusted`. The adapter
then derives `byte_identity: {:strong, seed}` from the resolved source identity.
With both `stable: :trusted` and `http_cache: :enabled`, ImagePipe can generate the
long `Cache-Control` and ETag. `http_cache: :enabled` alone doesn't force
cacheable headers when `byte_identity` is `:none`, when the response has
`Set-Cookie`, or when another v1 suppression rule applies.

### Source Resolved Migration

The current `ImagePipe.Source.Resolved` struct has `cache: :normal | :skip`.
V1 should migrate that field to `internal_cache: :enabled | :disabled`.

Mapping:

- `cache: :normal` becomes `internal_cache: :enabled`.
- `cache: :skip` becomes `internal_cache: :disabled`.

This breaking rename touches source adapters, `ImagePipe.Request.Runner`, tests,
and any pattern match on `%Source.Resolved{cache: ...}`. The project hasn't
shipped, so prefer the clearer field name over a compatibility shim.

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

Keep `stable` and `internal_cache` separate. `stable` is about public validator
truth: can ImagePipe generate an ETag that names response bytes for shared
caches? `internal_cache` is about local byte reuse: is the host willing to serve
an existing encoded body for the same internal key, including any accepted
staleness risk? A route can use the internal cache without exposing a generated
ETag.

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

The main API should return a prepared value, not only a header list:

```elixir
%ImagePipe.Request.HTTPCache.Prepared{
  representation_headers: [{"vary", "Accept"}],
  headers: [{"cache-control", "..."}, {"etag", "..."}],
  etag: ~s("ip1-...") | nil
}
```

`representation_headers` are correctness headers. Always apply them. For
example, automatic output still needs `Vary: Accept` when ImagePipe suppresses
generated `Cache-Control` and `ETag`. `headers` are the optional CDN-facing
policy and validator headers. `etag` is non-nil only when ImagePipe generated
the ETag and can interpret `If-None-Match`.

Build this value in `ImagePipe.Plug` after `Source.resolve/3` and before
`Runner.run/4`, then pass it through delivery for normal `200` responses. That
matches the current code shape: cache-hit delivery doesn't carry
`Source.Resolved`.

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

V1 has one generated cache-control value:
`public, max-age=31536000, immutable`. Keep it as an implementation constant.
Mutable short public caching stays deferred.

If `http_cache: :enabled` but `byte_identity` is `:none`, v1 emits
`Cache-Control: no-store` and no generated `ETag`, unless a host already set
`Cache-Control`. This avoids a half-cacheable mutable path where the CDN can
store bytes but ImagePipe can't produce a validator. Treat `no-store` here as a
safety signal: the route opted into generated HTTP caching, but the source did
not produce byte identity. Emit telemetry for this fallback so operators can
spot a bad route configuration. A low-cardinality log event can supplement
telemetry, but it isn't a substitute.

Emit low-cardinality HTTP cache telemetry for:

- `[:image_pipe, :http_cache, :prepare]`: effective mode, byte identity kind,
  and whether ImagePipe emitted an ETag;
- `[:image_pipe, :http_cache, :conditional, :match]`: conditional request
  matches;
- `[:image_pipe, :http_cache, :fallback, :no_store]`: the `no-store` fallback,
  with `%{adapter: resolved.adapter, source_kind: resolved.source_kind,
  reason: :missing_byte_identity}`;
- `[:image_pipe, :http_cache, :cache_hit, :headers]`: cache-hit delivery using
  freshly prepared HTTP cache headers.

Keep metadata low-cardinality. Don't include source identity, paths, URLs, ETag
values, or request header values.

Don't merge `Cache-Control` values. Directives can conflict, such as `private`
with `public`, or two different `max-age` values. If a host already set
`Cache-Control`, preserve it and suppress generated `Cache-Control`.
If the selected or existing `Cache-Control` contains `no-store`, suppress the
generated ETag. If a host sets public `Cache-Control` while ImagePipe has no
byte identity, ImagePipe preserves the host policy and doesn't generate an
ETag. That's a host-owned caching decision.

Suppressing generated public cache headers doesn't suppress representation
headers. Automatic output must still emit `Vary: Accept` even when ImagePipe
suppresses generated `Cache-Control` and `ETag`.

Merge `Vary` by parsing it as a comma-separated field-value list. Normalize
field names case-insensitively and remove duplicate tokens. Don't use a raw
string contains check. `Vary: Accept-Encoding` doesn't already contain `Accept`.

## ETag Material

Don't use `ImagePipe.Cache.Key.hash` as the public `ETag`.

The internal key includes storage and origin concerns. Those fields are useful
for safe internal reuse but too coupled for an HTTP validator.

Use separate ETag material:

```elixir
[
  etag_schema: @etag_schema,
  source: source_byte_identity_seed,
  plan: canonical_plan_key_data,
  output: output_selection_material,
  accept: normalized_accept_material,
  representation_version: representation_version
]
```

For explicit output with no `Accept` dependency, use `accept: []`.

Only generate an ETag when:

- the effective `http_cache` mode is `:enabled`;
- `byte_identity` is `{:strong, seed}`;
- ImagePipe can describe output deterministically before source fetch;
- the response doesn't already have an `ETag`;
- the selected cache policy isn't `no-store`.

V1 conditional handling only uses ImagePipe-generated ETags. ImagePipe keeps
existing host ETags but doesn't interpret them for `If-None-Match`.
Don't add a custom ETag override to generated HTTP caching. Routes that need
custom validators should use `http_cache: :disabled` and set their own headers.

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

Build the visible prefix from `@etag_schema`, for example
`"ip#{@etag_schema}-..."`, so the prefix and hashed material can't disagree.

Keep ETag material canonical before encoding. Don't use
`:erlang.term_to_binary/1` over maps unless ImagePipe first turns those maps into
sorted lists. The material should stay as ordered lists with primitive values so
the same logical material encodes the same way across nodes and supported OTP
versions.

Use a strong ETag, not a weak ETag, for generated ETags. A weak ETag would say
the response has the same meaning but not necessarily the same bytes. The
representation version must change whenever an encoder, codec, libvips behavior,
metadata policy, default quality, orientation handling, color-profile behavior,
animation handling, or output timestamp behavior can change bytes.
Changing symbolic output rule behavior is an output policy change, so it uses
`representation_version`. Don't add per-rule version fields to plan material.

It's acceptable for two byte-identical responses to have different ETags when
their deterministic instruction material differs. It isn't acceptable for the
same ETag to survive a change that may change bytes.

Increment `etag_schema` only when the shape or interpretation of ETag material
changes. Increment `representation_version` when the encoded bytes may change
while the material shape stays the same.

Keep `representation_version` as an implementation constant, not a request
option. Any byte-changing field in ETag material must also affect the internal
cache key. `representation_version` is the catch-all for encoder and output
policy behavior, so it must live in both places. Otherwise ImagePipe could serve
an old cached body with a new ETag after a version bump.

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
source fetch whenever these inputs define output representation material:

- parsed plan;
- source cache semantics from `Source.resolve/3`;
- normalized `Accept`;
- runtime output options;
- deterministic policy versions.

This pre-run conditional decision belongs after `Source.resolve/3` and before
`Runner.run/4`. The Plug has the resolved source at that point, but the current
cache-hit delivery shape doesn't. Compute a prepared HTTP cache value there and
pass it into later delivery instead of asking `ImagePipe.Response.Sender` to
recover source semantics from a cache entry.

The output policy must expose whether it can describe the representation before
source fetch. It doesn't need to know the final concrete output format when a
versioned deterministic rule can stand in for the later branch. A function that
returns `{:ok, representation_material}` or `:omit_etag` is enough.
Name the boundary explicitly, for example
`ImagePipe.Plan.canonical_representation_material/1`, and test it outside ETag
hashing so it doesn't drift.

Examples that can qualify:

- explicit formats;
- Accept-based automatic output;
- source-format preservation represented as an instruction such as
  `format: :source`;
- source-compatible fallback represented as a deterministic rule, such as
  `format: {:source_compatible, alpha: :preserve}`.

Stable source bytes imply stable source format and stable decoded-content
properties. Final alpha can affect the eventual branch, but the ETag can include
the branch rule instead of the branch result. If the pre-fetch material can't
describe a byte-changing input, omit the generated ETag.

A matching ETag must skip internal cache lookup and source fetch.

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
caller needs it. If `*` appears anywhere in an `If-None-Match` field value, v1
should treat the field as the wildcard form and ignore it.

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
binary body. The Plug should send the `304` directly before calling
`Runner.run/4`. Don't add a runner delivery shape for this path.

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

Prepare generated HTTP cache headers before calling `ImagePipe.Request.Runner`.
The existing runner receives `Source.Resolved`, but cache-hit delivery currently
drops it and returns only `{:cache_entry, entry, plan.response}`. Passing a
prepared HTTP cache value through delivery keeps cache misses and cache hits on
the same header path without teaching the sender how to rediscover source
semantics.

That keeps old internal entries usable after header-policy changes. It also
avoids replaying stale `ETag` or `Cache-Control` values from metadata written by
an older version.

`ImagePipe.Cache.Entry.cacheable_headers/1` already accepts these stored header
names:

- `vary`
- `cache-control`

These are output-owned or host-owned headers that may already exist before
cache storage. Generated `etag` and generated `cache-control` should come from
`ImagePipe.Request.HTTPCache` at delivery time, not from the cached entry.
V1 doesn't need a cache-entry allowlist change.

On internal cache hit:

1. Check and normalize the cached entry headers.
2. Use the prepared HTTP cache value built before runner execution.
3. Merge cached output headers with current host response headers and generated
   HTTP cache headers. Current host headers win. Generated headers come next.
   Cached entry headers fill gaps and contribute representation headers such as
   `Vary`, but they shouldn't override current host policy or freshly generated
   cache headers.
4. Return `200` with the cached body and merged response headers.

This preserves header behavior between cache misses and cache hits.

`ImagePipe.Cache.Entry` should only check and store cacheable headers. It should
not own conditional request behavior.

V1 has no separate cached-`304` path. A generated ETag match is
deterministic from resolved source semantics, plan, normalized `Accept`, and
options, so the pre-fetch check catches it before runner execution. If the
pre-fetch check can't produce an ETag, a cache hit can't produce one either.

The internal cache key doesn't need to include `etag_schema` just to protect
generated headers, because those headers come from current request inputs on
hit. It must include `representation_version`, because that version represents
byte-changing encoder and output policy behavior.

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
  mode: :disabled
]
```

Keep defaults small and explicit inside `ImagePipe.Request.Options`.
Keep `etag_schema`, `representation_version`, and the generated
`Cache-Control` value as implementation constants, not request options.

Source adapter options:

```elixir
stable: :auto,
internal_cache: :auto,
http_cache: :inherit
```

For S3, if `revision` is present, the source can treat the object as stable even
when `stable` is `:auto`.

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
- Non-pre-fetch generated ETags: v1 doesn't have this path. If pre-fetch
  material can't describe a byte-changing input, v1 omits the generated ETag.
  Needing to resolve a deterministic branch later isn't enough to opt out when
  the ETag material includes the branch rule.
- Automatic quality ETags: deferred until the quality strategy and any model
  artifact versions are explicit ETag material.
- Alpha-specific ETag material: source bytes already cover alpha. If output
  selection depends on final alpha, include the deterministic selection rule in
  ETag material.
- Static final-alpha inference: v1 doesn't need a transform effect system just
  to generate ETags. The runtime final-alpha path can still choose the concrete
  output branch after decode.
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
- `http_cache: :enabled` with `byte_identity: :none` emits telemetry or a
  low-cardinality log event for the safety fallback;
- request `Cookie` doesn't enter generated `Vary`, ETag material, or source
  fetches;
- response with `Set-Cookie` disables generated public cache headers in v1;
- automatic output emits `Vary: Accept`;
- explicit output doesn't emit `Vary: Accept`;
- Client Hints don't enter generated public cache headers, `Vary`, or ETag
  material in v1;
- existing `Plan.expires` doesn't change generated `Cache-Control`;
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
- ImagePipe treats `If-None-Match` containing `*` anywhere as the ignored wildcard
  form in v1;
- `304` responses include only cache metadata and no body;
- `304` responses don't include `Content-Type`, `Content-Length`, or
  `Content-Disposition`;
- internal cache hits preserve cached output headers such as `vary`;
- internal cache-hit delivery uses the prepared HTTP cache value built before
  runner execution;
- internal cache hits return `200` in v1 because matching generated ETags
  already short-circuit before runner execution;
- internal cache-hit responses use the current representation version in the
  generated ETag;
- internal cache hit header merging uses current host headers before generated
  headers, and generated headers before cached entry headers;
- existing host `ETag` suppresses generated ETag;
- ImagePipe preserves existing host `ETag`, but it doesn't trigger generated
  `304` handling in v1;
- existing host `Cache-Control` suppresses generated `Cache-Control`;
- existing host `Cache-Control: no-store` suppresses generated ETags;
- existing `Vary` merges with generated `Accept`;
- existing `Vary: Accept` doesn't produce duplicate `Accept` values when
  ImagePipe adds generated `Vary: Accept`;
- existing `Vary: *` turns off generated public headers in v1;
- transform option order variants produce the same ETag;
- source-compatible output ETag material contains the rule symbolically, not a
  post-decode branch result;
- changing the source-compatible output rule changes ETag material through the
  rule material or representation version;
- different source byte identities with the same source-compatible rule can
  resolve to different concrete output formats while still using pre-fetch ETag
  material based on the symbolic rule;
- changing source revision changes ETag;
- changing the implementation `etag_schema` constant changes ETag;
- changing representation version changes ETag;
- internal cache hit ETags use the current representation version.

Add source adapter tests:

- `ImagePipe.Source.CacheSemantics` requires explicit `byte_identity` and
  `stable?`;
- `Source.Resolved` enforces `cache_semantics`;
- `Source.Resolved.cache: :normal | :skip` callers migrate to
  `internal_cache: :enabled | :disabled`;
- S3 with revision marks the source stable and keeps `versionId` fetch;
- S3 without revision isn't stable and skips internal cache under
  `internal_cache: :auto` unless configured with `stable: :trusted`;
- File source defaults to not stable and host config can mark it with
  `stable: :trusted`;
- HTTP source defaults to not stable and host config can mark it with
  `stable: :trusted`;
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

1. Add source cache semantics struct and source adapter options. Migrate
   `Source.Resolved.cache` to `Source.Resolved.internal_cache`.
2. Expose pre-fetch representation material from the canonical plan layer. This
   step can ship with focused unit tests; integration with HTTP cache preparation
   comes in the next step.
3. Add request-owned HTTP cache header preparation and unit tests. Build the
   prepared value after source resolution and before `Runner.run/4`.
4. Add pre-run conditional handling. The Plug sends matching `304` responses
   before calling `Runner.run/4`.
5. Add generated-header delivery for cache misses and cache hits in one deploy.
   Cache hits should use the prepared value from current request inputs; internal
   cache entries should continue to store only cacheable output headers.
   Splitting this across rolling deploys is a user-facing consistency issue:
   some nodes may emit generated headers while others don't.
6. Document how to enable `http_cache: :enabled`, how to mark sources stable,
   expected CDN cache-key settings, stable-versus-mutable source behavior, and
   the operational effect of bumping the `ip1-`/`@etag_schema` pair.

The first implementation shouldn't add post-transform conditional validation.
If deterministic instruction material can't describe a future output mode, that
mode should opt out of pre-fetch validation until the design makes its inputs
explicit and versioned.
