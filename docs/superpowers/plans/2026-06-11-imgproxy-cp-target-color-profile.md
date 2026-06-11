# imgproxy `cp`/`icc` Built-in Target Color-Profile — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add imgproxy `color_profile`/`cp`/`icc` support that converts the processed image into one of three built-in RGB target ICC profiles (`srgb`, `display_p3`, `adobe_rgb`) and embeds that profile in the output.

**Architecture:** Fills the already-open `{:convert, target}` arm of `ImagePipe.Plan.Output.color_profile` (left open by #124). A new module under `ImagePipe.Output.*` resolves a target atom to a shipped CC0 `.icc` in `priv/icc/`. A new top-level `color_result/2` clause in the encoder converts the working-space image (sRGB, post-#124 import) to the target via `Vix.Vips.Operation.icc_transform` and embeds it, bypassing the `restore_backup`/`maybe_drop_profile` chain so the embed survives metadata strip. The imgproxy parser maps `cp`/`icc` to the target atom (mirroring `strip_color_profile`'s cross-pipeline resolution) and makes `cp` override the `scp` slot at plan-build time. Cache key / ETag / Resolved all carry the atom unchanged — no work there.

**Tech Stack:** Elixir, `Vix.Vips` (libvips), `image` (`~> 0.67`), ExUnit + StreamData.

**Spec:** [`docs/superpowers/specs/2026-06-11-imgproxy-cp-target-color-profile-design.md`](../specs/2026-06-11-imgproxy-cp-target-color-profile-design.md)

**Conventions:** run every tool through `mise exec --` (e.g. `mise exec -- mix test ...`). Comment-only/doc-only edits skip the compile/test gate; everything else runs focused tests.

---

## File Structure

**Create:**
- `priv/icc/sRGB.icc`, `priv/icc/DisplayP3.icc`, `priv/icc/AdobeRGB.icc` — shipped CC0 substitute profiles.
- `lib/image_pipe/output/color_profile.ex` — `ImagePipe.Output.ColorProfile`: target atom → shipped `.icc` path, hardcoded filenames + compile-time presence guard.
- `priv/icc/PROVENANCE.md` — license/source/SHA of each shipped profile.
- `test/image_pipe/output/color_profile_test.exs` — resolver unit tests.

**Modify:**
- `lib/image_pipe/output/encoder.ex` — new `color_result/2` clause + `convert_to_target/3`.
- `test/image_pipe/output/color_result_test.exs` — encoder convert unit tests.
- `lib/image_pipe/parser/imgproxy/option_grammar.ex` — parse `color_profile`/`cp`/`icc`.
- `lib/image_pipe/parser/imgproxy/pipeline_request.ex` — `color_profile` field.
- `lib/image_pipe/parser/imgproxy/options.ex` — accumulate + resolve `color_profile`.
- `lib/image_pipe/parser/imgproxy/parsed_request.ex` — `color_profile` in `@default_output` + `output_request()` type.
- `lib/image_pipe/parser/imgproxy/plan_builder.ex` — `color_profile_policy/2` precedence.
- `test/parser/imgproxy_test.exs` — parser/planner tests.
- `test/image_pipe/imgproxy_wire_conformance_test.exs` — wire-level request-boundary tests.
- `docs/imgproxy_support_matrix.md` — flip the `cp`/`icc` rows, record divergences.
- `fiddle/assets/` — `cp` target control + URL state.

**Unchanged (verified — the atom rides through):** `lib/image_pipe/plan/output.ex` (type already `{:convert, term()}`), `lib/image_pipe/output/resolved.ex`, `lib/image_pipe/output/policy.ex`, `lib/image_pipe/cache/key.ex` (already includes `color_profile`), `lib/image_pipe/format.ex`.

---

## Task 1: Shipped CC0 profiles + provenance

**Files:**
- Create: `priv/icc/sRGB.icc`, `priv/icc/DisplayP3.icc`, `priv/icc/AdobeRGB.icc`, `priv/icc/PROVENANCE.md`

This task obtains the three profile blobs. They must be genuinely **CC0 / public-domain / redistributable** — colors match the vendor targets, but they are NOT the vendor-authored profiles.

- [ ] **Step 1: Obtain the three `.icc` files**

Recommended CC0 sources (verify the license at fetch time):
- `sRGB.icc` — ICC's public-domain `sRGB2014.icc` (https://www.color.org/srgbprofiles.xalter) **or** Elle Stone `sRGB-elle-V4-srgbtrc.icc` (https://github.com/ellelstone/elles_icc_profiles, CC0).
- `AdobeRGB.icc` — Elle Stone `ClayRGB-elle-V4-g22.icc` (CC0; Adobe RGB 1998 primaries, gamma 2.2).
- `DisplayP3.icc` — a CC0 Display-P3-primaries (D65) profile. If no ready CC0 file is found, **generate** one from P3-D65 primaries with lcms2 (`tificc`/littlecms profile authoring) — a self-authored profile is yours to license CC0. Record the exact generation command in `PROVENANCE.md`.

Place each under `priv/icc/` with the names above. Keep each file small (ICC matrix profiles are sub-100 KB; sanity-cap at < 1 MB).

- [ ] **Step 2: Verify each file is a loadable ICC profile**

Run (adjust paths if a generated P3 lands elsewhere):

```bash
mise exec -- elixir -e '
for f <- ~w(sRGB DisplayP3 AdobeRGB) do
  path = Path.join(["priv/icc", f <> ".icc"])
  {:ok, img} = Vix.Vips.Operation.black(8, 8, bands: 3)
  {:ok, _} = Vix.Vips.Operation.icc_transform(img, path, input_profile: "srgb")
  IO.puts("OK #{path} (#{File.stat!(path).size} bytes)")
end'
```

Expected: three `OK …` lines, each under ~100 KB. If `icc_transform` errors, the file is not a usable profile — re-source it.

- [ ] **Step 3: Write `priv/icc/PROVENANCE.md`**

```markdown
# Shipped ICC profiles (CC0 substitutes)

These are redistributable substitutes, NOT the vendor-authored profiles. Primaries/white
point match the named target; embedded `description` and TRC metadata differ. See
`docs/imgproxy_support_matrix.md` for the imgproxy divergence note.

| File          | Target atom    | Source / license                                  | SHA-256 |
|---------------|----------------|---------------------------------------------------|---------|
| sRGB.icc      | `:srgb`        | <source URL> — <license>                          | <sha>   |
| DisplayP3.icc | `:display_p3`  | <source URL or generation command> — CC0          | <sha>   |
| AdobeRGB.icc  | `:adobe_rgb`   | ClayRGB (Elle Stone) — CC0                         | <sha>   |
```

Fill `<source>`/`<license>`/`<sha>` with real values (`shasum -a 256 priv/icc/*.icc`).

- [ ] **Step 4: Commit**

```bash
git add priv/icc/sRGB.icc priv/icc/DisplayP3.icc priv/icc/AdobeRGB.icc priv/icc/PROVENANCE.md
git commit -m "feat(output): ship CC0 substitute ICC profiles for cp targets"
```

---

## Task 2: `ImagePipe.Output.ColorProfile` resolver

**Files:**
- Create: `lib/image_pipe/output/color_profile.ex`
- Test: `test/image_pipe/output/color_profile_test.exs`

Resolves a target atom to its shipped `.icc` path. Hardcoded filenames per clause (no atom→path interpolation), with a compile-time presence guard so a missing asset fails the build.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ImagePipe.Output.ColorProfileTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Output.ColorProfile

  test "path!/1 returns an existing file for each built-in target" do
    for target <- [:srgb, :display_p3, :adobe_rgb] do
      path = ColorProfile.path!(target)
      assert File.exists?(path), "expected #{path} to exist for #{target}"
      assert Path.extname(path) == ".icc"
    end
  end

  test "path!/1 raises for an unknown target (programmer error, not user input)" do
    assert_raise FunctionClauseError, fn -> ColorProfile.path!(:rec2020) end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/output/color_profile_test.exs`
Expected: FAIL — `ImagePipe.Output.ColorProfile` is undefined.

- [ ] **Step 3: Write the module**

```elixir
defmodule ImagePipe.Output.ColorProfile do
  @moduledoc false
  # Resolves a built-in cp/icc target atom to its shipped CC0 .icc profile path.
  # Filenames are hardcoded per clause (never interpolated from the atom) so there
  # is no string-building seam for user input to slot into if a future custom-dir
  # slice is added. The only producer of these atoms is the imgproxy parser, which
  # emits exactly these three; an unknown atom is a programmer error and raises.

  @dir Application.app_dir(:image_pipe, "priv/icc")

  @srgb Path.join(@dir, "sRGB.icc")
  @display_p3 Path.join(@dir, "DisplayP3.icc")
  @adobe_rgb Path.join(@dir, "AdobeRGB.icc")

  @external_resource @srgb
  @external_resource @display_p3
  @external_resource @adobe_rgb

  # Compile-time presence guard: a missing shipped profile fails the build loudly
  # rather than surfacing as a per-request error on a broken release.
  for path <- [@srgb, @display_p3, @adobe_rgb] do
    unless File.exists?(path) do
      raise "missing shipped ICC profile: #{path} (see priv/icc/PROVENANCE.md)"
    end
  end

  @spec path!(:srgb | :display_p3 | :adobe_rgb) :: String.t()
  def path!(:srgb), do: @srgb
  def path!(:display_p3), do: @display_p3
  def path!(:adobe_rgb), do: @adobe_rgb
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/output/color_profile_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/output/color_profile.ex test/image_pipe/output/color_profile_test.exs
git commit -m "feat(output): add ColorProfile target->path resolver"
```

---

## Task 3: Encoder convert-and-embed finalize

**Files:**
- Modify: `lib/image_pipe/output/encoder.ex`
- Test: `test/image_pipe/output/color_result_test.exs`

The core mechanics. A new top-level `color_result/2` clause for `{:convert, target}` that bypasses the `restore_backup`/`apply_color_result`/`maybe_drop_profile` chain (so the embed is not stripped), promotes greyscale to sRGB, converts working-space sRGB → target via `icc_transform` with an explicit `input_profile` (NOT `embedded: true`), and embeds the target. Then `strip_metadata_and_private` preserves the ICC (because `color_profile != :strip`) while still stripping EXIF/XMP/IPTC.

> Read the existing `color_result/2` / `apply_color_result/3` / `to_standard/1` at `lib/image_pipe/output/encoder.ex:72-128` and the `color_result_test.exs` helpers before starting — the convert tests reuse the same `Resolved`-building + header-reading patterns.

- [ ] **Step 1: Write the failing tests**

Add to `test/image_pipe/output/color_result_test.exs` (match the file's existing `Resolved` builder / fixture helpers — adapt the helper names below to the ones already in the file):

```elixir
describe "color_profile {:convert, target}" do
  test "converts to the target and embeds its profile" do
    # working-space sRGB image (3-band, no embedded profile — the untagged case)
    {:ok, image} = Vix.Vips.Operation.black(16, 16, bands: 3)
    resolved = build_resolved(format: :png, color_profile: {:convert, :display_p3})

    {:ok, out} = finalize_for_test(image, resolved)

    assert Vix.Vips.Image.header_value(out, "icc-profile-data") != nil
  end

  test "greyscale source converts to a 3-band RGB target (N2)" do
    {:ok, grey} = Vix.Vips.Operation.black(16, 16, bands: 1)
    {:ok, grey} = Vix.Vips.Operation.colourspace(grey, :VIPS_INTERPRETATION_B_W)
    resolved = build_resolved(format: :png, color_profile: {:convert, :display_p3})

    {:ok, out} = finalize_for_test(grey, resolved)

    assert Vix.Vips.Image.bands(out) == 3
    assert Vix.Vips.Image.header_value(out, "icc-profile-data") != nil
  end

  test "embedded target survives metadata strip (not dropped by maybe_drop_profile)" do
    {:ok, image} = Vix.Vips.Operation.black(16, 16, bands: 3)
    resolved = build_resolved(format: :jpeg, color_profile: {:convert, :adobe_rgb}, strip_metadata: true)

    {:ok, out} = finalize_for_test(image, resolved)

    assert Vix.Vips.Image.header_value(out, "icc-profile-data") != nil
  end
end
```

Notes for the implementer:
- `build_resolved/1` and `finalize_for_test/2` are stand-ins for whatever the file already uses to build a `%ImagePipe.Output.Resolved{}` and invoke the finalize path (the file already tests `:preserve_source`/`:strip`, so equivalents exist — reuse them, do not add new public encoder API).
- These build `Resolved{color_profile: {:convert, _}}` directly: that is a **real** shape (Task 4's parser produces it), consistent with how the file already builds `Resolved` for `:strip`/`:preserve_source` — not an impossible-misuse struct.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mise exec -- mix test test/image_pipe/output/color_result_test.exs`
Expected: FAIL — no `color_result` clause matches `{:convert, _}` (FunctionClauseError or a `:strip`/`:preserve_source` mismatch).

- [ ] **Step 3: Add the convert clause + helper**

In `lib/image_pipe/output/encoder.ex`, add the alias and the new clause **above** the existing `color_result/2` clause (so the pattern match takes precedence), and the helper. Add near the existing aliases (line ~8):

```elixir
alias ImagePipe.Output.ColorProfile
```

Add the new clause immediately before `defp color_result(image, %Resolved{} = resolved) do` (line 72):

```elixir
# cp/icc: convert the working-space image (sRGB after the #124 import preamble) to
# the chosen built-in target profile and embed it. A dedicated clause: it must NOT
# flow through maybe_drop_profile/2, which (keep? == false here) would strip the
# profile we just embedded. strip_metadata_and_private preserves the ICC because
# color_profile is not :strip, while still stripping EXIF/XMP/IPTC.
defp color_result(image, %Resolved{color_profile: {:convert, target}} = resolved) do
  with {:ok, image} <- convert_to_target(image, target, resolved.format) do
    {:ok, strip_metadata_and_private(image, resolved)}
  end
end
```

Add the helper near `to_standard/1` (after line 128):

```elixir
# Convert working-space sRGB -> target built-in profile and embed it. Greyscale
# (B_W/sGrey, 1-band) is first promoted to sRGB so the 3-band target transform is
# valid (N2). Input is declared as the known working space ("srgb") rather than
# embedded: true, because an untagged source has no embedded profile to read (N1).
defp convert_to_target(image, target, format) do
  if Format.supports_color_profile?(format) do
    with {:ok, srgb} <- Operation.colourspace(image, :VIPS_INTERPRETATION_sRGB),
         {:ok, converted} <-
           Operation.icc_transform(srgb, ColorProfile.path!(target),
             input_profile: "srgb",
             depth: icc_depth(srgb)
           ) do
      {:ok, converted}
    else
      {:error, reason} -> {:error, {:decode, reason}}
    end
  else
    # Unreachable for the four current output formats (all carry ICC); kept for
    # symmetry. No target can be embedded, so leave the working-space image as-is.
    {:ok, image}
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mise exec -- mix test test/image_pipe/output/color_result_test.exs`
Expected: PASS (existing `:strip`/`:preserve_source` tests + the 3 new convert tests).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/output/encoder.ex test/image_pipe/output/color_result_test.exs
git commit -m "feat(output): convert-and-embed cp target profile at finalize"
```

---

## Task 4: imgproxy parser — `cp`/`icc` → target atom, overriding `scp`

**Files:**
- Modify: `lib/image_pipe/parser/imgproxy/option_grammar.ex`, `pipeline_request.ex`, `options.ex`, `parsed_request.ex`, `plan_builder.ex`
- Test: `test/parser/imgproxy_test.exs`

Mirrors the existing `strip_color_profile` cross-pipeline machinery. `cp`/`icc`/`color_profile` parse to a target atom (or error on unknown); the effective target is resolved across pipelines onto the output; the plan builder maps a present target to `{:convert, target}`, overriding the `scp` boolean.

- [ ] **Step 1: Write the failing parser tests**

Add to `test/parser/imgproxy_test.exs` (use the file's existing parse helper — shown here as `parse/1` returning `{:ok, %Plan{}}`; adapt to the real helper name):

```elixir
describe "color_profile / cp / icc" do
  test "cp maps each built-in identifier to a convert target" do
    for {str, atom} <- [{"srgb", :srgb}, {"p3", :display_p3}, {"display-p3", :display_p3},
                        {"adobe-rgb", :adobe_rgb}, {"adobergb", :adobe_rgb}] do
      {:ok, plan} = parse("rs:fit:10:10/cp:#{str}/plain/http://e/i.jpg")
      assert plan.output.color_profile == {:convert, atom}
    end
  end

  test "icc is an alias for cp" do
    {:ok, plan} = parse("rs:fit:10:10/icc:p3/plain/http://e/i.jpg")
    assert plan.output.color_profile == {:convert, :display_p3}
  end

  test "unknown identifier is a parse error" do
    assert {:error, _} = parse("cp:rec2020/plain/http://e/i.jpg")
  end

  test "cp overrides scp regardless of the scp boolean" do
    {:ok, p1} = parse("cp:p3/scp:1/plain/http://e/i.jpg")
    {:ok, p0} = parse("cp:p3/scp:0/plain/http://e/i.jpg")
    assert p1.output.color_profile == {:convert, :display_p3}
    assert p0.output.color_profile == {:convert, :display_p3}
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs`
Expected: FAIL — `cp` is an unknown option / `color_profile` is `:strip`/`:preserve_source`, never `{:convert, _}`.

- [ ] **Step 3a: Grammar — parse the option**

In `lib/image_pipe/parser/imgproxy/option_grammar.ex`, add a dispatch clause next to the `strip_color_profile`/`scp` one (line ~488):

```elixir
defp parse_special_option(name, args, segment)
     when name in ["color_profile", "cp", "icc"] do
  parse_color_profile(args, segment)
end
```

Add the parser near `parse_strip_color_profile/2` (line ~918):

```elixir
defp parse_color_profile([value], segment) when value != "" do
  case color_profile_target(value) do
    {:ok, target} -> {:ok, [color_profile: target]}
    :error -> {:error, {:invalid_option_segment, segment}}
  end
end

defp parse_color_profile(_args, segment),
  do: {:error, {:invalid_option_segment, segment}}

# v1 built-in allowlist. `srgb` is the imgproxy-faithful built-in; `p3`/`display-p3`
# and `adobe-rgb`/`adobergb` are ImagePipe-specific extensions (Pro reaches these only
# via a custom profiles dir). No percent-decoding in v1 — identifiers are ASCII-safe.
defp color_profile_target("srgb"), do: {:ok, :srgb}
defp color_profile_target("p3"), do: {:ok, :display_p3}
defp color_profile_target("display-p3"), do: {:ok, :display_p3}
defp color_profile_target("adobe-rgb"), do: {:ok, :adobe_rgb}
defp color_profile_target("adobergb"), do: {:ok, :adobe_rgb}
defp color_profile_target(_), do: :error
```

- [ ] **Step 3b: PipelineRequest — carry the parsed target**

In `lib/image_pipe/parser/imgproxy/pipeline_request.ex`, add to the type (near `strip_color_profile:`) and the `defstruct`:

Type (in the `@type t` map):
```elixir
          color_profile: ImagePipe.Plan.Output.color_profile() | nil,
```
defstruct (near `strip_color_profile: false`):
```elixir
            color_profile: nil,
```

(No separate `_requested` flag: `nil` already means "not set", an atom means "set".)

- [ ] **Step 3c: options.ex — accumulate and resolve**

In `lib/image_pipe/parser/imgproxy/options.ex`:

Accept the assignment onto the pipeline (in the per-option `update_*`/reducer that handles `strip_color_profile`, near line 234):
```elixir
{:color_profile, value}, pipeline ->
  %{pipeline | color_profile: value}
```

In `apply_request_defaults/2` (line 299), resolve the effective target and put it on the output, alongside the existing `strip_color_profile?` work:
```elixir
color_profile = effective_color_profile(pipelines)
```
and extend the `output` pipeline:
```elixir
output =
  output
  |> resolve_metadata_defaults(defaults)
  |> Map.put(:strip_color_profile, strip_color_profile?)
  |> Map.put(:color_profile, color_profile)
```

Add the reducer (near `effective_strip_color_profile/2`, line ~360) — last set across pipelines wins, default `nil`:
```elixir
defp effective_color_profile(pipelines) do
  Enum.reduce(pipelines, nil, fn
    %PipelineRequest{color_profile: target}, _acc when not is_nil(target) -> target
    %PipelineRequest{}, acc -> acc
  end)
end
```

- [ ] **Step 3d: parsed_request.ex — output field + type**

In `lib/image_pipe/parser/imgproxy/parsed_request.ex`, add `color_profile: nil` to `@default_output` (near `strip_color_profile: nil`, line ~12) and `required(:color_profile) => ImagePipe.Plan.Output.color_profile() | nil` to the `output_request()` type (near line ~36).

- [ ] **Step 3e: plan_builder.ex — precedence**

In `lib/image_pipe/parser/imgproxy/plan_builder.ex`, change both `color_profile: color_profile_policy(request.strip_color_profile)` call sites (lines 99, 116) to pass the target too:
```elixir
       color_profile: color_profile_policy(request.color_profile, request.strip_color_profile)
```
and replace the `color_profile_policy/1` clauses (lines 124-126) with:
```elixir
# A present cp/icc target wins over scp (imgproxy: cp-embedded profiles are not
# stripped by strip_color_profile). scp only decides strip vs preserve when no
# target is set.
defp color_profile_policy(target, _strip) when not is_nil(target), do: {:convert, target}
defp color_profile_policy(nil, true), do: :strip
defp color_profile_policy(nil, false), do: :preserve_source
defp color_profile_policy(nil, nil), do: :strip
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs`
Expected: PASS (new `color_profile` describe block + existing parser tests still green).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/parser/imgproxy/ test/parser/imgproxy_test.exs
git commit -m "feat(imgproxy): parse cp/icc target, overriding scp slot"
```

---

## Task 5: Wire-level request-boundary tests

**Files:**
- Modify: `test/image_pipe/imgproxy_wire_conformance_test.exs`

Real `ImagePipe.call/2` requests asserting user-visible contracts: embedded profile + decoded pixels, no-geometry form, `cp` overrides `scp`, EXIF still stripped, cache reuse / distinct keys. Keep representative, not exhaustive.

> Read the existing tests in this file first to reuse its request helpers, fixture sources, and decode helpers (it already decodes response bodies and asserts dimensions/headers). The snippets below name stand-in helpers — map them to the real ones.

- [ ] **Step 1: Write the failing wire tests**

```elixir
describe "cp/icc target color profile (wire)" do
  test "cp:display-p3 embeds the target and changes pixels vs strip" do
    # use a wide-gamut fixture if available; otherwise any RGB source — the assertion
    # is on embedded profile presence + decoded pixels, per the spec.
    p3 = request!("rs:fit:32:32/cp:display-p3/plain/#{src()}")
    strip = request!("rs:fit:32:32/scp:1/plain/#{src()}")

    assert decoded(p3) |> has_embedded_icc?()
    refute decoded(p3) |> pixels() == decoded(strip) |> pixels()
  end

  test "cp works without geometry (no-geometry form)" do
    resp = request!("cp:adobe-rgb/plain/#{src()}")
    assert decoded(resp) |> has_embedded_icc?()
  end

  test "cp overrides scp: profile embedded, not stripped" do
    resp = request!("cp:p3/scp:1/plain/#{src()}")
    assert decoded(resp) |> has_embedded_icc?()
  end

  test "EXIF/GPS still stripped under a cp target" do
    resp = request!("cp:display-p3/plain/#{src_with_gps()}")
    img = decoded(resp)
    assert has_embedded_icc?(img)
    assert exif_gps(img) == nil
  end

  test "cache: equal cp requests reuse; different targets get distinct keys" do
    k_p3a = cache_key!("cp:p3/plain/#{src()}")
    k_p3b = cache_key!("cp:display-p3/plain/#{src()}")
    k_adobe = cache_key!("cp:adobe-rgb/plain/#{src()}")

    assert k_p3a == k_p3b
    refute k_p3a == k_adobe
  end
end
```

- [ ] **Step 2: Run tests to verify they fail / then pass**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: these pass once Tasks 2-4 are in (this task adds no production code — it pins the end-to-end contract). If any fail, the failure points at a real integration gap to fix before proceeding. If a true wide-gamut fixture is unavailable, note it inline and assert embedded-profile presence + that pixels differ from the `scp:1` baseline rather than absolute pixel values.

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "test(imgproxy): wire-level cp target color-profile contracts"
```

---

## Task 6: Docs — support matrix

**Files:**
- Modify: `docs/imgproxy_support_matrix.md`

Comment/doc-only — skip the compile/test gate.

- [ ] **Step 1: Flip the `cp`/`icc` rows and record divergences**

Update the two `Missing` rows (lines ~778-779) and the `IMGPROXY_COLOR_PROFILES_DIR` line (~474):

- `color_profile` / `cp`,`icc` → **Supported (built-in RGB targets)**. State: targets `srgb` (surface-faithful built-in name), `display-p3`/`p3` and `adobe-rgb`/`adobergb` (**ImagePipe extensions** — Pro reaches these only via `IMGPROXY_COLOR_PROFILES_DIR`, so the same URL may resolve differently on Pro). `cmyk` not yet supported (→ #214). Shipped profiles are **CC0 substitutes** — bytes differ from Pro for every identifier incl. `srgb`; primaries match, `description`/TRC may differ; **not byte-conformant**. `cp` overrides/survives `scp`. No percent-decoding in v1.
- Tag the divergence axes per the conformance discipline: **surface** (extension identifiers), **behavioral/pixel** (CC0 substitute bytes), **stage/order** (none new — reuses encoder finalize).
- `IMGPROXY_COLOR_PROFILES_DIR` stays ⭕ — custom-dir resolution out of scope.

- [ ] **Step 2: Commit**

```bash
git add docs/imgproxy_support_matrix.md
git commit -m "docs(imgproxy): mark cp/icc built-in RGB targets supported"
```

---

## Task 7: Demo — fiddle `cp` control

**Files:**
- Modify: `fiddle/assets/` (Svelte controls + URL state — locate the existing `scp` control and mirror it)

- [ ] **Step 1: Add the control**

Find where `scp`/`strip_color_profile` is wired in `fiddle/assets/` and add a `cp` target selector with options: none / `srgb` / `display-p3` / `adobe-rgb`, wired into the imgproxy URL builder and URL state the same way. When a target is selected, emit `cp:<value>` in the URL; "none" omits it.

- [ ] **Step 2: Verify the fiddle build/lint**

Run: `mise exec -- mix run -e ':ok'` is NOT enough here — run the fiddle JS checks:
`cd fiddle && mise exec -- pnpm check && mise exec -- pnpm lint && mise exec -- pnpm build`
Expected: check/lint/build all pass.

- [ ] **Step 3: Commit**

```bash
git add fiddle/assets/
git commit -m "feat(fiddle): add cp target color-profile control"
```

---

## Task 8: Full gate

- [ ] **Step 1: Run the Elixir gate**

Run: `mise exec -- mix format --check-formatted && mise exec -- mix compile --warnings-as-errors && mise exec -- mix credo --strict && mise exec -- mix test`
Expected: all green. Fix any formatting/credo/warning issues and amend the relevant commit.

- [ ] **Step 2: Run the demo gate (fiddle touched)**

Run: `mise run precommit:demo`
Expected: Elixir gate + fiddle verify suite all pass.

- [ ] **Step 3: Branch rename + readiness**

Rename the branch to something descriptive before any push (leave the worktree dir as-is):
```bash
git branch -m feat/imgproxy-cp-target-color-profile
```
Do not push unless asked.

---

## Self-Review (filled at write time)

**Spec coverage:**
- Built-in allowlist `srgb`/`display_p3`/`adobe_rgb`, no dir/path → Tasks 1,2,4. ✅
- CC0 substitutes + provenance/honesty → Tasks 1,6. ✅
- `{:convert, _}` arm at finalize, bypass `maybe_drop_profile`, input_profile not embedded, greyscale promotion → Task 3 (B1/B2/N1/N2). ✅
- Parser `cp`/`icc` aliases, unknown→error pre-side-effect, precedence over `scp` → Task 4 (Q3). ✅
- Cache key/ETag free (no task — verified unchanged in File Structure). ✅
- Tests: parser, unknown-error, precedence, request-boundary pixels, no-geometry, cp-overrides-scp, EXIF-still-strips, greyscale, untagged, cache reuse/distinct → Tasks 3,4,5. ✅
- Docs + demo → Tasks 6,7. ✅
- CMYK deferred (#214), percent-decode non-goal, namespace-collision note → Tasks 4 (comment),6. ✅

**Placeholder scan:** the only intentional `<…>` placeholders are real-value fills in `PROVENANCE.md` (source/license/SHA) and the stand-in test-helper names, both flagged to map to existing helpers. No TBD/TODO in production steps.

**Type consistency:** target atoms `:srgb | :display_p3 | :adobe_rgb` consistent across `ColorProfile.path!/1`, parser `color_profile_target/1`, plan `{:convert, target}`, and `color_profile_policy/2`. Plan field name `color_profile` consistent (parser pipeline field, output map key, `Plan.Output.color_profile`). `convert_to_target/3`, `effective_color_profile/1`, `color_profile_policy/2` referenced consistently where defined.
