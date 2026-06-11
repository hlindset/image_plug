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
manifest's authored hashes without Docker: `mise exec -- mix imgproxy.reauthor`.

Rebuild the source images only deliberately (a libvips bump must not silently change
inputs): `mise exec -- mix imgproxy.gen_sources`.

(`imgproxy.reauthor`, `imgproxy.gen_sources`, and `imgproxy.gen_report` live in
`test/support`, so they auto-select `MIX_ENV=test` via `mix.exs` `preferred_envs` — no
prefix needed. `imgproxy.gen_fixtures` is the exception: it also needs `IMGPROXY_DIFF=1`,
shown explicitly above.)

## Visual-diff report (no Docker)

Generate a self-contained `report.html` for eyeball triage — imgproxy vs ImagePipe
side by side, a comparison slider, two diff heatmaps (banded over the case threshold,
and raw amplified), and the live-recomputed metric/verdict/triage per constellation:

```shell
mise exec -- mix imgproxy.gen_report          # writes report.html here
mise exec -- mix imgproxy.gen_report --out /tmp/r.html
```

It renders ImagePipe live and reads the committed fixtures — no Docker, no fixture or
manifest changes. The default `report.html` is gitignored (it inlines ImagePipe PNGs as
base64; regenerate on demand). Cases needing attention (over-budget, quarantined,
dims-mismatch, a `:diverges` case that now matches, or authored-hash drift) sort to the
top, and a top-of-page counts line summarizes them. The slider and Geist fonts load from
a CDN; with no network the side-by-side panels remain the source of truth.

## libvips provenance — record both, compare anyway

Fixtures are baked by the container's libvips, recorded as `imgproxy_libvips` in
`manifest.exs`. That value is the bundled `.so` **ABI soname** (e.g. `42.20.2`): the
darthsim image exposes no libvips *release* string and ships no `vips` CLI. ImagePipe's
own libvips reports only its **release** (`Vix.Vips.version()`, e.g. `8.18.2`). The two
are different version schemes with no clean conversion, so they cannot be compared
directly — and ImagePipe tracks a bleeding-edge libvips (via the custom Vix fork) while
imgproxy lags, so they would differ regardless.

The harness therefore makes no version-match claim: it always runs the pixel comparison
and emits a one-time provenance note carrying both versions, each tagged with its scheme
(the `:equal` tolerances absorb minor libvips-version resampling differences). A failure
may still reflect a libvips-version difference rather than an ImagePipe regression — read
the note's two versions when triaging. (`:diverges` constellations pin an algorithmic
divergence, not a kernel-version one, so they are unaffected.)

Recorded at bootstrap: imgproxy libvips `42.20.2` (.so ABI soname, ≈ release 8.17.x) and
ImagePipe `8.18.2` (release) produced **0.0% pixel difference over Δ2** on every ✅ stage.

## Quarantine mechanism

A constellation can be quarantined while a discrepancy it surfaced is triaged: set a
`:triage` key on its constellation map (a short reason + tracking issue). The
comparison test then tags it `:imgproxy_triage`, which `test/test_helper.exs` excludes
by default, so a plain `mix test` stays green and the case shows as skipped rather than
failed. Run the quarantined cases with:

```shell
MIX_ENV=test mise exec -- mix test test/image_pipe/imgproxy_differential_conformance_test.exs --include imgproxy_triage
```

`:triage` is not an authored field, so quarantining or un-quarantining alone does not
require a manifest reauthor. There are currently **no quarantined constellations** —
the bootstrap's four findings are all resolved (see below).

## Resolved bootstrap findings (#194–#197)

The first bootstrap (imgproxy `42.20.2` vs ImagePipe `8.18.2`) surfaced four
discrepancies, all since resolved:

| constellation | opts | finding | resolution |
|---|---|---|---|
| `min_dims_clamp` | `rs:fit:300:300/mw:280/mh:280` | ImagePipe 373×280 vs imgproxy 300×280 | **Bug fixed** ([#194](https://github.com/hlindset/image_pipe/issues/194)): the fit path lacked imgproxy's `cropToResult`, so the `mw`/`mh` upscale was never cropped back to the requested box. Now `:equal` with a Δ32 tol absorbing libvips-version resampling skew on the zone-plate source (max Δ27, no structural flips). |
| `extend_small` | `rs:fit:300:200/ex:1` | ~0.67% over Δ2 in the padded region | **Bug fixed** ([#195](https://github.com/hlindset/image_pipe/issues/195)): `ExtendCanvas` centered with a floor of `(canvas−image)/2` instead of imgproxy's `ShrinkToEven(canvas−image+1, 2)`, slipping content 1px. Now `:equal` at 0 over Δ2. |
| `extend_ar_small` | `rs:fit:300:200/exar:1` | ~0.5% over Δ2 | **Bug fixed** ([#196](https://github.com/hlindset/image_pipe/issues/196)): same center-placement root cause as #195. Now `:equal` at 0 over Δ2. |
| `fill_down_marker` | `rs:fill-down:500:500` | 166 band-bytes over Δ2 (≈0.02%) | **Sub-pixel seam** ([#197](https://github.com/hlindset/image_pipe/issues/197)): localized at one sharp red→dark marker edge (max Δ14, edge not shifted), libvips-version anti-aliasing — not a placement shift. `:equal` with budget widened to 256 (a real crop shift blows far past it). |

All constellations (the 25 ✅ + the `#124` `scp0` divergence) pass on the default lane.
