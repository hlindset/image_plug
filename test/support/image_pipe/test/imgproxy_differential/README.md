# imgproxy differential conformance — fixtures

Reference fixtures generated from a pinned `darthsim/imgproxy` container. The
comparison test (`test/image_pipe/imgproxy_differential_conformance_test.exs`) reads
them on the default `mix test` lane — no Docker in the hot path.

## Regenerate (requires Docker)

1. Add or edit a constellation in `constellations.ex`.
2. `MIX_ENV=test IMGPROXY_DIFF=1 mise exec -- mix imgproxy.gen_fixtures`
3. Commit the changed `fixtures/`, `manifest.exs`, and `REPORT.md`. Review the
   `REPORT.md` diff (not the binary PNGs) for what moved.

For a `tol` tweak or a `:diverges`→`:equal` verdict flip (no pixels change), refresh the
manifest's authored hashes without Docker: `MIX_ENV=test mise exec -- mix imgproxy.reauthor`.

Rebuild the source images only deliberately (a libvips bump must not silently change
inputs): `MIX_ENV=test mise exec -- mix imgproxy.gen_sources`.

## libvips skew

Fixtures are baked by the container's libvips (recorded in `manifest.exs`). The test
asserts pixels only when your libvips exactly matches; otherwise it skips loudly.
**CI must run on the fixtures' libvips** — the CI skew-guard test fails if it would
skip. Bump the pinned digest and regenerate on CI's libvips together.
