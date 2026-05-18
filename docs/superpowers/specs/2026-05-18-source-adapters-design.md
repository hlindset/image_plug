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
  stream: enumerable,
  headers: [{"content-type", "image/jpeg"}]
}
```

`stream` is an enumerable of binaries. `headers` is a list of lowercase binary
name/value pairs observed from the source response. Headers aren't cache key
material and aren't emitted in telemetry by default.

Adapter errors use a small tagged shape:

```elixir
{:source, reason}
```

`reason` must be safe to include in internal control flow and default error
responses. It must not contain source URLs, paths, object keys, signed request
data, credentials, client structs, raw response bodies, or arbitrary exceptions.
The source registry treats malformed callback returns as adapter errors rather
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
-> build cache key from canonical Plan fields and Source.Resolved.identity
-> cache lookup
-> fetch Source.Resolved on miss
-> decode, validate input limits, transform, encode
-> cache successful encoded responses
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
  scope: "tenant-a",
  key: "images/cat.jpg",
  revision: "abc"
}
```

`scope` is the product-neutral bucket or container name. `key` is the object key.
`revision` is an optional immutable object selector. The S3 adapter maps it to an
S3 object version ID. A GCS adapter can map the same field to a generation.

The plan struct names an opaque adapter key, not the adapter module. Plan
validation must not special-case `:s3`. S3-specific behavior belongs in the
imgproxy source translator and the configured source adapter. Runtime config
binds the adapter key to a module:

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

Runtime config maps source adapter keys to modules and options:

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
`ImagePlug.init/1`, before requests enter the pipeline. Missing adapters and
source policy failures return before cache lookup.

`Source.Resolved` contains:

- `adapter_key`: the configured adapter key used for fetch dispatch.
- `source_kind`: `:path`, `:url`, `:object`, or `:reference`.
- `identity`: deterministic primitive data used in cache keys.
- `cache`: `:normal` or `:skip`.
- `fetch`: adapter-owned data needed by `fetch/3`.

`identity` must not contain credentials, authorization headers, signed URLs,
client structs, local absolute paths, parser structs, raw request paths, or the
`Source.Resolved` struct itself. Cache code receives only primitive identity
data, never adapter modules or fetch payloads.

The identity must include every non-secret value that can change the source
bytes. That includes adapter scope, configured root identity, endpoint, region,
addressing mode, hidden object prefixes, tenant routing rules, catalog revision
data, and custom adapter identity fingerprints. The identity excludes credential
values. It can include the selected non-secret credential profile when that
profile changes which object storage space ImagePlug reads.

Example S3 identity:

```elixir
[
  kind: :object,
  adapter_key: :s3,
  adapter_scope: {:s3, :default},
  bucket: "tenant-a",
  key: "images/cat.jpg",
  revision: "abc",
  endpoint: "https://s3.amazonaws.com",
  region: "eu-west-1",
  addressing: :virtual_host
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

This built-in routing is exact-bucket routing. If the same bucket name can exist
behind different accounts, endpoints, tenants, or deployment profiles, the host
should use separate adapter keys or a custom adapter. That adapter's resolved
identity must include the non-secret profile that selects the backing storage
space.

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
   access_key_id: binary(),
   secret_access_key: binary(),
   session_token: binary() | nil
 ]}
| {:error, ImagePlug.Source.error()}
```

Providers can cache, refresh, assume roles, call instance metadata, or talk to a
private credential service. Those side effects happen only inside `fetch/3`,
after a cache miss.

Secret fields, access keys, session tokens, signed URLs, authorization headers,
and client structs must not enter plan data, cache key data, telemetry, or default
error messages.

## Imgproxy source parsing

The imgproxy parser keeps owning imgproxy URL syntax. Source parsing becomes
parser-owned translation from decoded source identifiers into `Plan.Source`
structs.

Built-in translations for the first slice:

```text
/plain/images/cat.jpg
plain/local:///images/cat.jpg
  -> Plan.Source.Path{segments: ["images", "cat.jpg"]}

plain/http://assets.example.com/images/cat.jpg
plain/https://assets.example.com/images/cat.jpg
  -> Plan.Source.URL{scheme: :http | :https, ...}

plain/s3://bucket/images/cat.jpg?abc
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
/plain/s3://bucket/images/cat.jpg%3Fabc
```

The imgproxy parser decodes that source segment before URI translation, so the
source translator sees `s3://bucket/images/cat.jpg?abc`.

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
matching source adapter configuration for the returned adapter key.

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

Fetch-time failures include:

- HTTP or S3 transport failure
- non-success response status
- local file missing or unreadable
- response body over `:max_body_bytes`
- decode failure
- input pixel limit failure

These happen only after cache miss and are never cached.

Expected adapter failures return tagged `ImagePlug.Source.error()` values.
Adapters shouldn't raise for denied sources, missing objects, transport errors,
credential failures, non-success statuses, malformed callback results, or body
limit failures. The source boundary wraps unexpected exceptions before telemetry
or error responses see them, so raw exception terms can't leak secrets by
default.

## Telemetry

Source-oriented spans replace origin-oriented names:

```text
[:source, :resolve]
[:source, :fetch_decode]
```

Metadata remains low-cardinality and safe:

```elixir
%{
  source_kind: :url | :path | :object | :reference,
  source_adapter_kind: :http | :file | :s3 | :catalog | :custom,
  result: :ok | :source_error | :processing_error
}
```

Default telemetry must not include full URLs, object keys, bucket names, local
paths, dispatch adapter keys, credentials, signatures, signed headers, raw error
reasons, stack traces, or parser-specific structs. Host applications can attach
their own handlers or opt-in metadata once they have decided which values are
safe for their environment.

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

- registry dispatches by adapter key to the configured module and options.
- `resolve/3` returns `adapter_key`, `source_kind`, primitive identity, cache
  policy, and fetch payload.
- custom adapter `resolve/3` identity data feeds cache identity.
- cache misses call the custom adapter `fetch/3`.
- cache hits don't call the custom adapter `fetch/3`.
- malformed custom adapter callback results fail predictably.
- init rejects malformed adapter options before request handling.

Request safety:

- parser, plan, and source-resolution failures return before cache lookup and
  fetch.
- cache lookup happens before any adapter `fetch/3` call.
- fetch and decode happen only on cache miss or when automatic output negotiation
  needs source format.

Cache keys:

- keys use resolved source identity, not raw request path or raw source spelling.
- different raw spellings with the same resolved identity can share cache.
- same bucket and key with different endpoint, region, addressing, or revision do
  not share cache.
- credentials, tokens, authorization headers, signed URLs, local absolute paths,
  and parser structs are absent from key data.
- `cache: :skip` bypasses processed-response cache without fetching before the
  cache decision.

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
- region, endpoint, addressing, bucket, key, and revision affect resolved
  identity.
- same bucket names behind different configured storage scopes don't share cache.
- the adapter passes Req SigV4 options during fetch.
- signed fetch redirects don't leak authorization headers across hosts.
- stream consumption.
- credential provider success, failure, and refresh paths return safe tagged
  errors.

Telemetry and boundaries:

- ImagePlug emits source spans for successful and failed source resolution/fetch.
- telemetry metadata excludes URLs, keys, paths, bucket names, dispatch adapter
  keys, credentials, signed headers, raw reasons, stack traces, and parser structs.
- request dispatch goes through `ImagePlug.Source`.
- architecture tests cover the deliberate replacement of `ImagePlug.Origin`
  internals with `ImagePlug.Source`.
- transforms remain source-unaware.
- parser-specific structs don't leak into source, cache, request, output, or
  transform boundaries.
