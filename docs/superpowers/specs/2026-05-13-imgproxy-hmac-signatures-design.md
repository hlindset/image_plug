# Imgproxy HMAC Signatures Design

## Context

ImagePlug currently accepts imgproxy-compatible URLs with a required signature
path segment, but only the disabled-signing placeholders `_` and `unsafe` are
valid. The support matrix marks HMAC URL signatures as missing.

The local imgproxy reference implementation verifies signatures before parsing
processing options or resolving the source image. It computes a URL-safe
Base64 HMAC-SHA256 digest over the path after the signature, including the
leading slash. The HMAC message is `salt <> signed_path`, and multiple key/salt
pairs are supported for rotation. Imgproxy also supports `trusted_signatures`,
which are exact signature strings accepted before HMAC decoding.

ImagePlug should add this as imgproxy-provider compatibility only. Signature
validation is request authorization, not product-neutral image intent, so it
must not enter `ImagePlug.Plan`, transform operations, output negotiation, or
cache key data.

## Goals

- Support imgproxy-compatible HMAC signatures for `ImagePlug.Parser.Imgproxy`.
- Support trusted signatures in the same first slice.
- Validate signing configuration during Plug initialization.
- Reject invalid signatures before option parsing, planning, origin identity,
  cache lookup, or origin fetch.
- Keep the canonical request model product-neutral.
- Keep disabled-signing behavior narrow: without signing config, only `_` and
  `unsafe` remain accepted placeholders.

## Non-Goals

- Do not add signatures to `ImagePlug.Plan`.
- Do not vary cache keys by signature string.
- Do not add absolute source URL support, encoded source URLs, encrypted source
  URLs, or imgproxy info endpoints.
- Do not match every imgproxy wire-level behavior. ImagePlug intentionally keeps
  disabled signing narrower than upstream, treats trusted-only config as exact
  trusted-signature authorization instead of disabled signing, and keeps URL
  source execution out of this slice even though signature parsing should
  already apply imgproxy `fixPath`.
- Do not add globally generic signing support for every parser.

## Configuration

Add imgproxy-specific parser configuration under the existing Plug options:

```elixir
[
  parser: ImagePlug.Parser.Imgproxy,
  root_url: "http://origin.test",
  imgproxy: [
    signature: [
      keys: ["736563726574"],
      salts: ["68656c6c6f"],
      signature_size: 32,
      trusted_signatures: ["local-dev", "migration-token"]
    ]
  ]
]
```

`keys` and `salts` are hex-encoded non-empty strings. Their list lengths must
match when either list is present.
`signature_size` is the number of digest bytes used before Base64 encoding and
must be in `1..32`; it defaults to `32`. `trusted_signatures` defaults to `[]`
and must be a list of non-empty strings. At least one authorization method is
required when `imgproxy[:signature]` is present: either one or more key/salt
pairs, one or more trusted signatures, or both.

If `imgproxy[:signature]` is absent, signature checking is disabled and the
current `_` and `unsafe` placeholders remain the only valid signature segments.
If signing config is present, `_` and `unsafe` are not special unless explicitly
listed in `trusted_signatures`.

This disabled-signing behavior is an intentional ImagePlug hardening divergence
from upstream imgproxy, which accepts any signature segment when no key/salt
pairs are configured. Trusted-only config is also intentionally stricter:
ImagePlug accepts only configured trusted signatures, while upstream returns
success before checking trusted signatures when key/salt pairs are absent.

## Architecture

Add a parser-owned signature module:

```elixir
ImagePlug.Parser.Imgproxy.Signature
```

Responsibilities:

- Validate and normalize signature config.
- Decode hex key/salt values during initialization.
- Verify a request signature against normalized config.
- Return tagged parser errors for malformed or invalid signatures.

`ImagePlug.init/1` should validate core/cache options first, then dispatch
parser-owned option validation from the top-level `ImagePlug` module, where the
parser boundary is already an allowed dependency. `ImagePlug.Request.Options`
must remain parser-free. In this slice, use a narrow explicit clause for
`ImagePlug.Parser.Imgproxy` instead of adding a broad parser behaviour callback.

The imgproxy parser owns the NimbleOptions schema for `:imgproxy` and returns a
normalized parser config, including decoded key/salt pairs. The top-level
`:imgproxy` schema should reject unknown keys; signing values belong under
`:imgproxy[:signature]`. Core should not know the shape of imgproxy signing
options.

This keeps dependencies aligned:

- `ImagePlug` coordinates selected-parser option validation.
- `ImagePlug.Request` remains independent of parser modules.
- `ImagePlug.Parser.Imgproxy` owns imgproxy option validation.
- `ImagePlug.Plan`, `ImagePlug.Cache`, request execution, origin fetching,
  response sending, output, and transform code do not depend on signature
  details.

## Request Flow

`ImagePlug.Parser.Imgproxy.parse_request/2` should derive both verification and
parsing inputs from the parser-visible raw request path:

- `signature`: the first raw path segment after any mounted `script_name`.
- `signed_path`: the raw request path after the signature segment, including
  its leading slash and preserving empty path segments and trailing slashes.
- `path_info`: slash-preserving parser segments from the same raw path used for
  `signed_path`.

The parser verifies `signature` against `signed_path` before splitting the
source marker or parsing options.

Before verification and parsing, apply imgproxy-compatible `fixPath` to the path
after the signature:

- Replace `%3A` with `:` in the options portion before `/plain/`.
- Repair normalized source URL schemes in the `/plain/` portion, so `scheme:/x`
  becomes `scheme://x`, and `local:/x` becomes `local:///x`.

Verification behavior:

1. If signing is disabled, accept only `_` and `unsafe`.
2. If signing is enabled and `signature` exactly matches a trusted signature,
   accept without Base64 decoding or HMAC verification.
3. Otherwise decode `signature` using URL-safe Base64 without padding.
4. For each configured key/salt pair, compute:

   ```elixir
   :crypto.mac(:hmac, :sha256, key, salt <> signed_path)
   ```

5. Truncate the digest to `signature_size` bytes before comparison.
6. Use constant-time comparison for equal-length binaries.
7. Accept when any configured pair matches, otherwise reject.

Use the parser-visible request path, after `fixPath`, for `signed_path` and for
subsequent imgproxy option/source parsing, not decoded source segments,
canonicalized plan data, or normalized `conn.path_info`. When ImagePlug is
mounted under a Plug `script_name`, strip only the mounted prefix before
removing the first signature segment. This preserves imgproxy's slash-sensitive
signing semantics while keeping signatures scoped to the path seen by this
parser.

## Errors

Keep errors parser-owned and stable enough for tests without over-specifying
private formatting. Suggested tags:

- `{:unsupported_signature, signature}` for disabled signing with a non-placeholder.
- `{:invalid_signature_encoding, signature}` for malformed Base64 signatures.
- `:invalid_signature` for HMAC mismatch.
- `{:invalid_imgproxy_signature_config, reason}` for initialization errors.

All request-time signature failures should return through
`ImagePlug.Parser.Imgproxy.handle_error/2` as HTTP 403, matching upstream
imgproxy's authorization failure status. Other parser validation failures should
continue returning HTTP 400. Initialization failures should raise
`ArgumentError` through option validation.

## Cache Semantics

Signatures must not participate in cache identity. A valid HMAC signature and a
trusted signature for the same source, options, output policy, and configured
vary inputs should resolve to the same cache key.

This follows ImagePlug's current cache contract: cache identity is based on
resolved origin identity, canonical plan fields, configured vary inputs, and
normalized automatic output negotiation inputs. Request authorization proofs do
not change image output.

## Testing

Add focused parser tests:

- Disabled signing accepts `_` and `unsafe`.
- Disabled signing rejects arbitrary signatures.
- Enabled signing accepts a valid full-size HMAC signature.
- Enabled signing rejects `_` and `unsafe` unless trusted.
- Enabled signing rejects invalid Base64 signatures.
- Enabled signing rejects valid Base64 with the wrong digest.
- Multiple key/salt pairs allow key rotation.
- `signature_size` supports truncated signatures.
- Trusted signatures are accepted before HMAC decoding.
- Trusted signatures are exact string matches.

Add initialization tests:

- Unknown top-level `:imgproxy` keys raise instead of silently disabling
  signing.
- Malformed hex key/salt values raise.
- Key/salt count mismatch raises.
- `signature_size` outside `1..32` raises.
- `trusted_signatures` rejects non-lists and empty/non-binary values.
- Empty decoded key/salt values raise.
- Trusted-only configuration is valid and accepts exact trusted signatures.

Add request safety tests:

- Invalid signature returns before source identity resolution, cache lookup, and
  origin fetch.
- Invalid signature returns before option parsing and planning through the
  public Plug entry point.
- Query strings are excluded from the signed bytes, matching upstream request
  handler behavior.
- `fixPath` decoding of `%3A` in options is applied before signature
  verification and option parsing.
- `fixPath` repair of `/plain/` URL schemes is applied before signature
  verification and source parsing.
- Positive raw-path parser vectors prove signatures are computed over duplicate
  slash and trailing slash paths without normalization.
- Mounted `script_name` requests strip only the mounted prefix before signature
  verification.
- Trusted signature and equivalent HMAC-signed request share cache identity.

### Upstream Primitive Compatibility Vectors

Copy these upstream imgproxy vectors into low-level signature module tests so
the implementation is pinned to imgproxy-compatible signing behavior. These are
direct `VerifySignature/2` vectors over exact signed bytes. The upstream
primitive vector signs `"asd"` without a leading slash; parser and request tests
must use signed paths that begin with `/`.

From `/Users/hlindset/src/image_plug/local/imgproxy-master/security/signature_test.go`:

```elixir
%{
  keys: ["746573742d6b6579"],
  salts: ["746573742d73616c74"],
  signed_path: "asd",
  signature_size: 32,
  valid_signature: "dtLwhdnPPiu_epMl1LrzheLpvHas-4mwvY6L3Z8WwlY",
  truncated_signature_size: 8,
  truncated_signature: "dtLwhdnPPis"
}
```

The same upstream test also covers key rotation:

```elixir
%{
  keys: ["746573742d6b6579", "746573742d6b657932"],
  salts: ["746573742d73616c74", "746573742d73616c7432"],
  signed_path: "asd",
  first_signature: "dtLwhdnPPiu_epMl1LrzheLpvHas-4mwvY6L3Z8WwlY",
  second_signature: "jbDffNPt1-XBgDccsaE-XJB9lx8JIJqdeYIZKgOqZpg",
  invalid_truncated_signature_at_default_size: "dtLwhdnPPis"
}
```

Trusted-signature compatibility should preserve imgproxy's exact primitive
fixture, including the upstream spelling:

```elixir
%{
  trusted_signatures: ["truested"],
  accepted_signature: "truested",
  rejected_signature: "untrusted",
  signed_path: "asd"
}
```

Add an ImagePlug-specific trusted-signature vector with a malformed Base64URL
signature to prove trusted signatures are accepted by exact match before Base64
decoding:

```elixir
%{
  trusted_signatures: ["local-dev!"],
  accepted_signature: "local-dev!",
  signed_path: "/w:300/plain/images/cat.jpg"
}
```

### Upstream Request-Handler Fixture

From `/Users/hlindset/src/image_plug/local/imgproxy-master/processing_handler_test.go`, keep this fixture as
upstream request-handler evidence that `unsafe` fails when signing is enabled
and the signed path succeeds. Use it as a low-level signature-module vector,
not as an ImagePlug parser contract: `local:///test1.png` is imgproxy source
syntax, while this ImagePlug slice continues to model plain sources as paths
resolved against `root_url`.

```elixir
%{
  keys: ["746573742d6b6579"],
  salts: ["746573742d73616c74"],
  unsigned_request_path: "/unsafe/rs:fill:4:4/plain/local:///test1.png",
  signed_request_path:
    "/My9d3xq_PYpVHsPrCyww0Kh1w5KZeZhIlWhsa4az1TI/rs:fill:4:4/plain/local:///test1.png"
}
```

### Public Documentation Vector

From `/Users/hlindset/src/image_plug/local/imgproxy-docs-master/.../usage/signing_url.mdx`, include the public
documentation vector as an algorithm drift check. This vector also uses
upstream-supported syntax that ImagePlug does not fully support in this slice,
so it belongs in signature-module tests, not parser tests.

```elixir
%{
  keys: ["736563726574"],
  salts: ["68656c6c6f"],
  signed_path:
    "/rs:fill:300:400:0/g:sm/aHR0cDovL2V4YW1w/bGUuY29tL2ltYWdl/cy9jdXJpb3NpdHku/anBn.png",
  signature: "oKfUtW34Dvo2BGQehJFR4Nr0_rIjOtdtzJ3QFsUcXH8"
}
```

### ImagePlug Parser Vector

Parser tests should use paths that ImagePlug already supports. Use this fixed
ImagePlug-supported parser URL vector rather than generating the expected
signature inside the test:

```elixir
%{
  keys: ["746573742d6b6579"],
  salts: ["746573742d73616c74"],
  signed_path: "/w:300/plain/images/cat.jpg",
  signature: "NSbxuO5fQqTgDkui_3o6ho1UCFFcmzsugB2Uksho49o",
  signed_request_path:
    "/NSbxuO5fQqTgDkui_3o6ho1UCFFcmzsugB2Uksho49o/w:300/plain/images/cat.jpg"
}
```

## Documentation

Update:

- `README.md` Imgproxy Path API examples and option notes.
- `docs/imgproxy_path_api.md` signature section.
- `docs/imgproxy_support_matrix.md`, changing HMAC URL signatures from
  `Missing` to `Supported`.

Document that ImagePlug's signing support is currently imgproxy-parser specific,
that disabled signing accepts only `_` and `unsafe`, and that trusted signatures
are exact bypass strings for deployments that deliberately configure them.
Document that signatures are verified against the path after imgproxy-compatible
`fixPath`, even though absolute URL source execution remains broader parser work.
