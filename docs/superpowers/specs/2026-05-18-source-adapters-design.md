# Source adapters design

## Status

Approved design direction from brainstorming. This document is for review before
implementation planning.

## Problem

ImagePlug currently treats `Plan.source` as path segments that resolve through a
single configured HTTP root. That's too narrow for source identifiers that name
local files, absolute HTTP URLs, S3-compatible objects, planned object-store
adapters, or catalog-backed asset identifiers.

The existing request order must stay intact:

1. Parse the request into `ImagePlug.Plan`.
2. Check plan shape and transform safety.
3. Resolve deterministic source identity.
4. Look up the processed-response cache.
5. Fetch and decode only on a cache miss.
6. Run product-neutral transforms over decoded image state.

The source design must not put credentials, clients, endpoints, bucket policy, or
per-bucket secrets into `ImagePlug.Plan`. Transform modules must not know which
source product supplied the bytes.

## Design

Use typed plan source structs plus a runtime resolved-source layer. The new
source boundary replaces the current `ImagePlug.Origin` internals. It doesn't
revive the abandoned `ImagePlug.Runtime` module tree.

Parsers emit product-neutral source data:

```elixir
%ImagePlug.Plan.Source.Path{}
%ImagePlug.Plan.Source.URL{}
%ImagePlug.Plan.Source.Object{}
%ImagePlug.Plan.Source.Reference{}
```

Runtime source adapters resolve those plan sources into a deterministic identity
and an adapter-owned fetch payload:

```elixir
@callback validate_options(keyword()) :: {:ok, keyword()} | {:error, term()}

@callback resolve(ImagePlug.Plan.Source.t(), adapter_opts :: keyword(), runtime_opts :: keyword()) ::
            {:ok, ImagePlug.Source.Resolved.t()} | {:error, ImagePlug.Source.error()}

@callback fetch(ImagePlug.Source.Resolved.t(), adapter_opts :: keyword(), runtime_opts :: keyword()) ::
            {:ok, ImagePlug.Source.Response.t()} | {:error, ImagePlug.Source.error()}
```

`resolve/3` runs before cache lookup. It may check source shape, enforce
source policy, select configured adapter data, normalize identity, and build a
fetch payload. It must not fetch source bytes, decode images, call credential
providers, or perform network-backed storage resolution.

`fetch/3` runs only after a cache miss. It returns a byte stream:

```elixir
%ImagePlug.Source.Response{
  stream: enumerable
}
```

`stream` is an enumerable of binaries. The first slice doesn't expose source
response headers through `Source.Response`, because HTTP and S3 headers aren't
available until the lazy stream opens the upstream response. Source headers
aren't cache key material and aren't emitted in telemetry by default.

The source boundary wraps adapter streams before the decoder consumes them. That
wrapper accepts binary chunks only, enforces `:max_body_bytes`, converts deferred
stream errors into safe source errors, and wraps stream exceptions. Request
option normalization passes `:max_body_bytes` into source runtime options. Source
code must not read request or cache config directly. Resource-owning adapters put
cleanup or cancellation in the enumerable termination path, so a decode error or
abandoned response closes the source request without a separate cleanup callback.

Adapter errors use a small tagged shape:

```elixir
{:source, reason}
```

Built-in adapter reasons must be safe to include in internal control flow and
default error responses. They must not contain source URLs, paths, object keys,
signed request data, credentials, client structs, raw response bodies, or
arbitrary exceptions. Custom adapters own the safety of returned reasons. The
source registry still treats malformed callback returns as adapter errors rather
than letting them reach cache, decode, or response code.

Adapters don't return loaded images. The request processor keeps decode
ownership so `ImagePlug.Transform.DecodePlanner` can choose sequential or random
access from the transform chain. The existing `ImagePlug.Origin.Decoded` concept
should move to the request or transform side of the boundary rather than into the
source adapter boundary.

The request flow becomes:

```text
parse request
-> validate Plan shape and transform safety
-> resolve Plan.source into Source.Resolved
-> if Source.Resolved.cache == :normal, build cache key and look up cache
-> if cache misses or Source.Resolved.cache == :skip, fetch Source.Resolved
-> decode, validate input limits, transform, encode
-> cache successful encoded responses only when Source.Resolved.cache == :normal
```

## Source variants

### Path

`ImagePlug.Plan.Source.Path` represents root-relative path segments:

```elixir
%ImagePlug.Plan.Source.Path{segments: ["images", "cat.jpg"]}
```

This is the local-file source shape for the new adapter model. Validation rejects
segments that can escape the configured root, including `.`, `..`, backslash
traversal, and absolute paths after parser normalization.

The file adapter identity must include a configured non-secret root identifier,
not the absolute root path. Two roots that both contain `images/cat.jpg` must not
share cache entries unless the host gives them the same root identifier.

### URL

`ImagePlug.Plan.Source.URL` represents absolute `http` or `https` sources:

```elixir
%ImagePlug.Plan.Source.URL{
  scheme: :https,
  host: "assets.example.com",
  path: ["images", "cat.jpg"],
  query: "v=1"
}
```

The HTTP adapter owns host policy, redirect limits, request timeouts, body-size
limits, and streaming through Req. URL source identity must include normalized
scheme, host, port, path, and query data. The default policy preserves the full
normalized query string because query parameters often affect the bytes. An
adapter can ignore or filter query fields only through explicit host
configuration.

### Object

`ImagePlug.Plan.Source.Object` represents bucket/container object storage:

```elixir
%ImagePlug.Plan.Source.Object{
  adapter: :s3,
  scope: "assets-bucket",
  key: "images/cat.jpg",
  revision: "abc"
}
```

`scope` is the product-neutral bucket or container name. `key` is the object key.
`revision` is an optional immutable object selector. The S3 adapter maps it to an
S3 object version ID. A GCS adapter can map the same field to a generation.

The plan struct names an opaque adapter, not the adapter module. Plan
validation must not special-case `:s3`. S3-specific behavior belongs in the
imgproxy source translator and the configured source adapter. Runtime config
binds the adapter to a module:

```elixir
sources: [
  s3: {ImagePlug.Source.S3, opts}
]
```

Hosts can replace the default S3 adapter:

```elixir
sources: [
  s3: {MyApp.AssumeRoleS3Source, opts}
]
```

The replacement adapter can use STS, AssumeRole, instance metadata, a private
credential service, a cached client, or a different HTTP client while preserving
the same parser and plan model.

### Reference

The architecture includes `ImagePlug.Plan.Source.Reference`, but the first
implementation slice defers it.

It represents an immutable external identifier:

```elixir
%ImagePlug.Plan.Source.Reference{
  adapter: :catalog,
  id: "asset_123",
  revision: "sha256-or-revision",
  metadata: [variant: "original"]
}
```

Reference identifiers are cacheable only if they name immutable bytes. If a host
uses mutable catalog IDs, it must include a revision in the source or return a
resolved cache policy that skips processed-response caching for that adapter.

A reference adapter must not rewrite the plan into another plan source and
restart resolution. It returns `Source.Resolved` directly. The identity can come
from the immutable reference fields. The backing lookup can wait until `fetch/3`,
which only runs on cache miss.

## Runtime source registry

`ImagePlug.Source` becomes the runtime source boundary. Because the library is
greenfield, existing `ImagePlug.Origin` internals can move into the new boundary.
Architecture tests should assert the new source boundary directly instead of
preserving the old origin boundary by inertia.

Runtime config maps source adapters to modules and options:

```elixir
sources: [
  path: {ImagePlug.Source.File, root: "/srv/images"},
  http: {ImagePlug.Source.HTTP, allowed_hosts: ["assets.example.com"]},
  https: {ImagePlug.Source.HTTP, allowed_hosts: ["assets.example.com"]},
  s3: {ImagePlug.Source.S3, s3_opts}
]
```

The source registry picks the adapter for `Plan.source`, calls `resolve/3`, and
returns `Source.Resolved`. Adapter option validation happens during
`ImagePlug.init/1`, before requests enter the pipeline. The registry calls
`validate_options/1` and stores the validated options for later `resolve/3` and
`fetch/3` calls. Missing adapters and source policy failures return before cache
lookup.

`Source.Resolved` contains:

- `adapter`: the configured adapter used for fetch dispatch. This is the config
  key, not the module.
- `source_kind`: `:path`, `:url`, `:object`, or `:reference`.
- `identity`: deterministic primitive data used in cache keys.
- `cache`: `:normal` or `:skip`.
- `fetch`: adapter-owned data needed by `fetch/3`.

`identity` must not contain credentials, authorization headers, signed URLs,
client structs, local absolute paths, parser structs, raw request paths, or the
`Source.Resolved` struct itself. Cache code receives only primitive identity
data, never adapter modules or fetch payloads.

The identity must include every non-secret value that can change the source
bytes. That includes the configured adapter, configured root identity, effective
endpoint, hidden object prefixes, tenant routing rules, catalog revision data,
and custom adapter identity fingerprints. The identity excludes credential
values.

When `cache` is `:skip`, request processing bypasses cache key construction,
cache adapter `get`, and cache adapter `put`. The decision still comes from
`resolve/3`, before source fetch. Mutable references can use this when they can't
supply an immutable revision without doing a backing lookup.

Example S3 identity:

```elixir
[
  kind: :object,
  adapter: :s3,
  bucket: "tenant-a",
  key: "images/cat.jpg",
  revision: "abc",
  endpoint: "https://s3.amazonaws.com"
]
```

Resolved identity, not raw source spelling, feeds the cache key. The cache key
keeps canonical plan data for transforms, output, configured vary inputs, and
cachebuster values, but source material comes from `Source.Resolved.identity`.
That lets different parser dialects share cache entries when they resolve to the
same source, and it keeps scheme-specific URI normalization out of
`ImagePlug.Cache`.

## S3 adapter

The first S3 adapter uses the AWS SigV4 support in Req for signed GET requests. It
supports S3-compatible endpoints by configuration rather than treating each
provider as a product in `Plan`.

Configuration supports default and per-bucket settings:

```elixir
sources: [
  s3:
    {ImagePlug.Source.S3,
     default: [
       region: "us-east-1",
       endpoint: "https://s3.amazonaws.com",
       credentials: {:static, access_key_id: "...", secret_access_key: "..."}
     ],
     buckets: %{
       "tenant-a" => [
         region: "eu-west-1",
         credentials: {:provider, MyApp.TenantACredentials, []}
       ],
       "tenant-b" => [
         region: "us-west-2",
         endpoint: "https://s3.us-west-2.amazonaws.com",
         credentials: {:provider, MyApp.TenantBCredentials, []}
       ]
     }}
]
```

Bucket-specific config overrides default config. When config includes a `buckets`
map, the adapter only accepts buckets listed in that map. `default` supplies
shared defaults for listed buckets. That default doesn't catch unlisted buckets in
that mode. Without a `buckets` map, `default` applies to every bucket. A host can
write a custom adapter for path-prefix, tenant, account, or deployment-specific
routing.

This built-in routing is exact-bucket routing. S3 bucket names identify the
object space for native S3. S3-compatible stores with independent bucket spaces
use different endpoints, and endpoint participates in identity. If a
custom adapter adds tenant, account, profile, or hidden-prefix routing, its
resolved identity must include that non-secret routing choice.

The built-in adapter signs every request with Req SigV4 `service: :s3`. That
keeps S3-compatible endpoints working even when Req can't infer the AWS service
from the host.

The S3 adapter must not call credential providers during `resolve/3` or cache
lookup. The adapter may include a non-secret credential reference in the fetch
payload. `fetch/3` calls the selected provider only on cache miss, builds a
signed request, and returns a stream.

Credential providers are runtime callbacks, not plan data. The S3 adapter calls:

```elixir
provider.fetch_credentials(scope, provider_opts, runtime_opts)
```

The callback returns:

```elixir
{:ok,
 [
   access_key_id: "AKIA...",
   secret_access_key: "..."
 ]}
```

For temporary credentials:

```elixir
{:ok,
 [
   access_key_id: "ASIA...",
   secret_access_key: "...",
   token: "temporary-session-token"
 ]}
```

Credential failures use the source error shape:

```elixir
{:error, {:source, :credentials_unavailable}}
```

`token` maps directly to Req SigV4's `:token` option for STS or other temporary
credentials.

Providers can cache, refresh, assume roles, call instance metadata, or talk to a
private credential service. Those side effects happen only inside `fetch/3`,
after a cache miss.

Secret fields, access keys, tokens, signed URLs, authorization headers,
and client structs must not enter plan data, cache key data, telemetry, or default
error messages.

## Imgproxy source parsing

The imgproxy parser keeps owning imgproxy URL syntax. Source parsing becomes
parser-owned translation from decoded source identifiers into `Plan.Source`
structs.

Built-in translations for the first slice:

```text
/_/plain/images/cat.jpg
/_/plain/local:///images/cat.jpg
  -> Plan.Source.Path{segments: ["images", "cat.jpg"]}

/_/plain/http://assets.example.com/images/cat.jpg
/_/plain/https://assets.example.com/images/cat.jpg
  -> Plan.Source.URL{scheme: :http | :https, ...}

/_/plain/s3://bucket/images/cat.jpg%3Fabc
  -> Plan.Source.Object{
       adapter: :s3,
       scope: "bucket",
       key: "images/cat.jpg",
       revision: "abc"
     }
```

For S3, the URI host maps to `scope`, the path maps to `key`, and the entire
query maps to `revision`. For example, `?abc` becomes `revision: "abc"`. A query
such as `?version=abc` becomes `revision: "version=abc"` unless a custom scheme
translator chooses different semantics.

In the actual Plug request path, callers must escape the embedded source query
delimiter because `Plug.Conn.request_path` excludes the request query string:

```text
/_/plain/s3://bucket/images/cat.jpg%3Fabc
```

The imgproxy parser removes the signature segment, then keeps the raw embedded
source string for built-in translation. That lets built-ins distinguish escaped
source delimiters such as `%3F`, `%23`, and `%25` before URI parsing. Built-in
translators produce decoded `Plan.Source` fields. Custom scheme translators
receive the decoded source string.

The existing `/plain/...@jpg` source-format behavior remains parser-owned.
Source parsing splits that suffix before translating the source identifier.

Unknown schemes fail unless configured with a scheme translator:

```elixir
imgproxy: [
  source_schemes: %{
    "foobar" => {MyApp.FoobarSourceParser, []}
  }
]
```

A scheme translator receives the decoded source string and its configured
options. It returns a `Plan.Source` struct or an error. Translator output still
goes through normal plan and source validation. Runtime fetching requires a
matching source adapter configuration for the returned adapter.

Scheme translators expose:

```elixir
@callback translate(source :: String.t(), opts :: keyword()) ::
            {:ok, ImagePlug.Plan.Source.t()} | {:error, term()}
```

The imgproxy parser calls `translate/2` during parsing, before plan validation,
source resolution, cache lookup, or fetch.

Scheme translators are parser extensions. They must be pure and deterministic:
no network calls, file reads, credential access, catalog lookup operations,
storage client calls, or process-local mutable state. Any source-specific side
effects belong in the runtime source adapter and happen after source resolution
and cache lookup.

## Error handling

Pre-cache failures include:

- unsupported source shape
- missing source adapter
- denied HTTP host
- denied local path
- denied S3 bucket
- malformed S3 bucket, key, or revision
- invalid deterministic source identity
- custom scheme translator errors

These return before cache lookup and before fetch.

Invalid source adapter options are initialization failures. `ImagePlug.init/1`
validates adapter modules and their options before requests can use them.

Source fetch and stream failures include:

- HTTP or S3 transport failure
- non-success response status
- local file missing or unreadable
- response body over `:max_body_bytes`

With lazy HTTP and S3 streams, status, transport, timeout, and body-limit
failures may surface during stream enumeration after `fetch/3` returns a
`Source.Response`. The source stream wrapper normalizes those deferred failures
into safe source errors before they cross into decode or request telemetry.

Post-fetch processing failures include:

- decode failure
- input pixel limit failure

These happen only after cache miss or cache skip and are never cached. They're
not source adapter failures.

Expected adapter failures return tagged `ImagePlug.Source.error()` values.
Adapters shouldn't raise for denied sources, missing objects, transport errors,
credential failures, non-success statuses, malformed callback results, or body
limit failures. The source boundary wraps unexpected exceptions before telemetry
or error responses see them, so raw exception terms can't leak secrets by
default. Source spans catch adapter exceptions inside the span body and convert
them to sanitized returned errors instead of letting `:telemetry.span/3` emit
exception metadata for adapter code. The `[:source, :fetch]` span means "stream
created": it covers `fetch/3` and stream wrapper construction, not later image
decode. Deferred stream errors still pass through the source stream wrapper and
become returned source errors before decode or request spans observe them.

## Telemetry

Source-oriented spans replace origin-oriented names:

```text
[:source, :resolve]
[:source, :fetch]
```

Metadata remains low-cardinality and safe:

```elixir
%{
  source_kind: :object,
  source_adapter_kind: :s3,
  result: :ok
}
```

Default telemetry must not include full URLs, object keys, bucket names, local
paths, dispatch adapter keys, credentials, signatures, signed headers, raw error
reasons, stack traces, or parser-specific structs. Host applications can attach
their own handlers or opt-in metadata once they have decided which values are
safe for their environment.

`source_adapter_kind` is a low-cardinality adapter family for telemetry, not the
configured `Source.Resolved.adapter` dispatch key. Built-in adapters emit
families such as `:http`, `:file`, and `:s3`. Custom adapters default to
`:custom` unless they define a safe family value during option validation.

For signed S3 fetches, redirects must not leak authorization headers across
hosts. The adapter disables redirects for signed object fetches unless tests
prove the chosen Req configuration preserves that boundary.

## Initial implementation scope

Build:

- `Plan.Source.Path`
- `Plan.Source.URL`
- `Plan.Source.Object`
- `ImagePlug.Source` behaviour and registry
- `ImagePlug.Source.Resolved`
- `ImagePlug.Source.Response`
- `ImagePlug.Source.HTTP`
- `ImagePlug.Source.File`
- `ImagePlug.Source.S3`
- imgproxy source translations for plain path, `local:///`, `http(s)://`, and
  `s3://`
- imgproxy custom source scheme translators
- cache key support for resolved source identity
- source-oriented telemetry spans

Document but defer:

- `Plan.Source.Reference`
- built-in GCS, Azure Blob Storage, and Swift adapters
- configurable object-source query separators for object keys that contain `?`

Out of scope:

- adapters that return loaded images
- recursive source resolution from `Reference` into another plan source
- cloud credential refresh or STS logic inside ImagePlug core
- full compatibility parsers for other image URL dialects

## Testing scope

Plan and source validation:

- `Path`, `URL`, and `Object` accept valid shapes.
- malformed source structs fail before source registry, cache lookup, and fetch.
- object-source revision participates in source identity.

Imgproxy source parsing:

- current plain paths still parse.
- `local:///`, `http://`, `https://`, and `s3://` parse into the expected source
  structs.
- optional `@format` remains parser-owned output-format handling.
- malformed URL encoding fails before source registry, cache lookup, and fetch.
- unknown schemes fail without config.

Custom source schemes:

- configured scheme translators receive decoded source strings and translator
  options.
- scheme translator configuration uses binary scheme keys.
- translators are deterministic and perform no side effects.
- translators can return `Path`, `URL`, `Object`, and `Reference` after the
  deferred `Reference` struct ships.
- translator errors return before source registry, cache lookup, and fetch.
- translator output still goes through normal plan and source validation.

Source registry and custom adapters:

- registry dispatches by adapter to the configured module and options.
- registry calls adapter `validate_options/1` during `ImagePlug.init/1`.
- `resolve/3` returns `adapter`, `source_kind`, primitive identity, cache
  policy, and fetch payload.
- custom adapter `resolve/3` identity data feeds cache identity.
- cache misses call the custom adapter `fetch/3`.
- cache hits don't call the custom adapter `fetch/3`.
- malformed custom adapter callback results fail predictably.
- init rejects malformed adapter options before request handling.
- stream wrappers reject non-binary chunks, enforce body-size limits, sanitize
  deferred stream errors, and run cleanup.

Request safety:

- parser, plan, and source-resolution failures return before cache lookup and
  fetch.
- cache lookup happens before any adapter `fetch/3` call.
- fetch and decode happen only after cache miss or when source resolution skips
  cache. When automatic output negotiation needs source format, it reads that
  format only after the cache decision.

Cache keys:

- keys use resolved source identity, not raw request path or raw source spelling.
- different raw spellings with the same resolved identity can share cache.
- same bucket and key with different endpoint or revision don't share cache.
- credentials, tokens, authorization headers, signed URLs, local absolute paths,
  and parser structs are absent from key data.
- `cache: :skip` bypasses cache key construction, cache lookup, and cache write
  without fetching before the skip decision.

HTTP adapter:

- allowed and denied hosts.
- redirect behavior.
- timeout behavior.
- body-size limit.
- non-success status handling.
- stream consumption.

File adapter:

- root config validation.
- traversal and dot-segment rejection.
- symlink escape rejection if the adapter follows symlinks.
- root identity participates in resolved source identity.
- regular-file checks.
- missing file behavior.
- stream consumption.

S3 adapter:

- exact bucket config overrides default config.
- missing bucket fails closed when config includes a `buckets` map.
- source resolution and cache lookup don't call the credential provider.
- fetch calls the credential provider only on cache miss.
- selected provider and options differ by bucket.
- endpoint, bucket, key, and revision affect resolved identity.
- same bucket and key at different endpoints don't share cache.
- the adapter passes Req SigV4 options with `service: :s3` during fetch.
- signed fetch redirects don't leak authorization headers across hosts.
- stream consumption.
- credential provider success, failure, and refresh paths return safe tagged
  errors.

Telemetry and boundaries:

- ImagePlug emits source spans for successful and failed source resolution/fetch.
- telemetry metadata excludes URLs, keys, paths, bucket names, dispatch adapter
  keys, credentials, signed headers, raw reasons, stack traces, and parser structs.
- source code converts adapter exceptions to sanitized source errors before
  telemetry sees them.
- request dispatch goes through `ImagePlug.Source`.
- the top-level `ImagePlug` entry point uses `ImagePlug.Source` and doesn't
  depend on `ImagePlug.Origin` or bypass the source registry.
- architecture tests cover the deliberate replacement of `ImagePlug.Origin`
  internals with `ImagePlug.Source`: request depends on source, source may depend
  on plan and telemetry, source avoids request/cache/output/transform/response
  and parser dependencies, and plan, parser, cache, output, transform, and
  response don't depend on source.
- architecture tests keep the old `ImagePlug.Runtime` module-tree absence
  assertion.
- transforms remain source-unaware.
- parser-specific structs don't leak into source, cache, request, output,
  transform, or response boundaries.
