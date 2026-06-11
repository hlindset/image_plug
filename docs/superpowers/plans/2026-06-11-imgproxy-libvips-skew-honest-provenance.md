# imgproxy libvips Honest Provenance (no skew boolean) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the structurally-false libvips "skew" comparison in the imgproxy differential harness and replace it with an always-on, clearly scheme-labeled provenance note.

**Architecture:** The harness compared a libvips *release* string (`Vix.Vips.version()`, e.g. `"8.18.2"`) against an ABI *soname* (`manifest.imgproxy_libvips`, e.g. `"42.20.2"`) — different schemes, so always unequal. Neither side can robustly expose the other's scheme, so we stop pretending to a comparison: delete the `Skew` module and the `skew?` flag, inline `Vix.Vips.version()` at its two call sites, and always emit both versions tagged with their scheme (stderr in the conformance suite, the provenance line in the HTML report, an info log + `REPORT.md` at generation time).

**Tech Stack:** Elixir, ExUnit, Vix (libvips bindings). Test-support only — no conformance pixel behavior change.

**Reference spec:** `docs/superpowers/specs/2026-06-11-imgproxy-libvips-skew-honest-provenance-design.md`

**Task ordering rationale:** `report_html` must stop *reading* `prov.skew?` before `gen_report` stops *emitting* it, and the `Skew` module is deleted last, once its two callers (conformance test, `gen_report`) no longer reference it. Each task leaves a compiling, green tree.

**Run all commands with `mise exec --` per project guidelines.**

---

### Task 1: report_html — drop the skew banner, label the provenance line

**Files:**
- Modify: `test/support/image_pipe/test/imgproxy_differential/report_html.ex` (`header/2` ~46-62; CSS ~335)
- Test: `test/image_pipe/imgproxy_gen_report_test.exs` (`sample_doc` ~74-80; new test in the `ReportHtml.render/1` describe block ~172)

- [ ] **Step 1: Add the failing provenance-label test**

In `test/image_pipe/imgproxy_gen_report_test.exs`, inside the `describe "ReportHtml.render/1"` block (after the existing `"emits a self-contained document..."` test), add:

```elixir
    test "provenance line labels each version with its scheme and notes incomparability" do
      html = ReportHtml.render(sample_doc())
      assert html =~ "(.so ABI soname)"
      assert html =~ "(release, at gen)"
      # stable fragment only — don't pin the full prose sentence (reword without behavior change)
      assert html =~ "not directly comparable"
      refute html =~ ~s(class="banner skew")
    end
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `mise exec -- mix test test/image_pipe/imgproxy_gen_report_test.exs:175` (adjust to the new test's line number)
Expected: FAIL — `"schemes differ, not directly comparable"` is not yet in the output. (ExUnit has no name-substring filter; run the file and read the new test's failure, or use `path:LINE`.)

- [ ] **Step 3: Remove the banner and label the provenance line**

In `test/support/image_pipe/test/imgproxy_differential/report_html.ex`, replace the `header/2` opening (the `skew = if prov.skew? do ... end` block plus the `#{skew}` line) so the function goes straight into the heredoc and the provenance `<p>` gains a trailing clause.

Replace:

```elixir
  defp header(prov, cards) do
    skew =
      if prov.skew? do
        ~s(<div class="banner skew">libvips skew: fixtures baked on #{esc(prov.imgproxy_libvips)}, running #{esc(prov.runtime_libvips)} — compare with care.</div>)
      else
        ""
      end

    """
    <header class="report-header">
      <div class="title-row">
        <h1>imgproxy differential — visual diff</h1>
        <button id="theme-toggle">theme: auto</button>
      </div>
      <p class="provenance">imgproxy <code>#{esc(prov.imgproxy_digest)}</code> · imgproxy libvips <code>#{esc(prov.imgproxy_libvips)}</code> (.so ABI soname) · ImagePipe libvips <code>#{esc(prov.pipe_libvips_at_gen)}</code> (release, at gen) · runtime <code>#{esc(prov.runtime_libvips)}</code> (release)</p>
      #{skew}
      <p class="counts">#{counts(cards)}</p>
```

with:

```elixir
  defp header(prov, cards) do
    """
    <header class="report-header">
      <div class="title-row">
        <h1>imgproxy differential — visual diff</h1>
        <button id="theme-toggle">theme: auto</button>
      </div>
      <p class="provenance">imgproxy <code>#{esc(prov.imgproxy_digest)}</code> · imgproxy libvips <code>#{esc(prov.imgproxy_libvips)}</code> (.so ABI soname) · ImagePipe libvips <code>#{esc(prov.pipe_libvips_at_gen)}</code> (release, at gen) · runtime <code>#{esc(prov.runtime_libvips)}</code> (release) — schemes differ, not directly comparable</p>
      <p class="counts">#{counts(cards)}</p>
```

Then delete the now-unused CSS rule (the `.banner` base rule and `.banner.drift` stay — `drift_banner/1` still uses them):

```elixir
    .banner.skew { background:color-mix(in srgb, var(--accent) 18%, transparent); }
```

- [ ] **Step 4: Drop `skew?` from the test fixture**

In `test/image_pipe/imgproxy_gen_report_test.exs`, in `sample_doc/0`'s `provenance:` map, remove the `skew?: false` entry (and the comma on the line above it). The map ends:

```elixir
        pipe_libvips_at_gen: "8.18.2",
        runtime_libvips: "8.18.2"
      },
```

- [ ] **Step 5: Run the test, verify it passes**

Run: `mise exec -- mix test test/image_pipe/imgproxy_gen_report_test.exs`
Expected: PASS (all render tests, including the new provenance-label test).

- [ ] **Step 6: Commit**

```bash
git add test/support/image_pipe/test/imgproxy_differential/report_html.ex test/image_pipe/imgproxy_gen_report_test.exs
git commit -m "test(imgproxy): label report provenance by scheme, drop skew banner (#207)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: gen_report — drop the skew? field, inline Vix.Vips.version()

**Files:**
- Modify: `test/support/mix/tasks/imgproxy.gen_report.ex` (alias block ~22-30; `provenance/1` ~59-69)

- [ ] **Step 1: Remove `Skew` from the alias block**

Replace:

```elixir
  alias ImagePipe.Test.ImgproxyDifferential.{
    Constellations,
    Manifest,
    OptsSummary,
    PixelCompare,
    ReportHtml,
    Skew
  }
```

with:

```elixir
  alias ImagePipe.Test.ImgproxyDifferential.{
    Constellations,
    Manifest,
    OptsSummary,
    PixelCompare,
    ReportHtml
  }
```

- [ ] **Step 2: Simplify `provenance/1`**

Replace:

```elixir
  defp provenance(manifest) do
    runtime = Skew.runtime_libvips()

    %{
      imgproxy_digest: manifest.imgproxy_digest,
      imgproxy_libvips: manifest.imgproxy_libvips,
      pipe_libvips_at_gen: manifest.pipe_libvips_at_gen,
      runtime_libvips: runtime,
      skew?: not Skew.aligned?(manifest)
    }
  end
```

with:

```elixir
  defp provenance(manifest) do
    %{
      imgproxy_digest: manifest.imgproxy_digest,
      imgproxy_libvips: manifest.imgproxy_libvips,
      pipe_libvips_at_gen: manifest.pipe_libvips_at_gen,
      runtime_libvips: Vix.Vips.version()
    }
  end
```

- [ ] **Step 3: Run the gen_report tests, verify green**

Run: `mise exec -- mix test test/image_pipe/imgproxy_gen_report_test.exs`
Expected: PASS — including the `"gen_report renders every constellation to a self-contained file"` integration test, which calls `provenance/1` for real and no longer hits a missing `skew?` key in `report_html`.

- [ ] **Step 4: Commit**

```bash
git add test/support/mix/tasks/imgproxy.gen_report.ex
git commit -m "refactor(imgproxy): drop skew? from gen_report provenance (#207)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: conformance test — always-on scheme-labeled provenance note

**Files:**
- Modify: `test/image_pipe/imgproxy_differential_conformance_test.exs` (alias ~6; `setup_all` ~43-53)

- [ ] **Step 1: Remove `Skew` from the alias**

Replace:

```elixir
  alias ImagePipe.Test.ImgproxyDifferential.{Constellations, Manifest, PixelCompare, Skew}
```

with:

```elixir
  alias ImagePipe.Test.ImgproxyDifferential.{Constellations, Manifest, PixelCompare}
```

- [ ] **Step 2: Replace the warn-and-attempt block with an unconditional note**

Replace:

```elixir
    # Warn-and-attempt: ImagePipe tracks bleeding-edge libvips while imgproxy lags,
    # so the versions rarely match. Empirically the ✅ stages still agree to
    # tolerance across minor libvips gaps, so we compare anyway and warn once — a
    # failure may reflect a libvips version difference rather than a regression.
    if not Skew.aligned?(manifest) do
      IO.puts(
        :stderr,
        "[imgproxy-differential] libvips skew: fixtures baked on #{manifest.imgproxy_libvips}, " <>
          "running #{Skew.runtime_libvips()}. Comparing anyway."
      )
    end
```

with:

```elixir
    # Provenance note: the fixtures were baked by imgproxy's libvips; ImagePipe runs its
    # own. The two report different version *schemes* — imgproxy exposes only the
    # `.so` ABI soname (no release string, no `vips` CLI in the darthsim image), Vix only
    # the release — so they can't be compared directly. A pixel diff may reflect libvips
    # drift rather than a regression; we record both and always compare.
    IO.puts(
      :stderr,
      "[imgproxy-differential] fixtures baked by imgproxy libvips " <>
        "#{manifest.imgproxy_libvips} (.so ABI soname); ImagePipe running " <>
        "#{Vix.Vips.version()} (release). Different version schemes — not directly " <>
        "comparable; pixel diffs may reflect libvips drift."
    )
```

- [ ] **Step 3: Run the conformance suite, verify green**

Run: `mise exec -- mix test test/image_pipe/imgproxy_differential_conformance_test.exs`
Expected: PASS. The new provenance line prints once to stderr; no assertion depends on the old wording.

- [ ] **Step 4: Commit**

```bash
git add test/image_pipe/imgproxy_differential_conformance_test.exs
git commit -m "test(imgproxy): always emit scheme-labeled libvips provenance note (#207)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Delete the Skew module and its test

**Files:**
- Delete: `test/support/image_pipe/test/imgproxy_differential/skew.ex`
- Delete: `test/image_pipe/imgproxy_differential/skew_test.exs`

- [ ] **Step 1: Confirm there are no remaining references**

Run: `grep -rn "Skew" test/ lib/`
Expected: only the two files about to be deleted (`skew.ex`, `skew_test.exs`). If anything else matches, stop — a prior task missed a reference.

- [ ] **Step 2: Delete both files**

```bash
git rm test/support/image_pipe/test/imgproxy_differential/skew.ex test/image_pipe/imgproxy_differential/skew_test.exs
```

(`aligned?/1` was the false comparison; `runtime_libvips/0` is now inlined as `Vix.Vips.version()`; `ci?/1` had no caller outside its own deleted test.)

- [ ] **Step 3: Compile with warnings-as-errors and run the affected suites**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean compile (no undefined-`Skew` references).

Run: `mise exec -- mix test test/image_pipe/imgproxy_differential_conformance_test.exs test/image_pipe/imgproxy_gen_report_test.exs`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor(imgproxy): delete dead Skew module after dropping skew boolean (#207)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: gen_fixtures — honest generation-time provenance log

**Files:**
- Modify: `test/support/mix/tasks/imgproxy.gen_fixtures.ex` (version log ~56-61; `container_libvips/1` comment ~132-134; `write_report!/1` ~157-159)

- [ ] **Step 1: Replace the always-true `!=` warning with an unconditional info log**

Replace:

```elixir
      if imgproxy_libvips != pipe_libvips do
        Mix.shell().info(
          "WARNING: imgproxy libvips #{imgproxy_libvips} != ImagePipe libvips #{pipe_libvips}; " <>
            "generation-time validation is not truly same-kernel."
        )
      end
```

with:

```elixir
      Mix.shell().info(
        "imgproxy libvips #{imgproxy_libvips} (.so ABI soname); " <>
          "ImagePipe libvips #{pipe_libvips} (release) — different schemes, recorded for provenance."
      )
```

- [ ] **Step 2: Drop "skew" from the `container_libvips/1` comment**

In the same file, replace:

```elixir
    # imgproxy exposes no libvips version over HTTP, and the darthsim image has no
    # `vips` CLI — read the bundled .so realname (e.g. "libvips.so.42.20.2") and
    # record its ABI version ("42.20.2") as the skew identifier.
```

with:

```elixir
    # imgproxy exposes no libvips version over HTTP, and the darthsim image has no
    # `vips` CLI — read the bundled .so realname (e.g. "libvips.so.42.20.2") and
    # record its ABI soname ("42.20.2") as the provenance identifier.
```

- [ ] **Step 3: Label the schemes in the generated REPORT.md**

In `write_report!/1`, replace:

```elixir
      - imgproxy digest: `#{manifest.imgproxy_digest}`
      - imgproxy libvips: `#{manifest.imgproxy_libvips}`
      - ImagePipe libvips at generation: `#{manifest.pipe_libvips_at_gen}`
```

with:

```elixir
      - imgproxy digest: `#{manifest.imgproxy_digest}`
      - imgproxy libvips (.so ABI soname): `#{manifest.imgproxy_libvips}`
      - ImagePipe libvips at generation (release): `#{manifest.pipe_libvips_at_gen}`
```

- [ ] **Step 4: Compile (the task is Docker-gated at run time but must still compile)**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean compile. (`gen_fixtures` is wrapped in `if Code.ensure_loaded?(Testcontainers)`; this change is text-only inside it. It is not run here — it needs Docker + `IMGPROXY_DIFF=1`.)

- [ ] **Step 5: Commit**

```bash
git add test/support/mix/tasks/imgproxy.gen_fixtures.ex
git commit -m "test(imgproxy): honest scheme-labeled libvips log at fixture generation (#207)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Doc sync — README provenance section + support matrix

The harness README and the imgproxy support matrix still describe the deleted
warn-and-attempt "skew model." Per the project's conformance-doc-sync rule (a
**stage/order**-axis change to a compatibility target's doc), update them in this change.

**Files:**
- Modify: `test/support/image_pipe/test/imgproxy_differential/README.md` (~49-61)
- Modify: `docs/imgproxy_support_matrix.md` (~140-141; ~157)

- [ ] **Step 1: Rewrite the README "libvips skew" section**

Replace the whole section (heading + the two paragraphs + the bootstrap line):

```markdown
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
```

with:

```markdown
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
```

- [ ] **Step 2: Drop the "skew-gated" claim in the support matrix `:equal` row**

In `docs/imgproxy_support_matrix.md`, replace:

```markdown
- **`:equal`** (transform group, ✅ stages): tight count-based pixel agreement on PNG
  output, skew-gated to the fixtures' libvips. Stages exercised: trim (sRGB),
```

with:

```markdown
- **`:equal`** (transform group, ✅ stages): tight count-based pixel agreement on PNG
  output against the fixtures' libvips (tolerances absorb minor libvips-version
  resampling differences). Stages exercised: trim (sRGB),
```

- [ ] **Step 3: Update the matrix's closing doc pointer**

In the same file, replace:

```markdown
Regeneration and the libvips skew model are documented in
```

with:

```markdown
Regeneration and the libvips provenance model are documented in
```

- [ ] **Step 4: Commit**

```bash
git add test/support/image_pipe/test/imgproxy_differential/README.md docs/imgproxy_support_matrix.md
git commit -m "docs(imgproxy): sync harness README + support matrix to provenance model (#207)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Final verification

**Files:** none (verification only)

- [ ] **Step 1: Confirm the only remaining matrix "skew" is the descriptive one**

Run: `grep -n "skew\|aligned?" docs/imgproxy_support_matrix.md`
Expected: a single match — the descriptive "libvips-version resampling skew" in the
`min_dims_clamp` row (a term for resampling *error*, not the removed detection model).
No "skew-gated", "skew model", or "aligned?".

- [ ] **Step 2: Run the Elixir gate**

Run: `mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, and `mix test` all pass.

- [ ] **Step 3: Confirm the Skew module and skew? key are fully gone**

Run: `grep -rn "Skew\|skew?" test/ lib/`
Expected: no matches. (Lowercase prose uses of "skew" as a resampling-error descriptor may
remain in docs and are fine — this grep targets the `Skew` module and the `skew?` key.)
