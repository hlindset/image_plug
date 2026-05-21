# Imgproxy encrypted source URL design

## Goal

ImagePlug should accept imgproxy-compatible `/enc/<source>[.<format>]` source URLs
when callers configure the imgproxy parser with a source URL encryption key.
The first slice should match imgproxy's wire format and keep the decrypted
source inside the parser boundary.

The same work adds a segment-only helper. It emits the encrypted source segment
only. It doesn't add `/enc/`, processing options, output suffixes, or
signatures.

The parser should also add imgproxy's SEO filename suffix mode for Base64 and
encrypted source URLs. That keeps the shared encoded-source parser behavior
aligned instead of adding the option only for one source kind.

## Current behavior

`ImagePlug.Parser.Imgproxy.Path.split_source/1` rejects a first source segment of
`enc` with `{:unsupported_source_kind, "enc"}`. The wire conformance test
`"encrypted source marker stops before cache lookup and origin fetch"` asserts
that this happens before source resolution telemetry, cache lookup, cache write,
or origin fetch.

Base64 encoded source URLs already decode to a normal source identifier before
`PlanBuilder` runs. Cache tests assert that plain and encoded spellings of the
same source produce the same canonical plan and cache key data.

ImagePlug doesn't currently support `IMGPROXY_BASE64_URL_INCLUDES_FILENAME`.
The support matrix marks it as missing, and `Path.parse_source(:encoded, ...)`
joins all encoded source chunks before splitting `.format`.

## Imgproxy behavior to match

Imgproxy's encrypted source URL docs define the segment as:

```text
base64url(iv <> aes-cbc-pkcs7(source_url))
```

The IV is 16 bytes. The key is `IMGPROXY_SOURCE_URL_ENCRYPTION_KEY`, a
hex-encoded AES key whose decoded length is 16, 24, or 32 bytes.

Incoming URLs use `/enc/<segment>`. Output format suffixes use the same encoded
source form as Base64 sources, for example `/enc/<segment>.webp`.

Imgproxy examples generate encrypted segments outside the server. They use a
random IV, prepend it to the ciphertext, and encode with unpadded URL-safe
Base64. The docs call out the CDN cache tradeoff: a random IV makes the same
source URL produce different path strings. They suggest caller-owned IV storage
or a deterministic IV derived from an HMAC of the source URL with a different
key.

## Public configuration

Add an imgproxy parser option:

```elixir
imgproxy: [
  source_url_encryption_key: "1eb5...",
  base64_url_includes_filename: true
]
```

`source_url_encryption_key` is a hex string only. Validation decodes it during
`ImagePlug.init/1` through the existing imgproxy option validation path. The
decoded key must be 16, 24, or 32 bytes. Empty, malformed, or wrong-length keys
raise `ArgumentError` during initialization.

The validated parser config should store decoded key material, not the submitted
hex string. A small parser-owned config struct or decoded value is fine, as long
as request parsing doesn't keep or re-decode the raw option.

`base64_url_includes_filename` is a boolean and defaults to `false`. It matches
imgproxy's `IMGPROXY_BASE64_URL_INCLUDES_FILENAME` behavior for Base64 and
encrypted source URLs.

When the option is absent, `/enc/...` remains unsupported. It may fail after
signature verification and option parsing, but it must still fail before source
resolution, cache lookup, or source fetch.

## Parser flow

Add `ImagePlug.Parser.Imgproxy.SourceEncryption` under the imgproxy parser
namespace. It owns encryption-key normalization, source decryption, and PKCS#7
padding checks. Keep it internal to the imgproxy parser boundary.

Expose the segment helper through `ImagePlug.Parser.Imgproxy` instead of
exporting `SourceEncryption`. The boundary should stay narrow: parser internals
remain private, while the top-level imgproxy parser module owns the supported
compatibility helper.

`Path.split_source/1` should recognize `enc` as a source kind instead of
rejecting it. This should only apply when the first raw source segment is exactly
`enc`. Existing encoded source chunks named `encA`, later `plain` chunks, and
colon-bearing option segments keep their current behavior.

Parsing then follows the existing order:

1. `Path.extract/1` repairs the request path.
2. `Signature.verify/3` checks the repaired signed path before decryption.
3. `Options.parse/2` applies processing options and presets.
4. `Path.parse_source/3` parses the source kind with normalized source parsing
   config.
5. `ParsedRequest` stores a plain source identifier.
6. `PlanBuilder` translates the source through `ImagePlug.Parser.Imgproxy.Source`.

Base64 and encrypted source parsing should share source-part preparation:

- if `base64_url_includes_filename` is `true` and there is more than one source
  segment, discard the final segment as an SEO filename
- join the remaining encoded chunks without `/`
- split the optional `.format` suffix
- reject repeated suffix separators

This matches imgproxy's ordering: it drops the filename before joining parts and
before splitting `.format`, so `<payload>.webp/puppy.jpg` resolves as payload
`<payload>` with explicit output format `webp`.

Base64 parsing decodes the prepared payload with unpadded URL-safe Base64 after
trimming trailing `=`. Encrypted parsing decodes the prepared payload the same
way, decrypts it, and checks the plaintext as UTF-8.

This first slice still excludes `IMGPROXY_BASE_URL` and
`IMGPROXY_URL_REPLACEMENTS` preprocessing after Base64 decoding or encrypted
source decryption. The support matrix and path API docs should state those
limits.

The decrypted value should enter `ParsedRequest` as `source_kind: :plain`.
`PlanBuilder` shouldn't need an encrypted-source branch. Source adapters,
output negotiation, response filenames, and cache key material continue to see
the normalized source identifier.

## Decryption rules

`SourceEncryption.decrypt_source/2` should reject these cases before source
translation:

- missing encrypted segment
- invalid Base64URL input
- decoded payload shorter than 32 bytes
- ciphertext length that's not divisible by 16 after the IV
- invalid AES-CBC padding
- plaintext that's not valid UTF-8
- missing encryption key

The public Plug response should remain a 400 parser failure for these cases.
With a configured key, all encrypted-source parse failures should collapse to
the same public reason before `handle_error/2`. Response bodies must not reveal
whether Base64 decoding, block sizing, padding, or UTF-8 validation failed.
Tests should assert that the response body is the same for representative
encrypted-source failures and that there is no source resolution telemetry,
cache lookup, cache write, or origin fetch.

Expected encrypted-source parse failures should return tagged errors rather than
raise. Telemetry for these failures should use the same parser error category and
safe metadata shape. It shouldn't emit parse exception events or detailed
padding, block-size, Base64, or UTF-8 tags.

## Segment helper

Expose a segment-only helper:

```elixir
ImagePlug.Parser.Imgproxy.encrypt_source_url(source_url, hex_key, opts \\ [])
```

Add `@doc` and `@spec` on the public helper. It returns
`{:ok, segment}` or `{:error, reason}`. The returned segment is the value used
after `/enc/`, without the `/enc/` prefix and without processing options,
signatures, or output suffixes.

Use stable helper error reasons:

- `:invalid_source_url` for non-binary source URLs
- `:invalid_key` for non-binary, malformed, empty, or wrong-length keys
- `:invalid_iv` for non-binary or non-16-byte IVs
- `:invalid_options` for non-keyword options or unknown option keys

Behavior:

- accepts a binary source URL and a hex string key
- decodes and validates the key using the same rules as parser config
- returns errors instead of raising for malformed runtime input
- uses `opts[:iv]` when supplied
- requires `iv` to be exactly 16 bytes
- uses `:crypto.strong_rand_bytes(16)` when `iv` is absent
- applies PKCS#7 padding
- encrypts with AES-CBC
- adds the IV before the ciphertext
- returns unpadded URL-safe Base64

The first helper doesn't add deterministic IV derivation. Applications that
need stable CDN paths can pass a deterministic IV. The docs should say that IV
reuse is safe only for the same source URL and that callers own this
cryptographic state. Recommend deriving deterministic IVs with a separate HMAC
key, not the imgproxy URL signing key. Don't show a constant-IV production
example.

## Security behavior

This design stays compatible with imgproxy: encrypted URLs work when signature
checking is off and callers configure the encryption key.

The docs should say that production encrypted URL callers should sign requests.
Unsigned encrypted URLs are compatible with imgproxy, but unauthenticated
AES-CBC ciphertext lacks integrity and source authorization. It can still leak
through status, timing, source translation, or fetch behavior. Treat unsigned
encrypted URLs as an unsafe compatibility mode, not a confidentiality boundary.
Signature verification already happens before source parsing and decryption. A
tampered encrypted segment changes the signed path, so a valid signed request
doesn't expose AES-CBC padding errors to callers.

Don't make padding failure distinguishable from other encrypted-source parse
failures in public responses, docs, logs, or telemetry. Internally tagged errors
are fine for tests close to `SourceEncryption`, but wire tests should assert the
shared public response body and side-effect boundaries.

Key validation errors must not echo the submitted key. Keep messages generic,
matching the existing signature config style.

## Tests

Add focused parser and helper tests:

- normalize valid 16, 24, and 32 byte hex keys
- reject malformed, empty, and wrong-length keys during config validation
- encrypt with fixed IV and decrypt back to the source URL
- helper returns stable errors for malformed keys, non-binary source URLs,
  non-keyword options, unknown options, non-binary IVs, short IVs, and long IVs
- property test helper/decrypt round trips across 16, 24, and 32 byte keys,
  source lengths around AES block boundaries, generated IVs, and generated SEO
  filename segments
- decrypt the example payload from imgproxy docs with the documented key
- parse `/enc/<payload>.webp` as decrypted source plus explicit format
- with `base64_url_includes_filename: true`, parse Base64
  `<payload>.webp/puppy.jpg` as decoded source plus explicit format
- with `base64_url_includes_filename: true`, parse encrypted
  `enc/<payload>.webp/puppy.jpg` as decrypted source plus explicit format
- keep current behavior when `base64_url_includes_filename` is false
- reject invalid Base64, short payload, unaligned ciphertext, invalid padding,
  and non-UTF-8 plaintext
- reject missing-payload variants such as `/enc`, `/enc/`, and `/enc/.webp`
- reject malformed encryption keys without including the key value in exception
  messages
- preserve `Path.split_source/1` regressions for exact first-segment `enc`,
  `encA`, later `plain` chunks, and colon-bearing options before encrypted
  sources

Add wire-level tests:

- `/enc/<payload>` succeeds through `ImagePlug.call/2`
- `/enc/<payload>.webp` bypasses `Accept` negotiation like encoded suffixes
- plain, Base64 encoded, and encrypted spellings of the same source share a
  filesystem cache entry
- Base64 and encrypted SEO filename suffixes don't enter canonical plan or
  cache key material with filename mode on
- different SEO filename suffixes for the same Base64 or encrypted source share
  the same internal cache entry with filename mode on
- two encrypted spellings of the same source with different IVs share the same
  canonical plan and cache key material
- missing encryption key rejects before source resolution, cache, and origin
- malformed encrypted payload rejects before source resolution, cache, and
  origin
- malformed encrypted payload failures return the same public response body
  across Base64, block-size, padding, and UTF-8 failures
- malformed encrypted payload failures emit the same safe parser telemetry
  category and no parse exception event across representative failure classes
- signed encrypted URLs check the repaired encrypted path before decryption,
  including an invalid signature plus malformed encrypted payload case
- signed Base64 and encrypted URLs include the SEO filename segment in the raw
  signed path, so changing that filename without recomputing the signature
  fails before source parsing

Update docs:

- `docs/imgproxy_support_matrix.md`: mark encrypted source URLs and AES-CBC
  helper support as supported or partial according to the implemented scope;
  mark `IMGPROXY_BASE64_URL_INCLUDES_FILENAME` as supported for Base64 and
  encrypted source URLs
- `docs/imgproxy_path_api.md`: describe `/enc/`, key config, suffix behavior,
  filename suffix mode, side-effect boundaries, signing recommendation, and
  segment helper limits

## Verification

Before finishing implementation, run:

```bash
mise exec -- mix test test/parser/imgproxy/path_test.exs
mise exec -- mix test test/parser/imgproxy/source_encryption_test.exs
mise exec -- mix test test/parser/imgproxy_test.exs
mise exec -- mix test test/image_plug/imgproxy_wire_conformance_test.exs
mise exec -- mix test test/image_plug/cache/key_test.exs
mise exec -- mix compile --warnings-as-errors
mise exec -- mix format --check-formatted
mise exec -- mix credo --strict
mise exec -- mix test
mise exec -- vale --no-global docs/superpowers/specs/2026-05-21-imgproxy-encrypted-urls-design.md docs/imgproxy_support_matrix.md docs/imgproxy_path_api.md
```
