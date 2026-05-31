# imgproxy Option Grammar Simplification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the 7 single-required-arg imgproxy pipeline options (`blur`, `sharpen`, `pixelate`, `dpr`, `brightness`, `contrast`, `saturation`) from hand-written `parse_*` clauses to a declarative `@special_specs` table + generic `interpret_special/3`, with zero change to observable behavior.

**Architecture:** This is a behavior-preserving refactor. The production change already exists as an uncommitted working-tree edit (the "spike"). To do it rigorously we (1) move the spike aside into a git stash so the working tree returns to the pre-refactor baseline, (2) add characterization tests that lock the exact behavior the refactor must preserve and prove they pass against the *old* code, then (3) restore the spike and prove the same tests plus the full suite stay green. The conversion routes `@special_specs` aliases through a new `interpret_special/3` that does arity/empty checks (uniform `:invalid_option_segment` on failure) and dispatches each arg through `apply_type/2` to the *existing, unchanged* value parsers (so each type's canonical error tag is preserved).

**Tech Stack:** Elixir, ExUnit, StreamData (ExUnitProperties), Plug. All commands run via `mise exec -- ...`. Spec: [docs/superpowers/specs/2026-05-31-imgproxy-option-grammar-simplification-design.md](../specs/2026-05-31-imgproxy-option-grammar-simplification-design.md).

**Key fact about test phases:** These are *characterization* (regression-locking) tests for a refactor, not red→green TDD for new behavior. Each new test is expected to **pass on the pre-refactor baseline** (Task 2–4) — that is the proof it correctly captures current behavior — and must **still pass after the refactor** (Task 5). There is intentionally no red phase.

**Why git stash (not a patch file):** the spike is the source of truth and lives in the working tree now. `git stash` stores it in git's object store exactly — no hand-transcribed diff to drift, no `/tmp` fragility. The stash persists across tasks/subagents (same repo, same machine). Tasks 2–4 touch only test files, so the stashed `option_grammar.ex` change never conflicts.

---

## Files

- Modify (production): `lib/image_pipe/parser/imgproxy/option_grammar.ex` — the refactor (currently an uncommitted working-tree edit; stashed in Task 1, restored in Task 5). See Appendix for exactly what the change adds/removes.
- Modify (test): `test/parser/imgproxy/option_grammar_test.exs` — add a `dpr` value-semantics test and an alias-equivalence property.
- Modify (test): `test/parser/imgproxy_test.exs` — tighten 3 loose adjustment out-of-range assertions to the exact error tag.

---

### Task 1: Stash the spike to reach the pre-refactor baseline

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/option_grammar.ex` (stash working-tree edit)

- [ ] **Step 1: Confirm the uncommitted refactor is present and is the only uncommitted change**

Run:
```bash
cd /Users/hlindset/src/image_plug/.claude/worktrees/tender-diffie-3e2dbf
git status --porcelain
```
Expected: exactly one line — ` M lib/image_pipe/parser/imgproxy/option_grammar.ex`. If there are other modified files, STOP and reconcile (this plan assumes the spike is the sole working-tree change). If that line is absent, the spike was already committed or lost — STOP and reconcile against the Appendix before continuing.

- [ ] **Step 2: Stash the spike**

Run:
```bash
cd /Users/hlindset/src/image_plug/.claude/worktrees/tender-diffie-3e2dbf
git stash push -m "spike: option grammar @special_specs conversion" -- lib/image_pipe/parser/imgproxy/option_grammar.ex
git stash list
```
Expected: `git status --porcelain` would now be empty; `git stash list` shows `stash@{0}: On <branch>: spike: option grammar @special_specs conversion`.

- [ ] **Step 3: Verify the baseline compiles and the parser suite is green**

Run:
```bash
mise exec -- mix test test/parser/imgproxy/option_grammar_test.exs test/parser/imgproxy_test.exs
```
Expected: PASS, `0 failures`. (This is the original bespoke code — the behavior the refactor must preserve.)

---

### Task 2: Lock `dpr` value semantics (characterization test)

**Why:** `dpr`'s type is `:positive_float`. No existing test pins `dpr`'s value behavior at the `OptionGrammar.parse/1` boundary (only its arity is covered by `invalid_pipeline_arity_segments/0`). A refactor that mistyped it (e.g. `:non_neg_float`) would let `dpr:0` through silently. This test pins it.

**Files:**
- Modify: `test/parser/imgproxy/option_grammar_test.exs`

- [ ] **Step 1: Add the test after the existing "basic effect options parse with imgproxy aliases" test**

Locate this existing block (around line 117–129):
```elixir
  test "basic effect options parse with imgproxy aliases" do
    assert OptionGrammar.parse("blur:2.5") == {:ok, {:pipeline, [blur: 2.5]}}
    assert OptionGrammar.parse("bl:3") == {:ok, {:pipeline, [blur: 3.0]}}
    assert OptionGrammar.parse("bl:0") == {:ok, {:pipeline, [blur: 0.0]}}

    assert OptionGrammar.parse("sharpen:0.7") == {:ok, {:pipeline, [sharpen: 0.7]}}
    assert OptionGrammar.parse("sh:1") == {:ok, {:pipeline, [sharpen: 1.0]}}
    assert OptionGrammar.parse("sh:0") == {:ok, {:pipeline, [sharpen: 0.0]}}

    assert OptionGrammar.parse("pixelate:8") == {:ok, {:pipeline, [pixelate: 8]}}
    assert OptionGrammar.parse("pix:12") == {:ok, {:pipeline, [pixelate: 12]}}
    assert OptionGrammar.parse("pix:0") == {:ok, {:pipeline, [pixelate: 0]}}
  end
```

Immediately after its closing `end`, insert:
```elixir
  test "dpr parses positive floats and rejects non-positive values" do
    assert OptionGrammar.parse("dpr:1.5") == {:ok, {:pipeline, [dpr: 1.5]}}
    assert OptionGrammar.parse("dpr:2") == {:ok, {:pipeline, [dpr: 2.0]}}
    assert OptionGrammar.parse("dpr:0") == {:error, {:invalid_positive_float, "0"}}
    assert OptionGrammar.parse("dpr:-1") == {:error, {:invalid_positive_float, "-1"}}
  end
```

- [ ] **Step 2: Run the test file against the baseline; expect PASS**

Run (`mix test` has no name filter; run the whole file — the new test is included):
```bash
mise exec -- mix test test/parser/imgproxy/option_grammar_test.exs
```
Expected: PASS, `0 failures`, and the count is one higher than the baseline run in Task 1 Step 3. (Passing on the pre-refactor code proves the test characterizes current behavior.)

---

### Task 3: Tighten the adjustment out-of-range assertions to the exact tag

**Why:** `brightness`/`contrast`/`saturation` out-of-range inputs currently assert only the loose `{:error, _reason}`. Their type is `:adjustment`, which emits `{:invalid_adjustment, value}`; the wire layer (`Imgproxy.parse`) propagates that tag unchanged (verified). Tightening locks the exact tag so a refactor can't silently change it.

**Files:**
- Modify: `test/parser/imgproxy_test.exs`

- [ ] **Step 1: Replace the loose assertions with exact-tag assertions**

Locate this existing test (around line 1289–1293):
```elixir
  test "rejects out-of-range imgproxy brightness contrast and saturation values" do
    assert {:error, _reason} = Imgproxy.parse(conn(:get, "/_/br:101/plain/images/cat.jpg"), [])
    assert {:error, _reason} = Imgproxy.parse(conn(:get, "/_/co:-101/plain/images/cat.jpg"), [])
    assert {:error, _reason} = Imgproxy.parse(conn(:get, "/_/sa:101/plain/images/cat.jpg"), [])
  end
```

Replace the whole test with:
```elixir
  test "rejects out-of-range imgproxy brightness contrast and saturation values" do
    assert Imgproxy.parse(conn(:get, "/_/br:101/plain/images/cat.jpg"), []) ==
             {:error, {:invalid_adjustment, "101"}}

    assert Imgproxy.parse(conn(:get, "/_/co:-101/plain/images/cat.jpg"), []) ==
             {:error, {:invalid_adjustment, "-101"}}

    assert Imgproxy.parse(conn(:get, "/_/sa:101/plain/images/cat.jpg"), []) ==
             {:error, {:invalid_adjustment, "101"}}
  end
```

- [ ] **Step 2: Run the test file against the baseline; expect PASS**

Run (whole file — `mix test` has no name filter):
```bash
mise exec -- mix test test/parser/imgproxy_test.exs
```
Expected: PASS, `0 failures` (the tightened "rejects out-of-range imgproxy brightness contrast and saturation values" test passes against the pre-refactor code).

---

### Task 4: Add the alias-equivalence property, then commit the locking tests

**Why:** Each converted option has a long and short alias mapping to one `@special_specs` row. This property guards against an alias accidentally diverging (e.g. a typo'd type on one alias), mirroring the existing `zoom`/`z` property. `dpr` has no short alias, so it is not included. Empty values are excluded because an empty arg yields `{:invalid_option_segment, "<segment>"}` whose segment string legitimately differs between `blur:` and `bl:` (an artifact, not a divergence); every non-empty value produces an alias-independent result (a value-tagged error or an `{:ok, ...}` assignment).

**Files:**
- Modify: `test/parser/imgproxy/option_grammar_test.exs`

- [ ] **Step 1: Add the property after the existing `zoom` alias property**

Locate this existing block at the top of the file (around line 9–18):
```elixir
  property "zoom aliases parse equivalent zoom_x and zoom_y assignments" do
    check all x_int <- integer(1..2000),
              y_int <- integer(1..2000),
              max_runs: 200 do
      x = decimal_string(x_int)
      y = decimal_string(y_int)

      assert OptionGrammar.parse("zoom:#{x}:#{y}") == OptionGrammar.parse("z:#{x}:#{y}")
    end
  end
```

Immediately after its closing `end`, insert:
```elixir
  property "fixed-arity option aliases parse equivalently to their long forms" do
    pairs = [
      {"blur", "bl"},
      {"sharpen", "sh"},
      {"pixelate", "pix"},
      {"brightness", "br"},
      {"contrast", "co"},
      {"saturation", "sa"}
    ]

    # Non-empty values only: an empty arg yields {:invalid_option_segment, segment}
    # whose segment string differs by alias (e.g. "blur:" vs "bl:") — an expected
    # artifact, not a divergence. Every non-empty value produces an alias-independent
    # result (a value-tagged error or an {:ok, ...} assignment).
    check all {long, short} <- member_of(pairs),
              value <-
                one_of([
                  map(integer(-200..200), &Integer.to_string/1),
                  string(:alphanumeric, min_length: 1)
                ]),
              max_runs: 300 do
      assert OptionGrammar.parse("#{long}:#{value}") == OptionGrammar.parse("#{short}:#{value}")
    end
  end
```

- [ ] **Step 2: Run the test file against the baseline; expect PASS**

Run (whole file — `mix test` has no name filter):
```bash
mise exec -- mix test test/parser/imgproxy/option_grammar_test.exs
```
Expected: PASS, `0 failures`; the property-count line now reads `2 properties` (the existing `zoom`/`z` property plus the new one).

- [ ] **Step 3: Run both touched test files in full to confirm nothing regressed**

Run:
```bash
mise exec -- mix test test/parser/imgproxy/option_grammar_test.exs test/parser/imgproxy_test.exs
```
Expected: PASS, `0 failures`.

- [ ] **Step 4: Commit the locking tests (on the pre-refactor baseline)**

Run:
```bash
cd /Users/hlindset/src/image_plug/.claude/worktrees/tender-diffie-3e2dbf
git add test/parser/imgproxy/option_grammar_test.exs test/parser/imgproxy_test.exs
git commit -m "test: lock imgproxy fixed-arity option behavior before grammar refactor

Characterization pins added at the parse/1 boundary that the upcoming
@special_specs conversion must preserve:
- dpr value semantics (positive_float: dpr:1.5 ok, dpr:0/-1 rejected)
- exact :invalid_adjustment tag for out-of-range br/co/sa
- alias-equivalence property over the 6 long/short pairs

Green against the pre-refactor bespoke parsers.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
Expected: commit succeeds.

---

### Task 5: Restore the refactor and prove behavior is preserved

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/option_grammar.ex` (restore stashed spike)

- [ ] **Step 1: Restore the stashed refactor**

Run:
```bash
cd /Users/hlindset/src/image_plug/.claude/worktrees/tender-diffie-3e2dbf
git stash list
git stash pop
```
Expected: `git stash list` shows the `spike: option grammar @special_specs conversion` entry at `stash@{0}`; `git stash pop` applies it cleanly (no conflict — it only touches `option_grammar.ex`, which Tasks 2–4 did not) and reports the dropped stash. If `git stash list` shows multiple entries, pop the specific one: `git stash pop stash@{N}` for the matching message.

- [ ] **Step 2: Confirm the restored change matches the intended refactor**

Run:
```bash
git -C /Users/hlindset/src/image_plug/.claude/worktrees/tender-diffie-3e2dbf diff --stat -- lib/image_pipe/parser/imgproxy/option_grammar.ex
```
Expected: `lib/image_pipe/parser/imgproxy/option_grammar.ex | 134 ++++---...  70 insertions(+), 64 deletions(-)`. The diff introduces `@special_specs`, `parse_pipeline_option/3`, `interpret_special/3`, `interpret_special_args/2`, `apply_type/2`, and removes `parse_effect_float/3`, `parse_pixelate/2`, `parse_adjustment/3`, `parse_dpr/2` and their dispatch clauses (Appendix).

- [ ] **Step 3: Compile with warnings-as-errors**

Run:
```bash
mise exec -- mix compile --warnings-as-errors
```
Expected: compiles, no warnings.

- [ ] **Step 4: Run the locking tests + the full imgproxy parser and wire suites**

Run:
```bash
mise exec -- mix test test/parser/imgproxy/option_grammar_test.exs test/parser/imgproxy_test.exs test/parser/imgproxy_property_test.exs test/image_pipe/imgproxy_wire_conformance_test.exs
```
Expected: PASS, `0 failures` (the same locking tests from Tasks 2–4 now pass against the refactored code — behavior preserved).

- [ ] **Step 5: Commit the refactor**

Run:
```bash
cd /Users/hlindset/src/image_plug/.claude/worktrees/tender-diffie-3e2dbf
git add lib/image_pipe/parser/imgproxy/option_grammar.ex
git commit -m "refactor: convert 7 fixed-arity imgproxy options to @special_specs

blur, sharpen, pixelate, dpr, brightness, contrast, saturation now parse
via a declarative @special_specs table + interpret_special/3, dispatching
through apply_type/2 to the existing value parsers. Arity/empty failures
yield :invalid_option_segment; value failures propagate each type's
canonical tag. Behavior unchanged (locked by the prior test commit; full
parser/property/wire suites green). Irregular options (scp, car,
background_alpha, gravity, padding, etc.) remain bespoke.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
Expected: commit succeeds.

---

### Task 6: Full gate and final check

- [ ] **Step 1: Run the full Elixir gate**

Run:
```bash
mise exec -- mix format --check-formatted && \
mise exec -- mix compile --warnings-as-errors && \
mise exec -- mix credo --strict && \
mise exec -- mix test
```
Expected: all four pass. `mix test` reports `0 failures`. (Equivalent to `mise run precommit`.)

- [ ] **Step 2: Confirm the branch is clean with the two new commits**

Run:
```bash
cd /Users/hlindset/src/image_plug/.claude/worktrees/tender-diffie-3e2dbf
git status
git log --oneline -3
```
Expected: working tree clean; `git stash list` empty; top two commits are `refactor: convert 7 fixed-arity imgproxy options to @special_specs` and `test: lock imgproxy fixed-arity option behavior before grammar refactor`, on top of the committed design/plan docs.

---

## Appendix: what the refactor changes (prose; the exact change lives in the git stash)

The authoritative change is the stashed working-tree edit restored in Task 5 — do not re-transcribe it by hand. For review/orientation, the refactor to `lib/image_pipe/parser/imgproxy/option_grammar.ex` does exactly this (net `70 insertions(+), 64 deletions(-)`):

**Adds:**
- `@special_specs` module attribute — a map from each option alias to `[{assignment_key, value_type}]`:
  - `blur`/`bl` → `[{:blur, :non_neg_float}]`
  - `sharpen`/`sh` → `[{:sharpen, :non_neg_float}]`
  - `pixelate`/`pix` → `[{:pixelate, :non_neg_int}]`
  - `dpr` → `[{:dpr, :positive_float}]`
  - `brightness`/`br` → `[{:brightness, :adjustment}]`
  - `contrast`/`co` → `[{:contrast, :adjustment}]`
  - `saturation`/`sa` → `[{:saturation, :adjustment}]`
- `parse_pipeline_option/3` — replaces the inline `:error ->` branch in the `@option_specs` lookup; does `@special_specs` lookup → `interpret_special/3`, else falls through to `parse_special_option/3`, then wraps the result as `{:ok, {:pipeline, assignments}}`.
- `interpret_special/3` — `cond`: `length(args) != length(arg_specs)` → `{:error, {:invalid_option_segment, segment}}`; any empty arg → same; else `interpret_special_args/2`.
- `interpret_special_args/2` — zips specs with args, `reduce_while` running each through `apply_type/2`, accumulating `{key, parsed}` and halting on the first error (propagating the value parser's tag), reversing on success.
- `apply_type/2` — 4 clauses mapping `:non_neg_float`/`:positive_float`/`:non_neg_int`/`:adjustment` to the existing `parse_non_negative_float/1`/`parse_positive_float/1`/`parse_non_negative_integer/1`/`parse_adjustment_value/1`. No catch-all (an unknown type raises, by design).

**Removes** (now handled by the table + interpreter):
- The `parse_special_option/3` dispatch clauses for `"dpr"`, `["blur","bl"]`, `["sharpen","sh"]`, `["pixelate","pix"]`, `["brightness","br"]`, `["contrast","co"]`, `["saturation","sa"]`.
- The helper functions `parse_effect_float/3`, `parse_pixelate/2`, `parse_adjustment/3`, `parse_dpr/2`.

**Keeps unchanged:** every value parser (`parse_non_negative_float/1`, `parse_positive_float/1`, `parse_non_negative_integer/1`, `parse_adjustment_value/1`, `parse_boolean/1`, …) and all other `parse_special_option/3` clauses (`zoom`, `extend`, `crop`, `gravity`, `padding`, `background`, `background_alpha`, `monochrome`, `duotone`, `strip_color_profile`, `crop_aspect_ratio`, etc.).
