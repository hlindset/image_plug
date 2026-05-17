# Wire-Level Imgproxy Conformance Tests

## Goal

Add representative Plug-level tests that prove user-facing imgproxy behavior through real requests and response inspection, not only parser, planner, cache, or transform unit tests.

## Why This Matters

The existing test suite has strong unit and property coverage around parser grammar, cache keys, filesystem cache behavior, output negotiation, request safety, and transform execution. The missing layer is a compact set of wire-level examples that assert what users actually observe: status, headers, content type, decoded dimensions, cache behavior, and equivalence across URL option order.

## Proposed Coverage

- Equivalent option order:
  - Different imgproxy option order should produce equivalent output behavior.
  - Where cache is enabled, equivalent semantic requests should share cache behavior when canonical data matches.
- Output negotiation:
  - automatic output with `Accept: image/avif,image/webp`
  - automatic output with `Accept: image/webp`
  - `q=0` exclusions
  - `Vary: Accept` only when automatic output negotiation uses `Accept`
- Explicit output:
  - `f:webp`
  - `f:jpeg`
  - plain source `@webp`
  - explicit formats should bypass `Accept` and avoid unnecessary `Vary: Accept`
- Representative geometry:
  - fit
  - fill/cover
  - force
  - crop
  - gravity anchors
  - decoded output dimensions should match expectations
- Safety:
  - invalid signatures, expired requests, malformed paths, and invalid options should return before origin fetch/cache access.
- Cache:
  - second equivalent request can be served from cache.
  - automatic output varies by normalized `Accept` candidates, not raw header noise.

## Scope Control

Keep this representative, not exhaustive. Broad grammar and edge-case coverage should stay in parser/property tests. Wire tests should cover the public contract users depend on.

## Likely Files

- New focused test file such as `test/parser/imgproxy_wire_conformance_test.exs` or `test/image_plug/imgproxy_wire_conformance_test.exs`.
- Existing test support modules under `test/support/image_plug/*` if reusable origin/cache probes are needed.
- No production code changes unless tests expose a real bug.

## Validation

- `mise exec -- mix test test/image_plug/imgproxy_wire_conformance_test.exs` or the final chosen focused file.
- Relevant existing parser, output, cache, and request safety tests.
- `mise exec -- mix test`
- `mise exec -- mix compile --warnings-as-errors` if any behavior changes are made.
