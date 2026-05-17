# Release Readiness, Docs, and Package Metadata

## Goal

Make the current ImagePlug project understandable and evaluable by someone arriving cold, without expanding the runtime feature surface or promising provider compatibility that does not exist yet.

## Why This Matters

The repo has strong architecture, safety, cache, and demo work, but the top-level presentation still reads like an internal project. Release-readiness work should make the current behavior easy to evaluate without implying that the library is published or that unsupported provider compatibility already exists.

## Proposed Scope

- Add Hex/package metadata in `mix.exs`: description, package files, maintainers, license, links, source URL, and docs module grouping.
- Add `LICENSE.md` and `CHANGELOG.md`.
- Rewrite the top of `README.md` around:
  - what ImagePlug is
  - current project status
  - installation
  - minimal Plug/Phoenix mounting example
  - first working imgproxy-style URL
  - current support boundaries
  - links to deeper imgproxy/cache/operational docs
- Keep current detailed safety and cache documentation, but move overly long sections into focused docs if the README becomes hard to scan.

## Out Of Scope

- Adding new providers.
- Adding variant APIs.
- Changing runtime behavior.
- Publishing to Hex.

## Likely Files

- `mix.exs`
- `README.md`
- `LICENSE.md`
- `CHANGELOG.md`
- Possibly `docs/*.md` if README material is split out.

## Validation

- `mise exec -- mix compile --warnings-as-errors`
- `mise exec -- mix test`
- Optionally `mise exec -- mix docs` if documentation generation is configured and dependencies are available.
