# Source adapters design

## Status

Approved design direction from brainstorming. This document is for review before
implementation planning.

## Problem

ImagePlug currently treats `Plan.source` as path segments that resolve through a
single configured HTTP root. That is too narrow for source identifiers that name
local files, absolute HTTP URLs, S3-compatible objects, planned object-store
adapters, or catalog-backed asset identifiers.

The existing request order must stay intact:

1. Parse the request into `ImagePlug.Plan`.
2. Validate plan shape and transform safety.
3. Resolve deterministic source identity.
4. Look up the processed-response cache.
5. Fetch and decode only on a cache miss.
6. Run product-neutral transforms over decoded image state.

The source design must not put credentials, clients, endpoints, bucket policy, or
per-bucket secrets into `ImagePlug.Plan`. Transform modules must not know which
source product supplied the bytes.

## Design

Use typed plan source structs plus a runtime resolved-source layer.

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
            {:ok, ImagePlug.Source.Resolved.t()} | {:error, term()}

@callback fetch(ImagePlug.Source.Resolved.t(), adapter_opts :: keyword(), runtime_opts :: keyword()) ::
            {:ok, ImagePlug.Source.Response.t()} | {:error, term()}
```

`resolve/3` runs before cache lookup. It may validate source shape, enforce
source policy, select configured adapter data, normalize identity, and build a
fetch payload. It must not fetch source bytes, decode images, call credential
providers, or perform network-backed storage lookups.

`fetch/3` runs only after a cache miss. It returns a byte stream:

```elixir
%ImagePlug.Source.Response{
  stream: enumerable,
  headers: headers
}
```

Adapters do not return loaded images. `ImagePlug.Request.Processor` keeps decode
ownership so `ImagePlug.Transform.DecodePlanner` can choose sequential or random
access from the transform chain.

The request flow becomes:

```text
parse request
-> validate Plan shape and transform safety
-> resolve Plan.source into Source.Resolved
-> build cache key from Plan and Source.Resolved.identity
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
scheme, host, port, path, and query data that affects the bytes.

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

The plan struct names the adapter key, not the adapter module. Runtime config
binds that key to a module:

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

`ImagePlug.Plan.Source.Reference` is included in the architecture but deferred
from the first implementation slice.

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
uses mutable catalog IDs, it must include a revision in the source or avoid normal
processed-response caching for that adapter.

A reference adapter must not rewrite the plan into another plan source and
restart resolution. It returns `Source.Resolved` directly. The identity can
come from the immutable reference fields; the backing lookup can wait until
`fetch/3`, which only runs on cache miss.

## Runtime source registry

`ImagePlug.Source` becomes the runtime source boundary. Existing
`ImagePlug.Origin` internals can be renamed or replaced because the library is
greenfield.

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
returns `Source.Resolved`. Missing adapters, malformed adapter config, and source
policy failures return before cache lookup.

`Source.Resolved` contains:

- `adapter`: the adapter key or module used for fetch dispatch.
- `identity`: deterministic primitive data used in cache keys.
- `fetch`: adapter-owned non-secret data needed by `fetch/3`.

`identity` must not contain credentials, authorization headers, signed URLs,
client structs, local absolute paths, parser structs, or raw request paths.

Example S3 identity:

```elixir
[
  kind: :object,
  adapter: :s3,
  bucket: "tenant-a",
  key: "images/cat.jpg",
  revision: "abc",
  endpoint: "https://s3.amazonaws.com",
  region: "eu-west-1",
  addressing: :virtual_host
]
```

Resolved identity, not raw source spelling, feeds the cache key. That lets
different parser dialects share cache entries when they resolve to the same
source, and it keeps scheme-specific URI normalization out of `ImagePlug.Cache`.

## S3 adapter

The first S3 adapter uses Req's AWS SigV4 support for signed GET requests. It
supports S3-compatible endpoints by configuration rather than treating each
provider as a product in `Plan`.

Configuration allows default and per-bucket settings:

```elixir
sources: [
  s3:
    {ImagePlug.Source.S3,
     default: [
       region: "us-east-1",
       endpoint: "https://s3.amazonaws.com",
       credentials: {:static, access_key_id: "...", secret_access_key: "..."}
     ],
     buckets: [
       "tenant-a": [
         region: "eu-west-1",
         credentials: {:provider, MyApp.TenantACredentials}
       ],
       "tenant-b": [
         region: "us-west-2",
         endpoint: "https://s3.us-west-2.amazonaws.com",
         credentials: {:provider, MyApp.TenantBCredentials}
       ]
     ],
     bucket_policy: :explicit}
]
```

Bucket-specific config overrides default config. When `buckets:` is configured,
the default policy fails closed for missing buckets. A host can write a custom
adapter for path-prefix, tenant, account, or deployment-specific routing.

Credential providers must not be called during `resolve/3` or cache lookup. The
S3 adapter may include a non-secret credential reference in the fetch payload.
`fetch/3` calls the selected provider only on cache miss, builds a signed request,
and returns a stream.

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

The existing `/plain/...@jpg` source-format behavior remains parser-owned.
Source parsing splits that suffix before translating the source identifier.

Unknown schemes fail unless configured with a scheme translator:

```elixir
imgproxy: [
  source_schemes: [
    "foobar": {MyApp.FoobarSourceParser, []}
  ]
]
```

A scheme translator receives the decoded source string and its configured
options. It returns a `Plan.Source` struct or an error. Translator output still
goes through normal plan and source validation. Runtime fetching requires a
matching source adapter configuration for the returned adapter key.

## Error handling

Pre-cache failures include:

- unsupported source shape
- missing source adapter
- invalid source adapter options
- denied HTTP host
- denied local path
- denied S3 bucket
- malformed S3 bucket, key, or revision
- invalid deterministic source identity
- custom scheme translator errors

These return before cache lookup and before fetch.

Fetch-time failures include:

- HTTP or S3 transport failure
- non-success response status
- local file missing or unreadable
- response body over `:max_body_bytes`
- decode failure
- input pixel limit failure

These happen only after cache miss and are never cached.

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
  source_adapter: :http | :file | :s3 | :catalog,
  result: :ok | :source_error | :processing_error
}
```

Default telemetry must not include full URLs, object keys, bucket names, local
paths, credentials, signatures, signed headers, or parser-specific structs.

For signed S3 fetches, redirects must not leak authorization headers across
hosts. The adapter disables redirects for signed object fetches unless tests
prove the chosen Req configuration preserves that boundary.

## Initial implementation scope

Implement:

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

Do not implement:

- adapters that return loaded images
- recursive source resolution from `Reference` into another plan source
- cloud credential refresh or STS logic inside ImagePlug core
- full compatibility parsers for IIIF, imgix, Cloudinary, or TwicPics

## Testing scope

Plan and source validation:

- `Path`, `URL`, and `Object` validate accepted shapes.
- malformed source structs fail before source registry, cache lookup, and fetch.
- object-source revision participates in source identity.

Imgproxy source parsing:

- current plain paths still parse.
- `local:///`, `http://`, `https://`, and `s3://` parse into the expected source
  structs.
- optional `@format` remains parser-owned output-format handling.
- malformed percent encoding fails before source registry, cache lookup, and
  fetch.
- unknown schemes fail without config.

Custom source schemes:

- configured scheme translators receive decoded source strings and translator
  options.
- translators can return `Path`, `URL`, `Object`, and `Reference` after the
  deferred `Reference` struct ships.
- translator errors return before source registry, cache lookup, and fetch.
- translator output still goes through normal plan and source validation.

Source registry and custom adapters:

- registry dispatches by adapter key to the configured module and options.
- custom adapter `resolve/3` results feed cache identity.
- custom adapter `fetch/3` is called only on cache miss.
- custom adapter `fetch/3` is not called on cache hit.
- malformed custom adapter callback results fail predictably.

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
- regular-file checks.
- missing file behavior.
- stream consumption.

S3 adapter:

- exact bucket config overrides default config.
- missing bucket fails closed when policy requires explicit config.
- credential provider is not called during source resolution or cache lookup.
- credential provider is called only during fetch on cache miss.
- selected provider and options differ by bucket.
- region, endpoint, addressing, bucket, key, and revision affect resolved
  identity.
- Req SigV4 options are passed during fetch.
- signed fetch redirects do not leak authorization headers across hosts.
- stream consumption.

Telemetry and boundaries:

- source spans are emitted for successful and failed source resolution/fetch.
- telemetry metadata excludes URLs, keys, paths, bucket names, credentials, signed
  headers, and parser structs.
- runtime dispatch goes through `ImagePlug.Source`.
- transforms remain source-unaware.
- parser-specific structs do not leak into source, cache, request, output, or
  transform boundaries.
