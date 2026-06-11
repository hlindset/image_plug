# imgproxy differential conformance — fixtures

Reference fixtures generated from a pinned `darthsim/imgproxy` container. The
comparison test (`test/image_pipe/imgproxy_differential_conformance_test.exs`) reads
them on the default `mix test` lane — no Docker in the hot path. It decodes both
imgproxy's committed output and ImagePipe's live output and compares pixels.

## Regenerate (requires Docker)

First time in a worktree, run `mise run diff:setup` once — it fetches the
`IMGPROXY_DIFF`-gated dep (testcontainers) and compiles, so the bake commands below
work without per-command env juggling.

1. Add or edit a constellation in `constellations.ex`. (`gen_fixtures` parses every
   constellation's path first and aborts — listing the offenders — before starting the
   container, so a typo'd or unsupported option fails fast rather than after a bake.)
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

## Triage a bake (no Docker)

When a freshly baked case fails the conformance lane, `mix imgproxy.diagnose` prints a
one-line summary per constellation — output dims, band layout, the maximum band-byte
delta, a `>Δ2`/`>Δ16`/`>Δ32` histogram, and PASS/over-budget against the authored tol —
by rendering ImagePipe live against the committed fixture (the same `Harness` the
conformance test uses):

```shell
mise exec -- mix imgproxy.diagnose exif_extend_south trim_resize_high_freq   # specific cases
mise exec -- mix imgproxy.diagnose                                           # whole suite
```

**Reading it — skew vs structural.** `maxΔ` is the deciding signal:

- **Diffuse resampling skew** (a libvips-version difference, not a bug) keeps `maxΔ` low —
  tens of levels — even when many band-bytes exceed Δ2. Absorb it with a tolerance.
- **A placement/crop/scale shift** misaligns high-contrast edges, pushing `maxΔ` toward
  ~255. That is a real divergence — never widen a tol to hide it; quarantine (`:triage` +
  a tracking issue) or fix.
- **A band/dim mismatch** prints `FINDING` (not pixel-comparable) — itself a divergence
  (e.g. an extend that adds a spurious alpha channel, #220).

**Tolerance conventions** (`tol: %{threshold, budget}` on the constellation; default
`Δ2 / budget 64`):

- Sharp-edge sources (`marker`/`border`) with a small AA seam at one edge: keep the
  **strict Δ2** threshold and widen only the **budget** just above the measured seam —
  more sensitive than raising the threshold, since a structural shift blows the budget.
- Zone-plate / heavy-downscale sources (`high_freq`, rotated EXIF blocks): the skew is
  diffuse and higher-amplitude, so set the **threshold just above the measured `maxΔ`**
  with a tight budget (Δ32 is typical; the worst cells need more).

After changing only a `tol`, refresh the authored hashes with `mix imgproxy.reauthor`
(no Docker) rather than re-baking.

## The per-PR loop

1. Translate each backlog item into a `constellations.ex` entry (real parser forms;
   `verdict: :equal` by default, `:diverges` only for a known algorithmic divergence).
2. Bake once (above) — one regen covers every changed fixture. The bake is the oracle:
   imgproxy's output can't be authored wrong, only the `verdict`/`tol`.
3. `mix imgproxy.diagnose` the failures and sort each: PASS at default → keep; skew over
   budget → set `tol` + a one-line rationale, `reauthor`; genuine divergence → quarantine
   (`:triage` + tracking issue) or fix.
4. Green the default lane (`mix test`) + the precommit gate.
5. Sync docs (`docs/imgproxy_support_matrix.md` if a coverage/divergence claim moved; the
   quarantine table here).

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
require a manifest reauthor. No constellations are currently quarantined. The cases
quarantined during earlier triage have all been resolved and now run in the default lane:

| constellation | surfaced | resolved |
|---|---|---|
| `extend_ar_dpr_marker` | [#199](https://github.com/hlindset/image_pipe/issues/199) — stage-6 fit+dpr rounding fold (two rounds vs imgproxy's single `imath.Scale`) | [#218](https://github.com/hlindset/image_pipe/pull/218) — fold fit/zoom/dpr into one `imath.Scale` per axis |
| `extend_offset_east_marker` | [#200](https://github.com/hlindset/image_pipe/issues/200) — stage-10 extend east/south offset sign + clamp | [#218](https://github.com/hlindset/image_pipe/pull/218) — subtract + clamp the offset for right/bottom anchors |
| `exif_5_cover_rot90` / `exif_7_cover_rot90` | [#211](https://github.com/hlindset/image_pipe/issues/211) — stage-7 transpose/transverse ∘ user `rot:90` 1px edge seam | [#219](https://github.com/hlindset/image_pipe/pull/219) — exact `vips_rot` instead of the affine `vips_rotate` |

## Resolved bootstrap findings (#194–#197)

The first bootstrap (imgproxy `42.20.2` vs ImagePipe `8.18.2`) surfaced four
discrepancies, all since resolved:

| constellation | opts | finding | resolution |
|---|---|---|---|
| `min_dims_clamp` | `rs:fit:300:300/mw:280/mh:280` | ImagePipe 373×280 vs imgproxy 300×280 | **Bug fixed** ([#194](https://github.com/hlindset/image_pipe/issues/194)): the fit path lacked imgproxy's `cropToResult`, so the `mw`/`mh` upscale was never cropped back to the requested box. Now `:equal` with a Δ32 tol absorbing libvips-version resampling skew on the zone-plate source (max Δ27, no structural flips). |
| `extend_small` | `rs:fit:300:200/ex:1` | ~0.67% over Δ2 in the padded region | **Bug fixed** ([#195](https://github.com/hlindset/image_pipe/issues/195)): `ExtendCanvas` centered with a floor of `(canvas−image)/2` instead of imgproxy's `ShrinkToEven(canvas−image+1, 2)`, slipping content 1px. Now `:equal` at 0 over Δ2. |
| `extend_ar_small` | `rs:fit:300:200/exar:1` | ~0.5% over Δ2 | **Bug fixed** ([#196](https://github.com/hlindset/image_pipe/issues/196)): same center-placement root cause as #195. Now `:equal` at 0 over Δ2. |
| `fill_down_marker` | `rs:fill-down:500:500` | 166 band-bytes over Δ2 (≈0.02%) | **Sub-pixel seam** ([#197](https://github.com/hlindset/image_pipe/issues/197)): localized at one sharp red→dark marker edge (max Δ14, edge not shifted), libvips-version anti-aliasing — not a placement shift. `:equal` with budget widened to 256 (a real crop shift blows far past it). |

All constellations pass on the default lane, with none currently quarantined.
