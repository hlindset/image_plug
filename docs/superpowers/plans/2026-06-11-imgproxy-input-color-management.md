# Input Color Management (#124) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generalize input color management to match imgproxy — import every profiled/wide-gamut/CMYK source to a working space before all processing (trim included), and re-embed the source profile on output (`scp:0`) or drop it (`scp:1`) — by introducing a fixed pipeline preamble + a single `Plan.Output` color-profile policy, retiring `NormalizeColorProfile`.

**Architecture:** Input conditioning is a **data-determined pipeline preamble** (`ImagePipe.Transform.InputColorManagement`), not a `Plan.Operation` — seeded once in `PlanExecutor.execute/3`, it imports the embedded ICC into a working space and records the source profile on `State`. The output decision is a declarative `Plan.Output.color_profile` policy (`:preserve_source | :strip | {:convert, target}`), threaded through `Output.Policy → Resolved`. The carried source profile is stamped onto private image metadata at the post-flush + post-Clamp seam in `Request.Processor.materialize_for_delivery/2`; the encoder finalize ports imgproxy's `colorspaceToResult` state machine. `supports_hdr?` is hardwired `false` (the #121 seam).

**Tech Stack:** Elixir, `Vix.Vips.Operation` (`icc_import`/`icc_export`/`icc_transform`/`colourspace`), the `image` library, ExUnit + StreamData, Boundary.

**Spec:** `docs/superpowers/specs/2026-06-11-imgproxy-input-color-management-design.md` (reviewed ×3).

---

## File Structure

**New:**
- `lib/image_pipe/transform/input_color_management.ex` — the preamble: working-space chooser (`working_space/2`), ICC header sniffs (`pcs/1`, `srgb_iec61966?/1`), and the import executor (`condition/2`). Owns input conditioning. In the `Transform` boundary.
- `test/image_pipe/transform/input_color_management_test.exs` — unit tests for the chooser + sniffs.
- `test/image_pipe/transform/input_color_management_sequential_test.exs` — the preamble-specific sequential-safety harness.
- `test/image_pipe/output/color_result_test.exs` — finalize colorspace-to-result behavior.

**Modified:**
- `lib/image_pipe/plan/output.ex` — `strip_color_profile` boolean → `color_profile` policy.
- `lib/image_pipe/output/policy.ex`, `lib/image_pipe/output/resolved.ex` — thread the policy.
- `lib/image_pipe/format.ex` — add `supports_color_profile?/1`.
- `lib/image_pipe/parser/imgproxy/plan_builder.ex` — map `scp` → policy; drop the color op.
- `lib/image_pipe/cache/key.ex` — three output branches use the policy.
- `lib/image_pipe/transform/state.ex` — add `source_color_profile`, `color_imported?`.
- `lib/image_pipe/transform/plan_executor.ex` — seed preamble in `execute/3`; remove op clause.
- `lib/image_pipe/request/processor.ex` — stamp carry in `materialize_for_delivery/2`.
- `lib/image_pipe/output/encoder.ex` — colorspace-to-result finalize.
- `lib/image_pipe/plan.ex`, `lib/image_pipe/transform.ex` — drop the `NormalizeColorProfile` exports.
- `lib/image_pipe/plan/operation.ex`, `lib/image_pipe/plan/key_data.ex` — drop op references.
- `lib/image_pipe/telemetry/logger.ex`, `docs/telemetry.md` — the new stage span.
- `docs/imgproxy_support_matrix.md` — stages 4/16/17, trim, scp rows, prose, diverges.
- `test/support/image_pipe/test/imgproxy_differential/constellations.ex` — flip the `scp0_colorspace_124` divergence.

**Deleted:**
- `lib/image_pipe/plan/operation/normalize_color_profile.ex`
- `lib/image_pipe/transform/operation/normalize_color_profile.ex`

---

## Task 1: Migrate `strip_color_profile` boolean → `color_profile` policy (behavior-preserving)

This is a behavior-preserving reshape: `:strip` ≡ old `true`, `:preserve_source` ≡ old `false`. `NormalizeColorProfile` is still emitted for `:strip` and the encoder behavior is unchanged. Existing tests are updated to the new field and stay green.

**Files:**
- Modify: `lib/image_pipe/plan/output.ex`
- Modify: `lib/image_pipe/output/policy.ex`
- Modify: `lib/image_pipe/output/resolved.ex`
- Modify: `lib/image_pipe/parser/imgproxy/plan_builder.ex:91-122` (both `output_plan` clauses) and `:241-247` (`color_profile_operations`)
- Modify: `lib/image_pipe/cache/key.ex:103-151` (three output branches)
- Modify: `lib/image_pipe/output/encoder.ex:48-90` (read policy, preserve behavior)
- Test: `test/parser/imgproxy_test.exs`, `test/image_pipe/imgproxy_wire_conformance_test.exs`, cache-key tests (update references)

- [ ] **Step 1: Update the `Plan.Output` struct + type**

In `lib/image_pipe/plan/output.ex`, replace the `strip_color_profile` field and type. Update the `@moduledoc` line that names it.

```elixir
defstruct mode: :automatic,
          quality: :default,
          format_qualities: %{},
          strip_metadata: true,
          keep_copyright: true,
          color_profile: :strip

@type color_profile :: :preserve_source | :strip | {:convert, term()}
@type t :: %__MODULE__{
        mode: :automatic | {:explicit, format()},
        quality: quality(),
        format_qualities: %{optional(format()) => quality()},
        strip_metadata: boolean(),
        keep_copyright: boolean(),
        color_profile: color_profile()
      }
```

Update the moduledoc: the three fields are resolved before plan build; `color_profile` drives the encoder's color finalize.

- [ ] **Step 2: Thread the policy through `Output.Resolved` and `Output.Policy`**

In `lib/image_pipe/output/resolved.ex`, replace `:strip_color_profile` with `:color_profile` in `@enforce_keys` and the type (type: `ImagePipe.Plan.Output.color_profile()`).

In `lib/image_pipe/output/policy.ex`, replace `:strip_color_profile` with `:color_profile` in `@enforce_keys`, the `@type t`, both `from_output_plan/3` clauses (`strip_color_profile: output.strip_color_profile` → `color_profile: output.color_profile`), and the `resolved/2` helper (`strip_color_profile: policy.strip_color_profile` → `color_profile: policy.color_profile`).

- [ ] **Step 3: Map `scp` → policy in the imgproxy plan builder, keyed gate on `:strip`**

In `lib/image_pipe/parser/imgproxy/plan_builder.ex`, both `output_plan` clauses: replace `strip_color_profile: request.strip_color_profile` with:

```elixir
color_profile: if(request.strip_color_profile, do: :strip, else: :preserve_source)
```

And `color_profile_operations/1` keeps emitting the (still-existing) op for the strip case only — leave it keyed on `request.strip_color_profile` for now (Task 8 deletes it).

- [ ] **Step 4: Update the three cache-key output branches**

In `lib/image_pipe/cache/key.ex`, in `output_plan_data/2` (both `:automatic` and `{:explicit, _}` clauses) and `output_data/3` (`:automatic` clause), replace the `strip_color_profile: output.strip_color_profile` keyword entry with `color_profile: output.color_profile`.

- [ ] **Step 5: Make the encoder read the policy (behavior-preserving)**

In `lib/image_pipe/output/encoder.ex`, rewrite the `finalize/2` clauses and the `strip/2` + `icc_fields/1` helpers to read `color_profile` instead of `strip_color_profile`, deriving the old boolean meaning (`:strip` ⇒ drop ICC, `:preserve_source` ⇒ keep). Keep the existing logic otherwise:

```elixir
defp finalize(image, %Resolved{strip_metadata: false, color_profile: :preserve_source}),
  do: {:ok, image}

defp finalize(image, %Resolved{} = resolved) do
  case VixImage.copy_memory(image) do
    {:ok, mem} -> {:ok, strip(mem, resolved)}
    {:error, reason} -> {:error, {:decode, reason}}
  end
end

# :strip with strip_metadata:false → drop just the ICC profile.
defp strip(image, %Resolved{strip_metadata: false, color_profile: :strip}),
  do: remove_fields(image, ["icc-profile-data"])

defp strip(image, %Resolved{strip_metadata: false, color_profile: :preserve_source}),
  do: image

defp strip(image, %Resolved{} = resolved) do
  keep = if resolved.keep_copyright, do: [:copyright, :artist], else: []
  icc = if resolved.color_profile == :strip, do: nil, else: header_value(image, "icc-profile-data")
  # ... unchanged minimize_metadata / fallback / restore_icc body ...
end

defp icc_fields(%Resolved{color_profile: :strip}), do: ["icc-profile-data"]
defp icc_fields(%Resolved{}), do: []
```

- [ ] **Step 6: Update existing tests to the new field, run them, verify green**

Search and update every test asserting `strip_color_profile:` on `Plan.Output`/`Policy`/`Resolved` to the `color_profile:` policy (`true` → `:strip`, `false` → `:preserve_source`). The cache-key and wire tests should still pass with identical observable behavior.

Run: `mise exec -- mix test test/parser/imgproxy_test.exs test/image_pipe/imgproxy_wire_conformance_test.exs test/image_pipe/cache`
Expected: PASS (behavior unchanged; only the field name/shape changed).

- [ ] **Step 7: Compile clean + commit**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: no warnings.

```bash
git add lib/image_pipe/plan/output.ex lib/image_pipe/output/ lib/image_pipe/parser/imgproxy/plan_builder.ex lib/image_pipe/cache/key.ex lib/image_pipe/output/encoder.ex test/
git commit -m "refactor(output): color_profile policy replaces strip_color_profile boolean"
```

---

## Task 2: Working-space chooser (`working_space/2`)

Pure port of imgproxy `guessTargetColorspace` with `supports_hdr?` hardwired `false`.

**Files:**
- Create: `lib/image_pipe/transform/input_color_management.ex`
- Test: `test/image_pipe/transform/input_color_management_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ImagePipe.Transform.InputColorManagementTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.InputColorManagement, as: ICM

  describe "working_space/2 (supports_hdr?: false)" do
    test "8-bit color and grey stay as-is" do
      assert ICM.working_space(:VIPS_INTERPRETATION_sRGB, false) == :VIPS_INTERPRETATION_sRGB
      assert ICM.working_space(:VIPS_INTERPRETATION_RGB, false) == :VIPS_INTERPRETATION_sRGB
      assert ICM.working_space(:VIPS_INTERPRETATION_B_W, false) == :VIPS_INTERPRETATION_B_W
    end

    test "16-bit tone-maps to 8-bit standard" do
      assert ICM.working_space(:VIPS_INTERPRETATION_RGB16, false) == :VIPS_INTERPRETATION_sRGB
      assert ICM.working_space(:VIPS_INTERPRETATION_GREY16, false) == :VIPS_INTERPRETATION_B_W
    end

    test "CMYK and unknown go to sRGB" do
      assert ICM.working_space(:VIPS_INTERPRETATION_CMYK, false) == :VIPS_INTERPRETATION_sRGB
      assert ICM.working_space(:VIPS_INTERPRETATION_scRGB, false) == :VIPS_INTERPRETATION_sRGB
    end
  end
end
```

- [ ] **Step 2: Run, verify fail**

Run: `mise exec -- mix test test/image_pipe/transform/input_color_management_test.exs`
Expected: FAIL (module/function undefined).

- [ ] **Step 3: Implement the module + chooser**

```elixir
defmodule ImagePipe.Transform.InputColorManagement do
  @moduledoc """
  Fixed, data-determined input-conditioning preamble (NOT a `Plan.Operation`):
  imports the embedded ICC profile into a working space before any processing
  step, mirroring imgproxy's `colorspaceToProcessing`. Seeded once by
  `ImagePipe.Transform.PlanExecutor`. `supports_hdr?` is hardwired `false`
  today (the #121 seam).
  """

  @doc "Working-space interpretation for a decoded image (port of guessTargetColorspace)."
  @spec working_space(atom(), boolean()) :: atom()
  def working_space(interpretation, supports_hdr?)

  def working_space(i, _hdr) when i in [:VIPS_INTERPRETATION_sRGB, :VIPS_INTERPRETATION_RGB, :VIPS_INTERPRETATION_B_W],
    do: i

  def working_space(:VIPS_INTERPRETATION_RGB16, true), do: :VIPS_INTERPRETATION_RGB16
  def working_space(:VIPS_INTERPRETATION_RGB16, false), do: :VIPS_INTERPRETATION_sRGB
  def working_space(:VIPS_INTERPRETATION_GREY16, true), do: :VIPS_INTERPRETATION_GREY16
  def working_space(:VIPS_INTERPRETATION_GREY16, false), do: :VIPS_INTERPRETATION_B_W
  def working_space(:VIPS_INTERPRETATION_CMYK, _hdr), do: :VIPS_INTERPRETATION_sRGB
  def working_space(_other, true), do: :VIPS_INTERPRETATION_RGB16
  def working_space(_other, false), do: :VIPS_INTERPRETATION_sRGB
end
```

- [ ] **Step 4: Run, verify pass**

Run: `mise exec -- mix test test/image_pipe/transform/input_color_management_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/input_color_management.ex test/image_pipe/transform/input_color_management_test.exs
git commit -m "feat(transform): working-space chooser for input color management"
```

---

## Task 3: ICC header sniffs (`pcs/1`, `srgb_iec61966?/1`)

Pure binary sniffs porting imgproxy `vips_icc_get_pcs` (bytes 20–23) and `vips_icc_is_srgb_iec61966`, both guarded by `byte_size(profile) >= 128`.

**Files:**
- Modify: `lib/image_pipe/transform/input_color_management.ex`
- Modify: `test/image_pipe/transform/input_color_management_test.exs`

- [ ] **Step 1: Write the failing test**

Use the real wide-gamut fixture (a Display-P3 profile, XYZ PCS) and a crafted minimal header.

```elixir
describe "pcs/1" do
  test "reads XYZ vs LAB from bytes 20-23, LAB on short/absent" do
    xyz = <<0::size(20 * 8), "XYZ ", 0::size(104 * 8)>>
    lab = <<0::size(20 * 8), "Lab ", 0::size(104 * 8)>>
    assert ICM.pcs(xyz) == :VIPS_PCS_XYZ
    assert ICM.pcs(lab) == :VIPS_PCS_LAB
    assert ICM.pcs(<<0, 1, 2>>) == :VIPS_PCS_LAB
    assert ICM.pcs(nil) == :VIPS_PCS_LAB
  end
end

describe "srgb_iec61966?/1" do
  test "false for a Display-P3 profile, false for short/absent" do
    {:ok, img} = Image.open(Path.join(__DIR__, "../../support/.../icc_p3.png"))
    {:ok, p3} = Vix.Vips.Image.header_value(img, "icc-profile-data")
    refute ICM.srgb_iec61966?(p3)
    refute ICM.srgb_iec61966?(<<0, 1, 2>>)
    refute ICM.srgb_iec61966?(nil)
  end
end
```

(Adjust the fixture path to the real `icc_p3.png` location — confirm with `find test -name icc_p3.png`.)

- [ ] **Step 2: Run, verify fail**

Run: `mise exec -- mix test test/image_pipe/transform/input_color_management_test.exs`
Expected: FAIL (functions undefined).

- [ ] **Step 3: Implement the sniffs**

Port `vips_icc_is_srgb_iec61966` (`local/imgproxy-master/vips/vips.c:454`) byte-for-byte — it compares fixed bytes at offsets 16, 24, 48, 52, 80 and a version at 8. Read those exact comparisons from the upstream source and translate to Elixir binary pattern matches. PCS:

```elixir
@spec pcs(binary() | nil) :: :VIPS_PCS_XYZ | :VIPS_PCS_LAB
def pcs(profile) when is_binary(profile) and byte_size(profile) >= 128 do
  case binary_part(profile, 20, 4) do
    "XYZ " -> :VIPS_PCS_XYZ
    _ -> :VIPS_PCS_LAB
  end
end

def pcs(_), do: :VIPS_PCS_LAB

@spec srgb_iec61966?(binary() | nil) :: boolean()
def srgb_iec61966?(profile) when is_binary(profile) and byte_size(profile) >= 128 do
  # Translate vips_icc_is_srgb_iec61966 (vips/vips.c:454): fixed-byte equality
  # at the documented offsets. Implement the exact comparisons from upstream.
  ...
end

def srgb_iec61966?(_), do: false
```

**Verification step (de-risk #4 in spec):** open the upstream `vips_icc_is_srgb_iec61966` and replicate its byte checks exactly; assert against a known sRGB-IEC61966 profile (extract one with `Image` from an sRGB-tagged fixture) returning `true`.

- [ ] **Step 4: Run, verify pass** — `mise exec -- mix test test/image_pipe/transform/input_color_management_test.exs` → PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/transform/input_color_management.ex test/image_pipe/transform/input_color_management_test.exs
git commit -m "feat(transform): ICC header PCS + sRGB-IEC61966 sniffs"
```

---

## Task 4: State carry fields

**Files:**
- Modify: `lib/image_pipe/transform/state.ex`

- [ ] **Step 1: Add the fields + type, document them**

In `defstruct`, add `source_color_profile: nil` and `color_imported?: false`. In `@type t`, add:

```elixir
source_color_profile: binary() | nil,
color_imported?: boolean(),
```

Add a `@moduledoc` bullet: `source_color_profile`/`color_imported?` carry the input-color-management result (raw source ICC bytes + whether an `icc_import` actually ran) from the preamble to the delivery-boundary stamp; they are transform-domain data, never emitted in telemetry.

- [ ] **Step 2: Compile + commit**

Run: `mise exec -- mix compile --warnings-as-errors` → clean.

```bash
git add lib/image_pipe/transform/state.ex
git commit -m "feat(transform): State carry for source color profile + imported flag"
```

---

## Task 5: Preamble import executor (`condition/2`) + sequential-safety harness

The meat. Mirrors `colorspaceToProcessing` + `vips_icc_import_go`.

**Files:**
- Modify: `lib/image_pipe/transform/input_color_management.ex`
- Create: `test/image_pipe/transform/input_color_management_sequential_test.exs`
- Modify: `test/image_pipe/transform/input_color_management_test.exs`

- [ ] **Step 1: Write the behavioral tests (fixtures)**

Add to `input_color_management_test.exs` a `describe "condition/2"` block opening real fixtures via a genuinely streamed open and asserting State + image outcomes:

```elixir
describe "condition/2" do
  setup do
    %{open: fn path -> Image.open!(path, access: :sequential) end}
  end

  test "wide-gamut (Display-P3) imports: records source profile, sets imported, lands sRGB", %{open: open} do
    img = open.(fixture("icc_p3.png"))
    state = %State{image: img}
    {:ok, out} = ICM.condition(state, supports_hdr?: false)
    assert out.color_imported? == true
    assert is_binary(out.source_color_profile)
    assert Vix.Vips.Image.interpretation(out.image) == :VIPS_INTERPRETATION_sRGB
  end

  test "untagged sRGB is a no-op: no import, no backup", %{open: open} do
    img = open.(fixture("plain_srgb.png"))
    {:ok, out} = ICM.condition(%State{image: img}, supports_hdr?: false)
    assert out.color_imported? == false
    assert out.source_color_profile == nil
  end

  test "CMYK imports and lands sRGB", %{open: open} do
    {:ok, out} = ICM.condition(%State{image: open.(fixture("cmyk.jpg"))}, supports_hdr?: false)
    assert out.color_imported? == true
    assert Vix.Vips.Image.interpretation(out.image) == :VIPS_INTERPRETATION_sRGB
  end

  test "linear (scRGB) drops profile, does not record backup, still converts", %{open: open} do
    {:ok, out} = ICM.condition(%State{image: linear_fixture()}, supports_hdr?: false)
    assert out.color_imported? == false
    assert out.source_color_profile == nil
  end
end
```

(Confirm/curate fixtures: `icc_p3.png` exists under the differential fixtures; add `plain_srgb.png` and a `cmyk.jpg` if absent. For `linear_fixture/0` build an scRGB image via `Vix.Vips.Operation.colourspace/2`.)

- [ ] **Step 2: Run, verify fail** — FAIL (`condition/2` undefined).

- [ ] **Step 3: Implement `condition/2`**

```elixir
import ImagePipe.Transform.State, only: [set_image: 2]
alias ImagePipe.Transform.State
alias Vix.Vips.Image, as: VixImage
alias Vix.Vips.Operation

@spec condition(State.t(), keyword()) :: {:ok, State.t()} | {:error, {__MODULE__, term()}}
def condition(%State{color_imported?: true} = state, _opts), do: {:ok, state}  # idempotency guard

def condition(%State{image: image} = state, opts) do
  hdr? = Keyword.get(opts, :supports_hdr?, false)
  interp = VixImage.interpretation(image)
  target = working_space(interp, hdr?)

  with {:ok, image} <- rad2float(image),
       {:ok, state} <- do_condition(state, image, interp, target) do
    {:ok, state}
  else
    {:error, reason} -> {:error, {__MODULE__, reason}}
  end
end

# Linear: drop profile, no backup/import, still convert to working space.
defp do_condition(state, image, :VIPS_INTERPRETATION_scRGB, target) do
  with {:ok, image} <- remove_profile(image),
       {:ok, image} <- to_colorspace(image, target) do
    {:ok, set_image(state, image)}
  end
end

defp do_condition(state, image, interp, target) do
  profile = header_value(image, "icc-profile-data")

  if importable?(image, interp, profile) do
    with {:ok, imported} <- icc_import(image, profile),
         {:ok, image} <- to_colorspace(imported, target) do
      {:ok, %State{set_image(state, image) | source_color_profile: profile, color_imported?: true}}
    end
  else
    with {:ok, image} <- to_colorspace(image, target), do: {:ok, set_image(state, image)}
  end
end

# Import gating: embedded profile present AND not (sRGB interp AND sRGB-IEC61966)
# AND coding NONE AND band format UCHAR/USHORT.
defp importable?(image, interp, profile) do
  is_binary(profile) and
    not (interp == :VIPS_INTERPRETATION_sRGB and srgb_iec61966?(profile)) and
    coding_none?(image) and band_format_importable?(image)
end
```

Implement the leaf helpers against the verified vix surface:
- `icc_import(image, profile)` → `Operation.icc_import(image, embedded: true, pcs: pcs(profile))`. **16-bit + alpha** (interpretation RGB16/GREY16 with `bands > colorbands`): split the alpha band (`Operation.extract_band/3`), import the color bands, rescale alpha 65535→255 (`Operation.linear/...` with `1/255`), and `Operation.bandjoin/1` — port `vips_icc_import_go` (`local/imgproxy-master/vips/vips.c:544`).
- `to_colorspace(image, target)` → `Operation.colourspace(image, target)` (no-op-safe when already in `target`).
- `rad2float/1` → best-effort `Operation.rad2float/1` when coding is Radiance, else `{:ok, image}`.
- `remove_profile/1`, `coding_none?/1`, `band_format_importable?/1`, `header_value/2` → small wrappers over `VixImage` header/coding/format accessors.

**Verification step (de-risk #1/#3):** confirm `Operation.icc_import/2` accepts `embedded:`/`pcs:` and the alpha helpers exist with the names used (`mise exec -- mix run -e 'Code.ensure_loaded(Vix.Vips.Operation); ...'`); adjust option keywords to match.

- [ ] **Step 4: Run behavioral tests, verify pass** — `mise exec -- mix test test/image_pipe/transform/input_color_management_test.exs` → PASS.

- [ ] **Step 5: Write the sequential-safety harness**

`test/image_pipe/transform/input_color_management_sequential_test.exs` — apply `condition/2` on a genuinely streamed open (`access: :sequential, fail_on: :error`), then `Vix.Vips.Image.copy_memory/1`, and compare pixels against the same source opened with `access: :random`. Include the **known-random self-check** (a raw `Operation.flip/2` vertical or transpose on the streamed open must raise) so equivalence can't pass tautologically. Cover wide-gamut + CMYK + Grey16 + 16-bit-with-alpha. Add a variant that runs a quarter-turn orientation flush after `condition/2` (then `copy_memory`) and asserts pixel-equivalence to the random-open baseline.

```elixir
defmodule ImagePipe.Transform.InputColorManagementSequentialTest do
  use ExUnit.Case, async: true
  # ... open seq + random, condition, copy_memory, compare via Image pixel readback;
  #     self-check that a known-random op raises under :sequential/:fail_on=:error.
end
```

- [ ] **Step 6: Run, verify pass** — `mise exec -- mix test test/image_pipe/transform/input_color_management_sequential_test.exs` → PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/transform/input_color_management.ex test/image_pipe/transform/input_color_management_test.exs test/image_pipe/transform/input_color_management_sequential_test.exs
git commit -m "feat(transform): input color-management preamble executor + sequential-safety gate"
```

---

## Task 6: `Format.supports_color_profile?/1`

**Files:**
- Modify: `lib/image_pipe/format.ex`
- Test: `test/image_pipe/format_test.exs` (or the existing format test file)

- [ ] **Step 1: Write the failing test**

```elixir
test "supports_color_profile?/1 mirrors imgproxy SupportsColourProfile" do
  assert ImagePipe.Format.supports_color_profile?(:jpeg)
  assert ImagePipe.Format.supports_color_profile?(:png)
  assert ImagePipe.Format.supports_color_profile?(:webp)
  assert ImagePipe.Format.supports_color_profile?(:avif)
end
```

(Confirm each format's truth value against imgproxy's `Format.SupportsColourProfile()` in the local checkout before pinning the assertions.)

- [ ] **Step 2: Run, verify fail** — FAIL (undefined).

- [ ] **Step 3: Implement** in `lib/image_pipe/format.ex`:

```elixir
@spec supports_color_profile?(output_format()) :: boolean()
def supports_color_profile?(format), do: format in @color_profile_formats
```

with a module attribute listing the profile-supporting output formats (per upstream).

- [ ] **Step 4: Run, verify pass** — PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/format.ex test/image_pipe/format_test.exs
git commit -m "feat(output): Format.supports_color_profile?/1"
```

---

## Task 7: Stamp carry onto the image at the delivery boundary

Stamps the two private fields from `State` onto the realized image inside `materialize_for_delivery/2` (post-flush + post-Clamp). Nothing reads them yet — safe, no behavior change.

**Files:**
- Modify: `lib/image_pipe/request/processor.ex:223-232`
- Test: `test/image_pipe/request/processor_test.exs` (or nearest)

- [ ] **Step 1: Write the failing test**

```elixir
test "materialize_for_delivery stamps source profile + imported marker from State carry" do
  state = %State{image: some_realized_image(), source_color_profile: <<1, 2, 3>>, color_imported?: true, materialized?: true}
  {:ok, out} = Processor.materialize_for_delivery(state, processor_opts())
  assert {:ok, <<1, 2, 3>>} = Vix.Vips.Image.header_value(out.image, "imagepipe-icc-backup")
  assert {:ok, 1} = Vix.Vips.Image.header_value(out.image, "imagepipe-icc-imported")
end
```

- [ ] **Step 2: Run, verify fail** — FAIL (fields absent).

- [ ] **Step 3: Implement the stamp**

In `materialize_for_delivery/2`, after a successful materialize, stamp the carry onto the realized image:

```elixir
def materialize_for_delivery(%State{} = state, opts) do
  result =
    if state.materialized?, do: {:ok, state}, else: materialize_state(state, opts)

  with {:ok, %State{} = materialized} <- classify_delivery_materialize_result(result) do
    {:ok, stamp_color_carry(materialized)}
  end
end

defp stamp_color_carry(%State{color_imported?: false} = state), do: state

defp stamp_color_carry(%State{source_color_profile: profile} = state) when is_binary(profile) do
  {:ok, image} =
    VixImage.mutate(state.image, fn mut ->
      VixMutableImage.set(mut, "imagepipe-icc-backup", :VipsBlob, profile)
      VixMutableImage.set(mut, "imagepipe-icc-imported", :gint, 1)
      :ok
    end)

  set_image(state, image)
end
```

(Add the `Vix.Vips.MutableImage`/`set_image` aliases/imports; `classify_delivery_materialize_result` already maps errors to `{:decode, _}`.)

- [ ] **Step 4: Run, verify pass** — PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/request/processor.ex test/
git commit -m "feat(request): stamp source-profile carry at delivery materialization"
```

---

## Task 8: Cutover — wire preamble, port finalize state machine, delete `NormalizeColorProfile`

The atomic switch. After this task the live pipeline uses the preamble + the new finalize; the old op is gone. Validated by the finalize behavior test + the differential gate.

**Files:**
- Modify: `lib/image_pipe/transform/plan_executor.ex` (seed preamble in `execute/3`; remove op clause + aliases)
- Modify: `lib/image_pipe/output/encoder.ex` (colorspace-to-result finalize)
- Modify: `lib/image_pipe/parser/imgproxy/plan_builder.ex` (drop `color_profile_operations`)
- Modify: `lib/image_pipe/plan.ex`, `lib/image_pipe/transform.ex` (drop exports)
- Modify: `lib/image_pipe/plan/operation.ex`, `lib/image_pipe/plan/key_data.ex`
- Delete: both `normalize_color_profile.ex` files
- Modify: `test/image_pipe/architecture_boundary_test.exs`
- Create: `test/image_pipe/output/color_result_test.exs`

- [ ] **Step 1: Write the finalize state-machine test (failing)**

`test/image_pipe/output/color_result_test.exs` — drive `Encoder.stream_output/3` (or the finalize seam) with realized images carrying the private fields:

```elixir
# keep_profile && imported  -> output carries the source profile bytes
test ":preserve_source + imported re-embeds the source profile (jpeg)" do
  img = image_with_carry(source_profile: p3_bytes(), imported: true)
  {:ok, stream, _mime} = Encoder.stream_output(img, resolved(:jpeg, :preserve_source), opts())
  out = decode(stream)
  assert {:ok, embedded} = Vix.Vips.Image.header_value(out, "icc-profile-data")
  assert embedded == p3_bytes()
end

# :preserve_source + strip_metadata:false MUST still re-embed (old short-circuit reworked)
test ":preserve_source re-embeds even with strip_metadata:false" do
  img = image_with_carry(source_profile: p3_bytes(), imported: true)
  {:ok, stream, _} = Encoder.stream_output(img, resolved(:jpeg, :preserve_source, strip_metadata: false), opts())
  assert {:ok, _} = Vix.Vips.Image.header_value(decode(stream), "icc-profile-data")
end

# :strip drops the profile
test ":strip drops the ICC profile" do
  img = image_with_carry(source_profile: p3_bytes(), imported: true)
  {:ok, stream, _} = Encoder.stream_output(img, resolved(:jpeg, :strip), opts())
  assert :error == Vix.Vips.Image.header_value(decode(stream), "icc-profile-data") |> elem(0) |> then(&{&1})
  # i.e. no icc-profile-data field
end

# untagged + :strip + strip_metadata:false stays a near-no-op (common path)
test "untagged :strip is pixel-identical (no spurious transform)" do
  base = plain_srgb_image()
  {:ok, stream, _} = Encoder.stream_output(base, resolved(:jpeg, :strip, strip_metadata: false), opts())
  assert_pixels_equal(decode(stream), base)
end
```

- [ ] **Step 2: Run, verify fail** — FAIL (new finalize not implemented; private fields not consumed).

- [ ] **Step 3: Port the colorspace-to-result finalize**

Rewrite `finalize/2` in `lib/image_pipe/output/encoder.ex` to the spec §4 sequence. After the existing `copy_memory` realize, read `imagepipe-icc-backup` + `imagepipe-icc-imported`; restore the backup to `icc-profile-data`; switch on `(keep_profile, imported)` where `keep_profile = resolved.color_profile == :preserve_source and Format.supports_color_profile?(resolved.format)`; then strip other metadata and remove the two private fields. Concrete shape:

```elixir
defp finalize(image, %Resolved{} = resolved) do
  case VixImage.copy_memory(image) do
    {:ok, mem} -> color_result(mem, resolved)
    {:error, reason} -> {:error, {:decode, reason}}
  end
end

defp color_result(image, %Resolved{} = resolved) do
  imported = header_value(image, "imagepipe-icc-imported") == 1
  backup = header_value(image, "imagepipe-icc-backup")
  keep? = resolved.color_profile == :preserve_source and Format.supports_color_profile?(resolved.format)

  with {:ok, image} <- restore_backup(image, backup),
       {:ok, image} <- apply_color_result(image, keep?, imported),
       {:ok, image} <- maybe_drop_profile(image, keep?) do
    {:ok, strip_metadata_and_private(image, resolved)}
  end
end

# keep && imported -> icc_export(pcs from restored profile, depth from interp)
defp apply_color_result(image, true, true) do
  case Operation.icc_export(image, pcs: pcs(header_value(image, "icc-profile-data")), depth: icc_depth(image)) do
    {:ok, image} -> {:ok, image}
    {:error, reason} -> {:error, {:decode, reason}}
  end
end

# !keep && !imported -> transform to standard (sRGB/sGrey); no-op for already-standard untagged
defp apply_color_result(image, false, false) do
  case to_standard(image) do
    {:ok, image} -> {:ok, image}
    {:error, reason} -> {:error, {:decode, reason}}
  end
end

defp apply_color_result(image, _keep, _imported), do: {:ok, image}  # keep&&!imported, !keep&&imported
```

Implement `restore_backup/2` (set `icc-profile-data` ← backup blob when present, else `{:ok, image}`), `to_standard/1` (`icc_transform` to `sRGB`/`sGrey` per interpretation, with the upstream embedded/sRGB no-op short-circuit so untagged stays identical), `maybe_drop_profile/2` (remove `icc-profile-data` when `!keep?`), `icc_depth/1` (8/16 from interpretation per imgproxy `image_depth`), and `strip_metadata_and_private/2` (the existing EXIF/XMP/IPTC strip + remove the two private fields). Every color op returns `{:decode, _}` on error; no hard `{:ok,_}=mutate` on the re-embed path.

**Boundary note — define a *local* private `pcs/1` in the encoder.** The encoder is in the `Output` boundary, whose deps are `[Format, Plan]` — it **must not** depend on `Transform.InputColorManagement`. So the 4-byte PCS sniff is duplicated as a private helper here (it is trivial pure code; a shared module would force an illegal `Output → Transform` edge). Keep it byte-identical to `InputColorManagement.pcs/1` so import and export agree:

```elixir
defp pcs(p) when is_binary(p) and byte_size(p) >= 128,
  do: if(binary_part(p, 20, 4) == "XYZ ", do: :VIPS_PCS_XYZ, else: :VIPS_PCS_LAB)

defp pcs(_), do: :VIPS_PCS_LAB
```

**Verification (de-risk #1/#3):** confirm `Operation.icc_export/2` keyword options and that `restore-then-export` yields the byte-identical source profile (the wire test pins this).

- [ ] **Step 4: Run finalize test, verify pass** — `mise exec -- mix test test/image_pipe/output/color_result_test.exs` → PASS.

- [ ] **Step 5: Seed the preamble in `execute/3`**

In `lib/image_pipe/transform/plan_executor.ex`, after the `seed_orientation` block in `execute/3`, condition color on the same real-execution gate:

```elixir
state =
  if Keyword.get(opts, :seed_orientation, false) do
    case InputColorManagement.condition(state, supports_hdr?: false) do
      {:ok, conditioned} -> conditioned
      {:error, _} = error -> throw(error)
    end
  else
    state
  end
```

(Use the existing error channel — wrap so a failure surfaces as `{:error, {:decode, _}}` consistent with the materialization contract; mirror how the module already returns `{:error, term()}` from `execute/3`. Prefer a `with` over `throw` if it reads cleaner against the surrounding code.) Add the `alias ImagePipe.Transform.InputColorManagement`.

- [ ] **Step 6: Delete `NormalizeColorProfile` + all references**

- `rm lib/image_pipe/plan/operation/normalize_color_profile.ex lib/image_pipe/transform/operation/normalize_color_profile.ex`
- `plan_executor.ex`: remove the `PlanNormalizeColorProfile`/`NormalizeColorProfile` aliases and the `executable_operations(%PlanNormalizeColorProfile{}, ...)` clause.
- `plan_builder.ex`: delete `color_profile_operations/1` and remove it from the `plan_geometry/1` `with`/concatenation.
- `plan.ex`, `transform.ex`: remove `Operation.NormalizeColorProfile` from the boundary `exports`.
- `plan/operation.ex`: remove the alias, the `@type` union member, the `normalize_color_profile/0` constructor, and the `semantic?/1` clause.
- `plan/key_data.ex`: remove the `data(%NormalizeColorProfile{})` clause + alias.
- `architecture_boundary_test.exs`: remove `:NormalizeColorProfile` from `@concrete_plan_names`, `@concrete_transform_names`, and the Plan/Transform `assert_boundary_exports*` lists.

- [ ] **Step 7: Migrate the tests that construct/assert the deleted op (delete vs retarget)**

These break on deletion and must be handled in this commit (spec §Test migration):
- `test/parser/imgproxy_test.exs` — the `NormalizeColorProfile` order-position assertions + the `operation_name(%NormalizeColorProfile{})` helper (~lines 122, 1828): **delete** (post-migration parity pin per "no post-migration parity pins"); replace with a parser test asserting `scp` sets `Plan.Output.color_profile` (`:strip`/`:preserve_source`), not an op.
- `test/image_pipe/plan/operation_key_data_test.exs` — the `%NormalizeColorProfile{}` key-data assertions: **delete** (producer gone).
- `test/image_pipe/transform/sequential_access_test.exs` — the `%NormalizeColorProfile{}` op case: **delete** (replaced by the Task 5 preamble harness).
- `test/image_pipe/transform/prefetch_validation_test.exs` — references the **Plan** op (`Plan.Operation.NormalizeColorProfile`): **drop** it from the operation list.
- `test/image_pipe/decode_planner_test.exs` (under `test/image_pipe/`, **not** `transform/`; refs ~29, 37): **drop** the op from its operation lists.
- `test/image_pipe/imgproxy_wire_conformance_test.exs` (~1894–1910) — the `scp:1` output-colorspace assertion: **retarget** to the new finalize (`scp:1 → :strip → sRGB` still holds); fix the rationale comment.

Then `grep -rn "NormalizeColorProfile" lib test` should return nothing.

- [ ] **Step 8: Flip the differential constellation**

In `test/support/image_pipe/test/imgproxy_differential/constellations.ex` (~165), change the `diverge("scp0_colorspace_124", :icc_p3, "rs:fit:200:200/scp:0", … issue: "#124")` entry to an equality case (`c(...)` / `:equal`), dropping the `#124` divergence floor. Regenerate the differential authored-hash/manifest per that harness's regeneration command (check `docs/superpowers/specs/2026-06-10-imgproxy-differential-conformance-design.md` for the regen task).

- [ ] **Step 9: Run the affected suites, verify green**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs test/image_pipe/imgproxy_wire_conformance_test.exs test/image_pipe/architecture_boundary_test.exs test/image_pipe/output/color_result_test.exs`
Expected: PASS. Then the differential suite per its tag/command.

- [ ] **Step 10: Compile clean + commit**

Run: `mise exec -- mix compile --warnings-as-errors` → clean.

```bash
git add -A
git commit -m "feat(transform): cut over to input color-management preamble + colorspace-to-result; retire NormalizeColorProfile"
```

---

## Task 9: Telemetry stage span + Logger sync

**Files:**
- Modify: `lib/image_pipe/transform/plan_executor.ex` (emit the span around the preamble)
- Modify: `lib/image_pipe/telemetry/logger.ex`
- Modify: `docs/telemetry.md`
- Test: `test/image_pipe/telemetry/logger_test.exs`

- [ ] **Step 1: Write the failing logger test**

Assert the Logger renders a line for `[:transform, :input_color_management]` (including its outcome), and escalates to `:warning` on a degraded outcome if one is emitted.

- [ ] **Step 2: Run, verify fail** — FAIL.

- [ ] **Step 3: Emit the span + wire the Logger**

Wrap the preamble call in `execute/3` in a `Telemetry.span`-style `[:transform, :input_color_management]` start/stop/exception (use the shared telemetry helper), metadata `%{working_space: ..., imported?: ...}`. In `logger.ex`: add `[:transform, :input_color_management]` to `@group_span_events` under the `transform` group; add a `message/3` clause that surfaces the outcome; extend `level_for/3` if a degraded outcome is emitted.

- [ ] **Step 4: Run, verify pass** — PASS.

- [ ] **Step 5: Update `docs/telemetry.md`** — document the new stage span + what the Logger renders.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/transform/plan_executor.ex lib/image_pipe/telemetry/logger.ex docs/telemetry.md test/image_pipe/telemetry/logger_test.exs
git commit -m "feat(telemetry): input-color-management stage span + Logger"
```

---

## Task 10: Behavioral / wire / cache conformance coverage

**Files:**
- Modify/Create: `test/image_pipe/imgproxy_wire_conformance_test.exs`, a cache-key test, and a request-boundary pixel test.

- [ ] **Step 1: Wire-level `scp:0` vs `scp:1` ICC presence**

Real `ImagePipe.call/2` requests; decode the body and inspect embedded ICC via `Vix.Vips.Image.header_value(_, "icc-profile-data")` (not headers): `scp:0` on a Display-P3 source carries a profile; `scp:1` does not. Assert `scp` option-order equivalence and cache reuse for equivalent requests.

- [ ] **Step 2: No-geometry + resize-only `scp:0` pixel test (required)**

Two request-boundary tests decoding the response body: (a) resize-only `rs:fit:200:200/scp:0` and (b) no-geometry `scp:0` on a wide-gamut source — assert the round-trip/gamut-clip behavioral change vs the pre-#124 untouched-source baseline (i.e. output differs from a plain source-space pass).

- [ ] **Step 3: Trim parity (wide-gamut + greyscale)**

Wide-gamut + `trim`: detected box matches imgproxy. Greyscale + `trim`: B_W working space, sRGB detection — box matches imgproxy.

- [ ] **Step 4: Cache key/ETag**

`:preserve_source` vs `:strip` produce different keys and ETags; cachebuster/vary unaffected.

- [ ] **Step 5: Edge cases**

CMYK `scp:0` → a profile-supporting format re-embeds (gated by `supports_color_profile?`); linear-light source drops + does not re-embed but still converts; finalize decode-error mapping on a corrupt source surfaces `{:decode, _}` → 415.

- [ ] **Step 6: Run the full suite, verify green**

Run: `mise exec -- mix test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add test/
git commit -m "test(imgproxy): #124 wire/behavioral/cache conformance for input color management"
```

---

## Task 11: Docs, demo verify, project rule, and the precommit gate

**Files:**
- Modify: `docs/imgproxy_support_matrix.md`
- Modify: `AGENTS.md` and `CLAUDE.md` (the project rule)
- Verify: `fiddle/`

- [ ] **Step 1: Update the support matrix**

Per spec §Docs: rewrite stage 4 (`colorspaceToProcessing`, ~line 82) and stage 16 (`colorspaceToResult`, ~101) ⚠️ → ✅; flip the Mermaid nodes (~47, ~54); remove the trim detection-colorspace divergence note (trim row ~80); update the "standing divergence" prose (~124); update **both** `scp` surface rows (~465, ~769), the stage-17 `stripMetadata` note (~102), and the "Metadata, color profile, …" prose (~443). Name the axes touched (surface + stage/order + behavioral/pixel).

- [ ] **Step 2: Add the project rule**

Add the "Distinguish discretionary operations from input conditioning" rule (spec §Project rule) to the Transform guidelines in **both** `AGENTS.md` and `CLAUDE.md`, with EXIF auto-orient + input color management as the worked examples.

- [ ] **Step 3: Verify the demo end-to-end**

The `scp` control already exists in `fiddle/` (`App.svelte`, `demo-url-state.ts`); the URL surface is unchanged. Run the fiddle verify suite and confirm `scp:0`/`scp:1` exercise the new policy end-to-end.

Run: `mise run precommit:demo`
Expected: PASS (Elixir gate + fiddle verify).

- [ ] **Step 4: Final gate**

Run: `mise run precommit`
Expected: format clean, compile warnings-as-errors clean, credo --strict clean, all tests pass.

- [ ] **Step 5: Commit**

```bash
git add docs/ AGENTS.md CLAUDE.md fiddle/
git commit -m "docs(imgproxy): #124 support-matrix + preamble project rule; demo verify"
```

---

## Notes for the implementer

- **Boundary discipline:** the working-space chooser lives in `Transform.*`; `supports_color_profile?` in `Format` (reachable from `Output`). They are on opposite sides of the transform→output boundary and must not share a module. The carry stamp lives in `Request.Processor` (Request boundary), never `Output`.
- **Three TDD-time API confirmations** (spec §De-risk): (1) `icc_export` has no blob target → restore the source blob onto `icc-profile-data` first, then export embedded; (2) `minimize_metadata` enumerate-removes the private fields → the finalize read-before-strip order is mandatory; (3) re-sniff PCS from the restored profile on export and take depth from the interpretation (`icc_import` has no depth knob).
- **Don't** emit `State` (which now holds raw ICC bytes) into telemetry metadata — confirmed today it isn't; keep it that way.
- **Idempotency:** `condition/2` short-circuits on `color_imported?: true`; seeding in `execute/3` runs it once.
