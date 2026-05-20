# Imgproxy Base64 Source URL Design

## Goal

Add Imgproxy-compatible Base64 source URL parsing to `ImagePlug.Parser.Imgproxy`.

The parser should accept encoded source URLs in Imgproxy processing paths, decode
them inside the Imgproxy compatibility boundary, and pass the decoded source
string through the existing source translator. The decoded source must not change
`ImagePlug.Plan`, cache key material, transform modules, request runtime, or
source adapter contracts.

## Current Behavior

ImagePlug currently supports only the explicit plain source marker:

```text
/<signature>/<options>/plain/<source>[@extension]
```

The parser flow is:

1. `ImagePlug.Parser.Imgproxy.Path.extract/1` removes the mounted script name,
   extracts the signature segment, applies current `fixPath` normalization, and
   returns the signed path plus path segments.
2. `ImagePlug.Parser.Imgproxy.Signature.verify/3` verifies the fixed signed path
   before option parsing or source parsing.
3. `ImagePlug.Parser.Imgproxy.Path.split_source/1` finds the `plain` marker.
4. `ImagePlug.Parser.Imgproxy.Path.parse_plain_source/1` separates the optional
   `@extension` suffix and validates URI escapes.
5. `ImagePlug.Parser.Imgproxy.PlanBuilder.to_plan/2` calls
   `ImagePlug.Parser.Imgproxy.Source.translate/2`, which maps the source string
   into `ImagePlug.Plan.Source.Path`, `URL`, or `Object`.

This ordering is a safety property. Signature, option, policy, and parser
failures return before source identity resolution, cache lookup, or source
fetch.

## Imgproxy Behavior to Match

Imgproxy also accepts a source URL encoded with URL-safe Base64:

```text
/<signature>/<options>/<base64-url>[.<extension>]
/<signature>/<options>/<base64-chunk>/<base64-chunk>[.<extension>]
```

Clients may split the encoded value with `/`. Imgproxy joins those chunks
without a separator, trims trailing `=`, decodes with URL-safe Base64, and
treats a suffix after `.` as an output format.

For example:

```text
/_/rs:fit:300:400/aHR0cDovL2V4YW1w/bGUuY29tL2ltYWdl/cy9jYXQuanBn.webp
```

decodes the source as:

```text
http://example.com/images/cat.jpg
```

and requests explicit WebP output.

## Supported URL Shapes

This change should support two source forms:

```text
/<signature>/<options>/plain/<source>[@extension]
/<signature>/<options>/<encoded-source>[.<extension>]
```

Plain source parsing stays unchanged. Encoded source parsing starts at the first
path segment that's not an option segment. In the existing parser, option
segments contain `:` after preset expansion and option name parsing rules.
Encoded source segments normally don't.

Examples:

```text
/_/plain/images/cat.jpg
/_/plain/http://example.com/images/cat.jpg@png
/_/aW1hZ2VzL2NhdC5qcGc
/_/aHR0cDovL2V4YW1wbGUuY29tL2ltYWdlcy9jYXQuanBn.png
/_/aHR0cDovL2V4YW1wbGUuY29t/L2ltYWdlcy9jYXQuanBn.webp
```

The design excludes:

- encrypted `/enc/<encrypted-source>[.<extension>]`
- SEO filename suffixes controlled by `IMGPROXY_BASE64_URL_INCLUDES_FILENAME`
- source URL prefixing controlled by `IMGPROXY_BASE_URL`
- source URL rewriting controlled by `IMGPROXY_URL_REPLACEMENTS`

Those features change source preprocessing policy. A later change can add them
as explicit Imgproxy parser features if the library needs them.

## Parser Design

Replace the current `Path.split_source/1` and `Path.parse_plain_source/1`
pairing with parser-owned source detection:

```elixir
{:ok, option_segments, source_kind, source_segments}
{:ok, decoded_source, source_format}
```

Use this shape:

```elixir
Path.split_source(path_info)
Path.parse_source(source_kind, source_segments)
```

This keeps option splitting and source decoding in separate test surfaces.

Detection rules:

- If a `plain` segment exists, treat it as the source marker exactly as today.
- If no `plain` segment exists, split at the first segment that doesn't contain
  `:`.
- If no source segment exists, return `{:error, :missing_source_kind}` or the
  closest existing error for the path shape.
- If the encoded source starts with `enc`, return an explicit unsupported
  encrypted-source error before any source side effects.

The parser should keep `source_kind: :plain` in
`%ImagePlug.Parser.Imgproxy.ParsedRequest{}` after decoding. Encoded syntax is a
parser input form, not a plan or runtime source kind.

## Base64 Rules

Encoded source parsing should:

- join encoded path chunks with `""`
- split the joined value on `.`
- reject an empty encoded value
- reject more than one `.`
- treat a non-empty suffix after `.` as output format
- accept a trailing `.` with no extension and no explicit output format
- trim trailing `=` before decoding
- decode with `Base.url_decode64(value, padding: false)`
- reject standard Base64 alphabet characters that `Base.url_decode64/2` rejects
- reject decoded bytes that aren't valid UTF-8

Error examples:

```elixir
{:error, {:missing_source_identifier, "encoded"}}
{:error, {:invalid_encoded_source, :base64}}
{:error, {:invalid_encoded_source, :utf8}}
{:error, {:multiple_output_extension_separators, encoded}}
{:error, {:unsupported_source_kind, "enc"}}
```

Adjust the exact atoms to match local error naming, but errors shouldn't include
decoded source URLs. The raw encoded value is acceptable when it's already
present in the request path.

## Source Translation

After decoding, pass the decoded source string to
`ImagePlug.Parser.Imgproxy.Source.translate/2` unchanged.

That reuses existing behavior:

| Decoded source | Existing result |
| --- | --- |
| `images/cat.jpg` | `ImagePlug.Plan.Source.Path` |
| `local:///images/cat.jpg` | `ImagePlug.Plan.Source.Path` |
| `http://example.com/cat.jpg?x=1` | `ImagePlug.Plan.Source.URL` |
| `https://example.com/cat.jpg` | `ImagePlug.Plan.Source.URL` |
| `s3://bucket/images/cat.jpg?rev1` | `ImagePlug.Plan.Source.Object` |
| configured custom scheme | configured `SourceScheme` translator |

No transform, cache, request, response, or source adapter code should know that
the original request used encoded source syntax.

## Signing

Signature verification must continue to run before Base64 decoding.

The signed path is the fixed path produced by `Path.extract/1`, including the
encoded chunks and optional `.extension` suffix exactly as received after
current `fixPath` behavior. Decoding the source must not change the bytes used
for signature verification.

The existing public docs vector in `test/parser/imgproxy/signature_test.exs`
already proves that the signature primitive accepts an encoded-source signed
path. Add one full parser test that uses that vector through
`ImagePlug.Parser.Imgproxy.parse/2` after encoded source parsing is available.

## Request Safety

Malformed encoded source values are parser failures. They should return before:

- source identity resolution
- cache lookup
- source fetch
- transform decode
- output negotiation that depends on fetched source data

This follows the current parser safety boundary for invalid signatures, missing
source markers, invalid options, expired requests, and malformed plain source
URI escapes.

Wire-level tests should use the existing `CacheProbe` and
`OriginShouldNotFetch` helpers to prove this boundary.

## Documentation Updates

Update `docs/imgproxy_path_api.md`:

- add encoded source URL shape to the path shape section
- document `@extension` for plain sources and `.extension` for encoded sources
- state that the Imgproxy parser decodes encoded source URLs
- state that signing uses the received fixed path before decoding
- state that this feature doesn't include `/enc/`, SEO filename suffixes, base
  URL prefixing, or URL replacements

Update `docs/imgproxy_support_matrix.md`:

- mark Base64 encoded source URL as supported
- keep encrypted `/enc/` source URL missing
- keep `IMGPROXY_BASE64_URL_INCLUDES_FILENAME`,
  `IMGPROXY_BASE_URL`, and `IMGPROXY_URL_REPLACEMENTS` missing
- update extension suffix notes to include encoded `.extension`

## Test Coverage

Parser path tests in `test/parser/imgproxy/path_test.exs`:

- splits option segments from encoded source segments
- joins encoded chunks without `/`
- parses `.webp`, `.avif`, `.jpg`, `.jpeg`, `.png`, and `.best`
- accepts Base64URL without padding
- accepts padded Base64URL by trimming trailing `=`
- rejects empty encoded source
- rejects invalid Base64URL input
- rejects decoded non-UTF-8 bytes
- rejects repeated `.` extension separators
- rejects unknown encoded-source output formats
- rejects `/enc/` as unsupported

Full parser tests in `test/parser/imgproxy_test.exs`:

- decoded path source becomes `ImagePlug.Plan.Source.Path`
- decoded HTTP URL with query becomes `ImagePlug.Plan.Source.URL`
- decoded S3 URL with query revision becomes `ImagePlug.Plan.Source.Object`
- decoded custom scheme reaches the configured source scheme translator
- signed encoded-source request verifies before decoding and parses correctly

Wire tests in `test/image_plug/imgproxy_wire_conformance_test.exs`:

- encoded path source succeeds through a real `ImagePlug.call/2` request
- malformed encoded source returns `400`
- malformed encoded source emits no cache lookup
- malformed encoded source emits no origin fetch

## Rejected Alternatives

### Add a new plan source kind

Don't add `ImagePlug.Plan.Source.Encoded` or a similar type. Base64 source
syntax is an Imgproxy URL representation detail. The plan should describe the
resolved source identity, not how one parser received it.

### Decode inside source adapters

Don't pass encoded values to source adapters. That would make every source
adapter account for Imgproxy syntax and would weaken parser-owned validation.

### Add base URL and replacements now

Don't add `IMGPROXY_BASE_URL` or `IMGPROXY_URL_REPLACEMENTS` in this change.
They alter source preprocessing policy for both plain and encoded sources. This
feature should only add the missing encoded source syntax.

### Add SEO filename passthrough now

Don't add `IMGPROXY_BASE64_URL_INCLUDES_FILENAME` in this change. It adds a mode
where the parser ignores the last path segment. That's compatible behavior, but
it's separate from decoding the source URL.

## Review Checklist

- Encoded syntax stays under `ImagePlug.Parser.Imgproxy`.
- `%ImagePlug.Plan{}` contains the same source structs used by plain sources.
- Cache key material depends on resolved source identity and canonical plan
  fields, not the original encoded request spelling.
- Signature verification happens before Base64 decoding.
- Parser failures stop before source identity resolution, cache lookup, and
  source fetch.
- Docs describe only behavior present in this design.
