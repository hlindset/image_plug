# imgproxy differential conformance — fixtures

Reference fixtures generated from a pinned `darthsim/imgproxy` container. The
comparison test (`test/image_pipe/imgproxy_differential_conformance_test.exs`) reads
them on the default `mix test` lane — no Docker in the hot path. It decodes both
imgproxy's committed output and ImagePipe's live output and compares pixels.

## Regenerate (requires Docker)

1. Add or edit a constellation in `constellations.ex`.
2. `MIX_ENV=test IMGPROXY_DIFF=1 mise exec -- mix compile --force`
   (the `--force` is required: toggling `IMGPROXY_DIFF` does not by itself trigger a
   recompile, so the env-gated `gen_fixtures` task module won't otherwise be defined.)
3. `MIX_ENV=test IMGPROXY_DIFF=1 mise exec -- mix imgproxy.gen_fixtures`
4. `MIX_ENV=test mise exec -- mix compile --force` (rebuild without the dep so a plain
   `mix test` doesn't see the now-stale generator module).
5. Commit the changed `fixtures/`, `manifest.exs`, and `REPORT.md`. Review the
   `REPORT.md` diff (not the binary PNGs) for what moved.

For a `tol` tweak or a `:diverges`→`:equal` verdict flip (no pixels change), refresh the
manifest's authored hashes without Docker: `MIX_ENV=test mise exec -- mix imgproxy.reauthor`.

Rebuild the source images only deliberately (a libvips bump must not silently change
inputs): `MIX_ENV=test mise exec -- mix imgproxy.gen_sources`.

## libvips skew — warn-and-attempt

Fixtures are baked by the container's libvips (recorded as `imgproxy_libvips` in
`manifest.exs`). ImagePipe tracks a bleeding-edge libvips (via the custom Vix fork)
while imgproxy lags, so the versions rarely match. Empirically the ✅ stages still
agree to tolerance across minor libvips gaps, so the test **compares anyway and prints
a one-time warning** when the versions differ — a failure under skew may reflect a
libvips version difference rather than an ImagePipe regression. (`:diverges`
constellations always run regardless of skew, since the divergence they pin is
algorithmic, not kernel-version-dependent.)

Validated at bootstrap: imgproxy libvips `42.20.2` (≈ 8.17.x) vs ImagePipe `8.18.2`
produced **0.0% pixel difference over Δ2** on every ✅ stage.

## Known discrepancies (pending triage)

The first real bootstrap (imgproxy `42.20.2` vs ImagePipe `8.18.2`) found four
constellations where ImagePipe and imgproxy genuinely differ. These tests currently
**fail** — they are recorded findings awaiting triage (is each an ImagePipe bug to fix,
an acceptable divergence to mark `:diverges`, or, for the borderline one, a tolerance
to widen?). They are NOT yet classified.

| constellation | opts | observed | notes |
|---|---|---|---|
| `min_dims_clamp` | `rs:fit:300:300/mw:280/mh:280` (1600×1200 src) | ImagePipe **373×280**, imgproxy **300×280** | Dimension divergence in min-width/height semantics. After `fit`→300×225, the `mh:280` minimum forces an upscale; ImagePipe preserves aspect (→373×280), imgproxy yields 300×280. Most likely a genuine ImagePipe behavior difference. |
| `extend_small` | `rs:fit:300:200/ex:1` (small src) | ~0.67% of band-bytes exceed Δ2 | Divergence in the extended/padded region — extend background or edge handling differs. |
| `extend_ar_small` | `rs:fit:300:200/exar:1` | ~0.5% exceed Δ2 | Same family as `extend`. |
| `fill_down_marker` | `rs:fill-down:500:500` (marker src) | 166 band-bytes over Δ2 (≈0.02%) | Tiny, but above the 0.0% noise floor every other resize shows — a small fill-down crop-seam difference. Borderline: may just need a wider per-constellation `tol`. |

All other constellations (the 22 ✅ + the `#124` `scp0` divergence) pass.
