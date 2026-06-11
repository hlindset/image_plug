# EXIF Orientation Source Fixtures (2/3/4/5/7/8) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add committed EXIF source fixtures for orientations 2/3/4/5/7/8 and a Batch-A-shaped constellation set on each, extending the imgproxy differential conformance suite beyond the lone orientation-6 source.

**Architecture:** One shared 400×300 corner-block base image is retagged into seven `exif_N.jpg` files (rename current `exif.jpg` → `exif_6.jpg`, add 2/3/4/5/7/8) by `gen_sources`. The constellation registry gains ~22 cases (3 seams × 6 orientations + 4 user-op crosses on 5/7). Fixtures are baked by the pinned imgproxy Docker container via `gen_fixtures`; failures are triaged (tol-widen for libvips skew, or quarantine + follow-up issue for real compose bugs — this PR is test-data scoped).

**Tech Stack:** Elixir, Vix/libvips (`Image.set_orientation!`), Testcontainers + Docker (pinned `darthsim/imgproxy`), ExUnit conformance test.

Spec: `docs/superpowers/specs/2026-06-11-exif-orientation-source-fixtures-design.md`

---

## File Structure

- `test/support/mix/tasks/imgproxy.gen_sources.ex` — **modify**: replace the single orientation-6 `exif.jpg` build with a shared-base loop emitting `exif_2.jpg`…`exif_8.jpg`.
- `test/support/image_pipe/test/imgproxy_differential/sources/exif.jpg` — **delete** (replaced by `exif_6.jpg`).
- `test/support/image_pipe/test/imgproxy_differential/sources/exif_{2..8}.jpg` — **create** (generated, committed).
- `test/support/image_pipe/test/imgproxy_differential/constellations.ex` — **modify**: rework `@source_files`, re-point `rotate_exif`/`strip_exif`, append `exif_orientation_constellations/0` (22 cases).
- `test/image_pipe/imgproxy_differential/constellations_test.exs:12` — **modify**: replace `:exif_jpeg` in the `@valid_sources` allowlist with `:exif_2 … :exif_8`.
- `test/support/image_pipe/test/imgproxy_differential/fixtures/exif_*.png` — **create** (baked by imgproxy).
- `test/support/image_pipe/test/imgproxy_differential/manifest.exs` — **regenerated** by `gen_fixtures`.
- `test/support/image_pipe/test/imgproxy_differential/REPORT.md` — **regenerated** by `gen_fixtures`.
- `docs/imgproxy_support_matrix.md` — **modify**: stage-7 `rotateAndFlip` coverage now spans all 8 orientations + flip∘quarter-turn.
- `test/support/image_pipe/test/imgproxy_differential/README.md` — **modify** only if the bake produces new quarantines/skew notes.

No production (`lib/`) code changes are expected (test-data scoped; real bugs are quarantined, not fixed).

---

## Task 1: Generate the seven `exif_N.jpg` sources

**Files:**
- Modify: `test/support/mix/tasks/imgproxy.gen_sources.ex:45-51`
- Delete: `test/support/image_pipe/test/imgproxy_differential/sources/exif.jpg`
- Create: `test/support/image_pipe/test/imgproxy_differential/sources/exif_{2,3,4,5,6,7,8}.jpg`

- [ ] **Step 1: Replace the `exif` build block**

In `imgproxy.gen_sources.ex`, replace the current block (lines 45–51):

```elixir
    exif =
      400
      |> Image.new!(300, color: [200, 180, 60])
      |> Image.Draw.rect!(0, 0, 200, 150, color: [40, 40, 200])
      |> Image.set_orientation!(6)

    write!(exif, "exif.jpg", suffix: ".jpg", quality: 95)
```

with:

```elixir
    exif_base =
      400
      |> Image.new!(300, color: [200, 180, 60])
      |> Image.Draw.rect!(0, 0, 200, 150, color: [40, 40, 200])

    for o <- [2, 3, 4, 5, 6, 7, 8] do
      exif_base
      |> Image.set_orientation!(o)
      |> write!("exif_#{o}.jpg", suffix: ".jpg", quality: 95)
    end
```

Rationale: identical base pixels across all seven files; only the EXIF Orientation tag differs. `set_orientation!` mutates the tag, not the stored pixels.

- [ ] **Step 2: Run the generator**

Run: `mise exec -- mix imgproxy.gen_sources`
Expected: `Wrote sources to test/support/image_pipe/test/imgproxy_differential/sources`, and seven new `exif_*.jpg` files present.

- [ ] **Step 3: Verify the files and EXIF tags**

Run:
```bash
ls -1 test/support/image_pipe/test/imgproxy_differential/sources/exif_*.jpg
mise exec -- mix run -e 'for o <- [2,3,4,5,6,7,8] do
  {:ok, img} = Vix.Vips.Image.new_from_file("test/support/image_pipe/test/imgproxy_differential/sources/exif_#{o}.jpg")
  {:ok, v} = Vix.Vips.Image.header_value(img, "orientation")
  IO.puts("exif_#{o}.jpg orientation=#{v}")
end'
```
Expected: seven files listed; each prints `orientation=<o>` matching its filename (2..8). (`mix run` starts the app so Vix is loaded; bare `elixir -e` would not.)

- [ ] **Step 4: Remove the stale single source**

Run: `git rm test/support/image_pipe/test/imgproxy_differential/sources/exif.jpg`
Expected: `exif.jpg` staged for deletion (the generator does not delete it; `exif_6.jpg` is its replacement).

- [ ] **Step 5: Commit the sources**

```bash
git add test/support/mix/tasks/imgproxy.gen_sources.ex \
        test/support/image_pipe/test/imgproxy_differential/sources/exif_2.jpg \
        test/support/image_pipe/test/imgproxy_differential/sources/exif_3.jpg \
        test/support/image_pipe/test/imgproxy_differential/sources/exif_4.jpg \
        test/support/image_pipe/test/imgproxy_differential/sources/exif_5.jpg \
        test/support/image_pipe/test/imgproxy_differential/sources/exif_6.jpg \
        test/support/image_pipe/test/imgproxy_differential/sources/exif_7.jpg \
        test/support/image_pipe/test/imgproxy_differential/sources/exif_8.jpg
git commit -m "test(imgproxy-differential): generate exif_2..exif_8 orientation sources (#204)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 2: Wire the constellations

**Files:**
- Modify: `test/support/image_pipe/test/imgproxy_differential/constellations.ex`

- [ ] **Step 1: Rework `@source_files`**

Replace the `exif_jpeg: "exif.jpg",` line (currently line 17) with the seven orientation entries:

```elixir
    exif_2: "exif_2.jpg",
    exif_3: "exif_3.jpg",
    exif_4: "exif_4.jpg",
    exif_5: "exif_5.jpg",
    exif_6: "exif_6.jpg",
    exif_7: "exif_7.jpg",
    exif_8: "exif_8.jpg",
```

- [ ] **Step 2: Re-point the two existing EXIF constellations**

Change `rotate_exif` and `strip_exif` from `:exif_jpeg` to `:exif_6` (same bytes, new atom):

```elixir
      c("rotate_exif", :exif_6, "rs:fit:120:120"),
```
```elixir
      c("strip_exif", :exif_6, "rs:fit:120:120/sm:1"),
```

- [ ] **Step 3: Append the orientation constellations to `all/0`**

Change the closing of `all/0` so the authored list is suffixed with the new cases. The list currently ends:

```elixir
      lossy("lossy_avif", :high_freq, "rs:fill:240:180/f:avif")
    ]
  end
```

Change to:

```elixir
      lossy("lossy_avif", :high_freq, "rs:fill:240:180/f:avif")
    ] ++ exif_orientation_constellations()
  end
```

- [ ] **Step 4: Add the private builder functions**

Add these private functions (place them just above the `c/3` helper near the bottom of the module):

```elixir
  # --- #204: EXIF orientation source fixtures (2/3/4/5/7/8) ---
  #
  # Each orientation is the same 400×300 corner-block base retagged with a
  # different EXIF Orientation. The Batch-A shape (cover / non-center crop /
  # extend-with-gravity) hits the per-axis storage↔display dims, the crop-gravity
  # rotate-into-storage, and the post-flush gravity seams respectively. 5/7
  # (transpose/transverse) additionally cross with a user op (rot/flip) — the
  # deepest #146 compose, flip ∘ quarter-turn ∘ user-op.
  @exif_orientations [2, 3, 4, 5, 7, 8]

  defp exif_orientation_constellations do
    base =
      for o <- @exif_orientations, {suffix, opts} <- exif_base_seams() do
        c("exif_#{o}_#{suffix}", :"exif_#{o}", opts)
      end

    base ++ exif_transpose_crosses()
  end

  defp exif_base_seams do
    [
      {"cover", "rs:fill:200:150"},
      {"crop_no", "c:200:120/g:no"},
      {"extend_so", "rs:fit:200:300/ex:1:so"}
    ]
  end

  defp exif_transpose_crosses do
    [
      c("exif_5_cover_rot90", :exif_5, "rs:fill:200:150/rot:90"),
      c("exif_5_cover_fl", :exif_5, "rs:fill:200:150/fl:1"),
      c("exif_7_cover_rot90", :exif_7, "rs:fill:200:150/rot:90"),
      c("exif_7_cover_fl", :exif_7, "rs:fill:200:150/fl:1")
    ]
  end
```

This yields 18 base cases (`exif_2_cover`, `exif_2_crop_no`, `exif_2_extend_so`, … `exif_8_extend_so`) + 4 crosses = 22.

- [ ] **Step 5: Update the constellation well-formedness allowlist**

`test/image_pipe/imgproxy_differential/constellations_test.exs:12` has an `@valid_sources` allowlist and asserts every constellation's `source` is in it. Replace `:exif_jpeg` there with the seven new atoms:

```elixir
  @valid_sources [
    :high_freq,
    :high_freq_webp,
    :marker,
    :border,
    :alpha,
    :exif_2,
    :exif_3,
    :exif_4,
    :exif_5,
    :exif_6,
    :exif_7,
    :exif_8,
    :icc_p3,
    :small
  ]
```

(Read the file first; preserve the other entries exactly as they appear — only the `:exif_jpeg` line changes to the seven.)

- [ ] **Step 6: Compile and sanity-check the count**

Run:
```bash
mise exec -- mix compile --warnings-as-errors
MIX_ENV=test mise exec -- mix run -e 'alias ImagePipe.Test.ImgproxyDifferential.Constellations, as: C
all = C.all()
exif = Enum.filter(all, &String.starts_with?(&1.id, "exif_"))
IO.puts("total=#{length(all)} exif_prefixed=#{length(exif)}")
IO.inspect(Enum.map(exif, & &1.id))'
```
Expected: `exif_prefixed=22` (the 22 new cases; `rotate_exif`/`strip_exif` do not start with `exif_`), and the 22 ids printed. No compile warnings. `Constellations` lives under `test/support`, so it is only compiled in `MIX_ENV=test` — the `mix run` must use it.

- [ ] **Step 7: Confirm ImagePipe parses every new opt (pre-bake gate)**

Each new opt must parse in ImagePipe (a parse failure would otherwise surface only as a non-200 at conformance time, after a wasted bake). The imgproxy parser entry point is `ImagePipe.Parser.Imgproxy.parse/1`, which takes a **`%Plug.Conn{}`** (confirm the return shape in `lib/image_pipe/parser/imgproxy.ex` — treat any `{:error, _}` or raised exception as a failure):

```bash
MIX_ENV=test mise exec -- mix run -e 'import Plug.Test
alias ImagePipe.Test.ImgproxyDifferential.Constellations, as: C
for con <- Enum.filter(C.all(), &String.starts_with?(&1.id, "exif_")) do
  conn = conn(:get, C.imgproxy_path(con))
  case ImagePipe.Parser.Imgproxy.parse(conn) do
    {:error, reason} -> IO.puts("PARSE FAIL #{con.id}: #{inspect(reason)}")
    _ok -> :ok
  end
end
IO.puts("parse check done")'
```
Expected: `parse check done` with **no** `PARSE FAIL` lines. All five opt shapes (`rs:fill`, `c:W:H/g:`, `rs:fit/ex:1:so`, `rot:90`, `fl:1`) are proven in the existing suite / #203, so this should pass first try; it is cheap insurance against a typo before the Docker bake.

- [ ] **Step 8: Commit**

```bash
git add test/support/image_pipe/test/imgproxy_differential/constellations.ex \
        test/image_pipe/imgproxy_differential/constellations_test.exs
git commit -m "test(imgproxy-differential): add exif orientation constellations (#204)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 3: Bake the imgproxy fixtures

**Files:**
- Regenerate: `test/support/image_pipe/test/imgproxy_differential/fixtures/exif_*.png`, `manifest.exs`, `REPORT.md`

- [ ] **Step 1: Compile with the gated generator**

Run: `MIX_ENV=test IMGPROXY_DIFF=1 mise exec -- mix compile --force`
Expected: clean compile; the `imgproxy.gen_fixtures` task module is now defined.

- [ ] **Step 2: Bake (requires Docker; pinned `darthsim/imgproxy`)**

Run: `MIX_ENV=test IMGPROXY_DIFF=1 mise exec -- mix imgproxy.gen_fixtures`
Expected: the task pulls/starts the pinned container, transforms every constellation, and writes `fixtures/exif_*.png`, a regenerated `manifest.exs`, and `REPORT.md`. Watch for any imgproxy URL rejection (would print an error for that constellation) — if one occurs, fix the opt in `constellations.ex` (per Task 2 Step 6 fallbacks), recommit Task 2, and re-run this step.

- [ ] **Step 3: Restore the plain test build**

Run: `MIX_ENV=test mise exec -- mix compile --force`
Expected: clean compile without the generator module, so a plain `mix test` won't see the stale gated task.

- [ ] **Step 4: Review the REPORT diff (not the PNGs)**

Run: `git status --short && git diff -- test/support/image_pipe/test/imgproxy_differential/REPORT.md | head -120`
Expected: new `exif_*.png` fixtures, modified `manifest.exs` (sources map now lists `exif_2.jpg`…`exif_8.jpg`; new entries for the 22 cases), and `REPORT.md` rows for the new constellations. Confirm the 22 new ids and the renamed source filenames appear; confirm `rotate_exif`/`strip_exif` still present.

- [ ] **Step 5: Commit the baked artifacts**

```bash
git add test/support/image_pipe/test/imgproxy_differential/fixtures \
        test/support/image_pipe/test/imgproxy_differential/manifest.exs \
        test/support/image_pipe/test/imgproxy_differential/REPORT.md
git commit -m "test(imgproxy-differential): bake exif orientation fixtures (#204)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 4: Run the conformance test and triage

**Files:**
- Modify (only as triage dictates): `test/support/image_pipe/test/imgproxy_differential/constellations.ex`

- [ ] **Step 1: Run the conformance suite**

Run: `MIX_ENV=test mise exec -- mix test test/image_pipe/imgproxy_differential_conformance_test.exs`
Expected: ideally all green. Record any failing `exif_*` cases (name + reported outliers/Δ).

- [ ] **Step 2: For each failure, inspect with the visual report**

Run: `mise exec -- mix imgproxy.gen_report --out /tmp/exif_report.html`
Open `/tmp/exif_report.html`; the over-budget cases sort to the top. For each, read the banded heatmap (where the Δ sits) and the raw heatmap (structure).

- [ ] **Step 3: Classify and act per the decision tree**

For each failing case, decide:

- **libvips-version AA/resampling skew** (Δ confined to a few columns at sharp edges, edges *not* shifted, max Δ small): widen `tol` on that constellation with an evidence comment in the existing house style — band-byte count, seam x-locations, max Δ, and the structural-flip argument (a real placement shift blows the budget). Example shape, mirroring `min_dims_dpr_marker`:

```elixir
      # #204: exif_5 transpose cover. The N band-bytes over Δ2 sit in C columns at
      # the rotated marker edge (max ΔM), edge at the same coord in both — a 1px
      # storage↔display shift would diverge every edge near full contrast. libvips
      # AA skew; budget just above the seam at the strict Δ2.
      %{
        c("exif_5_cover", :exif_5, "rs:fill:200:150")
        | tol: %{threshold: 2, budget: 256}
      },
```

- **Real ImagePipe compose bug** (whole-frame divergence, content shifted/mirrored relative to imgproxy, Δ across many edges): **quarantine** — do not fix here. Open a follow-up issue and add a `triage:` key:

```elixir
      %{
        c("exif_7_cover", :exif_7, "rs:fill:200:150")
        | triage: %{reason: "<one-line: which compose path diverges>", issue: "#<new>"}
      },
```

Open the issue with `gh issue create` referencing #204, `gravity.go RotateAndFlip` / `orientation.ex` / `orientation_flush.ex`, and the observed vs expected placement.

- [ ] **Step 4: Reauthor if any authored field changed**

A `tol` change is an authored field; a `triage` change is not. If any `tol` was edited:

Run: `mise exec -- mix imgproxy.reauthor`
Expected: `manifest.exs` authored hashes refreshed (no fixture/pixel change).

- [ ] **Step 5: Re-run green**

Run: `MIX_ENV=test mise exec -- mix test test/image_pipe/imgproxy_differential_conformance_test.exs`
Expected: 0 failures on the default lane (quarantined cases show as excluded). Then run the quarantined lane to confirm they still *fail* as documented:
`MIX_ENV=test mise exec -- mix test test/image_pipe/imgproxy_differential_conformance_test.exs --include imgproxy_triage`

- [ ] **Step 6: Commit any triage adjustments**

```bash
git add test/support/image_pipe/test/imgproxy_differential/constellations.ex \
        test/support/image_pipe/test/imgproxy_differential/manifest.exs
git commit -m "test(imgproxy-differential): triage exif orientation cases (#204)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
(Skip this commit if every case was `:equal` as authored.)

---

## Task 5: Update the conformance docs

**Files:**
- Modify: `docs/imgproxy_support_matrix.md`
- Modify (only if Task 4 added quarantines/skew notes): `test/support/image_pipe/test/imgproxy_differential/README.md`

- [ ] **Step 1: Update the support matrix stage-7 note**

In `docs/imgproxy_support_matrix.md`, find the stage-7 `rotateAndFlip` row/section (the orientation/storage↔display compensation note, referencing #185/#146; it is around line 85). Extend it to state that the differential suite now exercises **all eight** EXIF orientations, including the flip∘quarter-turn (transpose 5 / transverse 7) compose path, not just the orientation-6 quarter-turn. If Task 4 quarantined a case, note the divergence and link the new issue. Keep the edit to the **stage/order** section (no new option-table row — EXIF orientation has no URL option). The claim must match imgproxy's actual `prepare.go angleFlip` / `gravity.go RotateAndFlip` in the local checkout (`/Users/hlindset/src/imgproxy`) — verify before writing, per the spec's compatibility-reviewer requirement.

- [ ] **Step 2: Update the README if the bake produced findings**

If Task 4 added any quarantine, add a row to the README's quarantine/findings section (constellation, opts, finding, issue link), matching the existing table style — and in the same edit fix the now-doubly-stale sentence "There are currently **no quarantined constellations**" (README line ~82; it is already stale because #199/#200 are quarantined) to reflect the actual quarantined set. If every case was `:equal`, leave the README unchanged (it does not enumerate sources).

- [ ] **Step 3: Commit the docs**

```bash
git add docs/imgproxy_support_matrix.md test/support/image_pipe/test/imgproxy_differential/README.md
git commit -m "docs(imgproxy-differential): EXIF orientation coverage 2/3/4/5/7/8 (#204)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Task 6: Full gate

- [ ] **Step 1: Run the Elixir gate**

Run: `mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, and full `mix test` all green (quarantined `imgproxy_triage` cases excluded by default).

- [ ] **Step 2: If format complains, format and re-commit**

Run: `mise exec -- mix format` then re-stage and amend/commit the touched files. Re-run `mise run precommit` until green.

- [ ] **Step 3: Final review of the branch**

Run: `git log --oneline origin/main..HEAD && git diff --stat origin/main..HEAD`
Expected: the spec, plan, sources, constellations, fixtures, manifest, REPORT, and docs commits — no stray `lib/` changes (test-data scoped).

- [ ] **Step 4: Rename the branch before pushing**

Per CLAUDE.md, give the branch a descriptive name (off the random `claude/...` name) before the first push. Rename only the branch — leave the worktree directory as-is (moving it breaks harness cleanup):

Run: `git branch -m test/imgproxy-exif-orientation-fixtures`
Then push with `-u` when ready. Do not push until the user asks.
