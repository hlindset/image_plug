# imgproxy Differential Pixel Conformance — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add pixel-level differential conformance testing that compares ImagePipe's decoded output against committed reference fixtures generated from a pinned real imgproxy container.

**Architecture:** Two decoupled artifacts. (1) Manually-run Mix tasks (`imgproxy.gen_sources`, `imgproxy.gen_fixtures`) spin up a pinned `darthsim/imgproxy` via testcontainers-elixir, transform committed synthetic sources, and write committed PNG fixtures + a provenance manifest + a human-readable report. (2) A fast default-lane ExUnit test re-runs the same transforms through `ImagePipe.Plug.call/2`, decodes both sides, and compares pixels with a count-based tolerance (transform group), a structured-divergence floor (`:diverges`), or a format/dimension contract (lossy group). A skew gate plus a CI guard keep the assertions honest across libvips versions.

**Tech Stack:** Elixir, ExUnit, the `Image`/`Vix` libvips wrappers (already deps), `Req` (already a dep, used to drive imgproxy over HTTP), `testcontainers` (new, env-gated test-only dep), Docker (manual generation only).

**Spec:** `docs/superpowers/specs/2026-06-10-imgproxy-differential-conformance-design.md`

---

## File Structure

| Path | Responsibility |
|------|----------------|
| `mix.exs` | Add the env-gated `:testcontainers` test dep. |
| `test/support/image_pipe/test/imgproxy_differential/pixel_compare.ex` | Pure pixel-comparison primitives: dimension equality, count-based outlier budget, region mean-delta. |
| `test/support/image_pipe/test/imgproxy_differential/manifest.ex` | Manifest encode/decode + load-time shape validation + authored-field and file hashing. |
| `test/support/image_pipe/test/imgproxy_differential/constellations.ex` | Canonical authored constellation list + shared imgproxy request-path builder (`use Boundary`). |
| `test/support/image_pipe/test/imgproxy_differential/skew.ex` | Runtime libvips read, manifest alignment check, CI detection. |
| `test/support/mix/tasks/imgproxy.gen_sources.ex` | One-shot source-image builder (no Docker). |
| `test/support/mix/tasks/imgproxy.gen_fixtures.ex` | Fixture generator (testcontainers; module defined only when dep present; `:test`-only). |
| `test/support/mix/tasks/imgproxy.reauthor.ex` | Docker-free manifest authored-hash refresh (tol/verdict-only edits). |
| `test/support/image_pipe/test/imgproxy_differential/sources/` | Committed synthetic source images + `.icc`. |
| `test/support/image_pipe/test/imgproxy_differential/fixtures/` | Committed reference PNGs. |
| `test/support/image_pipe/test/imgproxy_differential/manifest.exs` | Generated provenance (committed, git-diffable Elixir term). |
| `test/support/image_pipe/test/imgproxy_differential/REPORT.md` | Generated human-readable bump record (committed). |
| `test/image_pipe/imgproxy_differential_conformance_test.exs` | The default-lane comparison test + CI skew-guard. |
| `test/image_pipe/transform/.../*_test.exs` (new unit tests) | TDD coverage for the four support modules above. |
| `docs/imgproxy_support_matrix.md` | "Differential conformance" subsection. |
| `test/support/image_pipe/test/imgproxy_differential/README.md` | Contributor regeneration loop. |

**Naming/namespace conventions (locked):**
- Modules: `ImagePipe.Test.ImgproxyDifferential.{PixelCompare,Manifest,Constellations,Skew}`.
- Mix tasks: `Mix.Tasks.Imgproxy.GenSources`, `Mix.Tasks.Imgproxy.GenFixtures`, `Mix.Tasks.Imgproxy.Reauthor` — under `test/support/mix/tasks/`, so they compile only in `:test` and never enter the `:dev`/`:prod` compile or the hex package.
- Run generation with `MIX_ENV=test IMGPROXY_DIFF=1 mise exec -- mix imgproxy.gen_fixtures`.
- Always run repo commands via `mise exec -- ...`.

---

## Task 1: Add the env-gated testcontainers dependency

**Files:**
- Modify: `mix.exs` (the `defp deps` function, near the existing `IMAGE_VISION` conditional block)

- [ ] **Step 1: Read the existing conditional-dep pattern**

Run: `mise exec -- grep -n "IMAGE_VISION" mix.exs`
Expected: shows the `if System.get_env("IMAGE_VISION") in ["1", "true"]` block that conditionally appends `ml_test_deps` to `base`.

- [ ] **Step 2: Add the testcontainers conditional dep**

In `mix.exs`, immediately after the `ml_test_deps = if System.get_env("IMAGE_VISION") ... end` block and before `base ++ ml_test_deps`, add a parallel block, and extend the final concatenation:

```elixir
    imgproxy_diff_deps =
      if System.get_env("IMGPROXY_DIFF") in ["1", "true"] do
        [{:testcontainers, "~> 1.14", only: :test, runtime: false}]
      else
        []
      end

    base ++ ml_test_deps ++ imgproxy_diff_deps
```

(Replace the existing `base ++ ml_test_deps` tail with `base ++ ml_test_deps ++ imgproxy_diff_deps`.)

- [ ] **Step 3: Verify the default build still compiles clean WITHOUT the dep (acceptance criterion)**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: compiles with no warnings; `:testcontainers` is absent from the dev dep tree.

Run: `MIX_ENV=test mise exec -- mix compile --warnings-as-errors`
Expected: compiles clean; `:testcontainers` absent (IMGPROXY_DIFF unset), and no undefined-module warnings (the generator task module is guarded — added in Task 7).

- [ ] **Step 4: Verify the dep resolves WHEN gated on**

Run: `IMGPROXY_DIFF=1 mise exec -- mix deps.get`
Expected: fetches `testcontainers` and its transitive deps.

Run: `IMGPROXY_DIFF=1 MIX_ENV=test mise exec -- mix compile --warnings-as-errors`
Expected: compiles clean with the dep present.

- [ ] **Step 5: Commit**

```bash
git add mix.exs mix.lock
git commit -m "feat(test): add env-gated testcontainers dep for imgproxy differential conformance"
```

---

## Task 2: PixelCompare — pure comparison primitives

**Files:**
- Create: `test/support/image_pipe/test/imgproxy_differential/pixel_compare.ex`
- Test: `test/image_pipe/imgproxy_differential/pixel_compare_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/image_pipe/imgproxy_differential/pixel_compare_test.exs
defmodule ImagePipe.Test.ImgproxyDifferential.PixelCompareTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Test.ImgproxyDifferential.PixelCompare

  defp img(w, h, color), do: Image.new!(w, h, color: color)

  describe "dims/1" do
    test "returns width and height" do
      assert PixelCompare.dims(img(7, 3, :black)) == {7, 3}
    end
  end

  describe "same_dims?/2" do
    test "true for equal dims, false otherwise" do
      assert PixelCompare.same_dims?(img(4, 4, :black), img(4, 4, :white))
      refute PixelCompare.same_dims?(img(4, 4, :black), img(5, 4, :white))
    end
  end

  describe "outliers/3" do
    test "identical images have zero outliers" do
      a = img(16, 16, [10, 20, 30])
      assert PixelCompare.outliers(a, a, 0) == 0
    end

    test "a uniform per-channel offset below threshold is not an outlier" do
      a = img(16, 16, [10, 20, 30])
      b = img(16, 16, [12, 22, 32])
      assert PixelCompare.outliers(a, b, 2) == 0
      # 16x16 pixels x 3 bands; every band-byte exceeds Δ1 here.
      assert PixelCompare.outliers(a, b, 1) == 16 * 16 * 3
    end

    test "raises on mismatched dims" do
      assert_raise ArgumentError, fn ->
        PixelCompare.outliers(img(4, 4, :black), img(5, 4, :black), 0)
      end
    end
  end

  describe "region_mean_delta/3" do
    test "mean absolute per-channel delta over a region equals a uniform offset" do
      a = img(32, 32, [40, 40, 40])
      b = img(32, 32, [46, 46, 46])
      assert_in_delta PixelCompare.region_mean_delta(a, b, {8, 8, 16, 16}), 6.0, 0.001
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/imgproxy_differential/pixel_compare_test.exs`
Expected: FAIL — `ImagePipe.Test.ImgproxyDifferential.PixelCompare` is undefined.

- [ ] **Step 3: Implement the module**

```elixir
# test/support/image_pipe/test/imgproxy_differential/pixel_compare.ex
defmodule ImagePipe.Test.ImgproxyDifferential.PixelCompare do
  @moduledoc """
  Pure pixel-comparison primitives for the imgproxy differential conformance
  harness. Operates on decoded `Vix.Vips.Image` structs. Each band is read once
  to a raw row-major buffer (`write_to_binary/1`) and indexed in the BEAM, so a
  full-frame comparison costs two FFI reads instead of per-pixel FFI calls.
  """

  alias Vix.Vips.Image, as: VipsImage

  @spec dims(VipsImage.t()) :: {pos_integer(), pos_integer()}
  def dims(image), do: {Image.width(image), Image.height(image)}

  @spec same_dims?(VipsImage.t(), VipsImage.t()) :: boolean()
  def same_dims?(a, b), do: dims(a) == dims(b)

  @doc """
  Count of band-bytes whose absolute delta exceeds `threshold` (band-byte counting
  upper-bounds pixel outliers — the stricter choice). Raises `ArgumentError` if the
  two images differ in dimensions or band layout.
  """
  @spec outliers(VipsImage.t(), VipsImage.t(), non_neg_integer()) :: non_neg_integer()
  def outliers(a, b, threshold) do
    unless same_dims?(a, b) do
      raise ArgumentError, "dimension mismatch: #{inspect(dims(a))} vs #{inspect(dims(b))}"
    end

    {:ok, ab} = VipsImage.write_to_binary(a)
    {:ok, bb} = VipsImage.write_to_binary(b)

    unless byte_size(ab) == byte_size(bb) do
      raise ArgumentError, "band layout mismatch: #{byte_size(ab)} vs #{byte_size(bb)}"
    end

    count_outliers(ab, bb, threshold, 0)
  end

  @doc """
  Mean absolute per-channel delta over the `{left, top, width, height}` region.
  """
  @spec region_mean_delta(VipsImage.t(), VipsImage.t(), {integer, integer, pos_integer, pos_integer}) ::
          float()
  def region_mean_delta(a, b, {left, top, width, height}) do
    {:ok, ra} = Image.crop(a, left, top, width, height)
    {:ok, rb} = Image.crop(b, left, top, width, height)
    {:ok, ab} = VipsImage.write_to_binary(ra)
    {:ok, bb} = VipsImage.write_to_binary(rb)
    {sum, n} = sum_abs_delta(ab, bb, 0, 0)
    if n == 0, do: 0.0, else: sum / n
  end

  # Counts band-bytes (not pixels) whose absolute delta exceeds the threshold.
  # Band-byte counting upper-bounds pixel outliers — the stricter choice — and
  # avoids needing the band count here.
  defp count_outliers(<<>>, <<>>, _t, acc), do: acc

  defp count_outliers(<<av, arest::binary>>, <<bv, brest::binary>>, t, acc) do
    acc = if abs(av - bv) > t, do: acc + 1, else: acc
    count_outliers(arest, brest, t, acc)
  end

  defp sum_abs_delta(<<>>, <<>>, sum, n), do: {sum, n}

  defp sum_abs_delta(<<av, arest::binary>>, <<bv, brest::binary>>, sum, n) do
    sum_abs_delta(arest, brest, sum + abs(av - bv), n + 1)
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/imgproxy_differential/pixel_compare_test.exs`
Expected: PASS (all cases).

- [ ] **Step 5: Commit**

```bash
git add test/support/image_pipe/test/imgproxy_differential/pixel_compare.ex \
        test/image_pipe/imgproxy_differential/pixel_compare_test.exs
git commit -m "feat(test): pixel-compare primitives for differential conformance"
```

---

## Task 3: Manifest — encode, validate, hash

**Files:**
- Create: `test/support/image_pipe/test/imgproxy_differential/manifest.ex`
- Test: `test/image_pipe/imgproxy_differential/manifest_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/image_pipe/imgproxy_differential/manifest_test.exs
defmodule ImagePipe.Test.ImgproxyDifferential.ManifestTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias ImagePipe.Test.ImgproxyDifferential.Manifest

  @sample %{
    imgproxy_digest: "sha256:abc",
    imgproxy_libvips: "8.18.2",
    pipe_libvips_at_gen: "8.18.2",
    sources: %{"high_freq.jpg" => "deadbeef"},
    entries: %{
      "rs_fill" => %{
        kind: :transform,
        authored_sha256: "aaa",
        fixture_filename: "rs_fill.png",
        fixture_sha256: "bbb"
      },
      "lossy_webp" => %{
        kind: :lossy,
        authored_sha256: "ccc",
        width: 240,
        height: 180,
        content_type: "image/webp"
      }
    }
  }

  test "round-trips through encode/decode", %{tmp_dir: tmp} do
    path = Path.join(tmp, "manifest.exs")
    Manifest.write!(path, @sample)
    assert Manifest.load!(path) == @sample
  end

  test "load! rejects a malformed manifest with a clear error", %{tmp_dir: tmp} do
    path = Path.join(tmp, "bad.exs")
    File.write!(path, "%{not: :a_manifest}")
    assert_raise RuntimeError, ~r/invalid manifest/i, fn -> Manifest.load!(path) end
  end

  test "authored_sha256 is stable and order-independent over authored fields" do
    a = %{source: :high_freq, opts: "rs:fill:240:180", verdict: :equal, group: :transform, tol: nil, divergence: nil}
    b = %{group: :transform, verdict: :equal, opts: "rs:fill:240:180", source: :high_freq, divergence: nil, tol: nil}
    assert Manifest.authored_sha256(a) == Manifest.authored_sha256(b)
  end

  test "authored_sha256 changes when an authored field changes" do
    a = %{source: :high_freq, opts: "rs:fill:240:180", verdict: :equal, group: :transform, tol: nil, divergence: nil}
    b = %{a | verdict: :diverges}
    refute Manifest.authored_sha256(a) == Manifest.authored_sha256(b)
  end

  test "file_sha256 hashes file bytes", %{tmp_dir: tmp} do
    path = Path.join(tmp, "bytes.bin")
    File.write!(path, "hello")
    expected = :crypto.hash(:sha256, "hello") |> Base.encode16(case: :lower)
    assert Manifest.file_sha256(path) == expected
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/imgproxy_differential/manifest_test.exs`
Expected: FAIL — `Manifest` is undefined.

- [ ] **Step 3: Implement the module**

```elixir
# test/support/image_pipe/test/imgproxy_differential/manifest.ex
defmodule ImagePipe.Test.ImgproxyDifferential.Manifest do
  @moduledoc """
  Generated provenance for the imgproxy differential harness. Stored as a
  git-diffable Elixir term (`manifest.exs`). The manifest is machine-only
  (REPORT.md is the human-readable record); it is data crossing a serialization
  boundary, so `load!/1` validates shape and fails loudly on anything malformed.
  """

  @authored_keys [:source, :opts, :verdict, :group, :tol, :divergence]

  @doc "Pretty-print the manifest term to `path`."
  @spec write!(Path.t(), map()) :: :ok
  def write!(path, %{} = manifest) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, inspect(manifest, pretty: true, limit: :infinity, printable_limit: :infinity) <> "\n")
  end

  @doc "Load and validate a manifest term from `path`."
  @spec load!(Path.t()) :: map()
  def load!(path) do
    {term, _binding} = Code.eval_file(path)
    validate!(term)
  end

  defp validate!(%{
         imgproxy_digest: d,
         imgproxy_libvips: l,
         pipe_libvips_at_gen: p,
         sources: sources,
         entries: entries
       } = m)
       when is_binary(d) and is_binary(l) and is_binary(p) and is_map(sources) and is_map(entries) do
    Enum.each(entries, fn {id, entry} -> validate_entry!(id, entry) end)
    m
  end

  defp validate!(other) do
    raise "invalid manifest: missing required top-level keys in #{inspect(other, limit: 5)}"
  end

  defp validate_entry!(_id, %{kind: :transform, authored_sha256: a, fixture_filename: f, fixture_sha256: fs})
       when is_binary(a) and is_binary(f) and is_binary(fs),
       do: :ok

  defp validate_entry!(_id, %{kind: :lossy, authored_sha256: a, width: w, height: h, content_type: ct})
       when is_binary(a) and is_integer(w) and is_integer(h) and is_binary(ct),
       do: :ok

  defp validate_entry!(id, entry) do
    raise "invalid manifest: entry #{inspect(id)} is malformed: #{inspect(entry)}"
  end

  @doc "Stable, field-order-independent hash of a constellation's authored fields."
  @spec authored_sha256(map()) :: String.t()
  def authored_sha256(constellation) do
    canonical =
      @authored_keys
      |> Enum.map(fn k -> {k, Map.get(constellation, k)} end)

    :crypto.hash(:sha256, :erlang.term_to_binary(canonical)) |> Base.encode16(case: :lower)
  end

  @doc "SHA-256 (lowercase hex) of a file's bytes."
  @spec file_sha256(Path.t()) :: String.t()
  def file_sha256(path) do
    :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/imgproxy_differential/manifest_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add test/support/image_pipe/test/imgproxy_differential/manifest.ex \
        test/image_pipe/imgproxy_differential/manifest_test.exs
git commit -m "feat(test): manifest encode/validate/hash for differential conformance"
```

---

## Task 4: Constellations — canonical list + shared request path

**Files:**
- Create: `test/support/image_pipe/test/imgproxy_differential/constellations.ex`
- Test: `test/image_pipe/imgproxy_differential/constellations_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/image_pipe/imgproxy_differential/constellations_test.exs
defmodule ImagePipe.Test.ImgproxyDifferential.ConstellationsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Test.ImgproxyDifferential.Constellations

  @valid_sources [:high_freq, :high_freq_webp, :marker, :border, :alpha, :exif_jpeg, :icc_p3, :small]

  test "every constellation is well-formed" do
    for c <- Constellations.all() do
      assert is_binary(c.id) and c.id != ""
      assert c.source in @valid_sources
      assert is_binary(c.opts)
      assert c.verdict in [:equal, :diverges]
      assert c.group in [:transform, :lossy]
      assert match?(nil, c.tol) or is_map(c.tol)
      if c.verdict == :diverges do
        assert is_map(c.divergence), "diverges row #{c.id} must declare a divergence metric"
      end
    end
  end

  test "ids are unique" do
    ids = Enum.map(Constellations.all(), & &1.id)
    assert ids == Enum.uniq(ids)
  end

  test "imgproxy_path builds an unsafe processing path ending in the local source" do
    c = %{id: "x", source: :high_freq, opts: "rs:fill:240:180", verdict: :equal, group: :transform, tol: nil, divergence: nil}
    path = Constellations.imgproxy_path(c)
    assert path =~ "/unsafe/"
    assert path =~ "rs:fill:240:180"
    assert path =~ "f:png"
    assert String.ends_with?(path, "plain/local:///high_freq.jpg")
  end

  test "imgproxy_path for a lossy constellation keeps the requested format and source ext" do
    c = %{id: "y", source: :high_freq_webp, opts: "rs:fill:240:180/f:webp", verdict: :equal, group: :lossy, tol: nil, divergence: nil}
    path = Constellations.imgproxy_path(c)
    assert path =~ "f:webp"
    refute path =~ "f:png"
    assert String.ends_with?(path, "plain/local:///high_freq.webp")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/imgproxy_differential/constellations_test.exs`
Expected: FAIL — `Constellations` undefined.

- [ ] **Step 3: Implement the module**

```elixir
# test/support/image_pipe/test/imgproxy_differential/constellations.ex
defmodule ImagePipe.Test.ImgproxyDifferential.Constellations do
  @moduledoc """
  The canonical, authored constellation list for the imgproxy differential
  conformance harness. Imported by BOTH the generator Mix task and the comparison
  test, so the two cannot drift. Each entry is authored intent; provenance lives
  in the generated manifest, joined by `:id`.
  """

  use Boundary, top_level?: true, deps: []

  @source_files %{
    high_freq: "high_freq.jpg",
    high_freq_webp: "high_freq.webp",
    marker: "marker.png",
    border: "border.png",
    alpha: "alpha.png",
    exif_jpeg: "exif.jpg",
    icc_p3: "icc_p3.png",
    small: "small.png"
  }

  @doc "Map of `source` atom -> committed source filename."
  def source_files, do: @source_files

  @doc "The authored constellation list."
  def all do
    [
      # --- transform group: :equal (PNG output, pixel comparison) ---
      c("rs_fill_zone", :high_freq, "rs:fill:240:180/g:ce"),
      c("rs_fit_zone", :high_freq, "rs:fit:300:300"),
      c("rs_fill_zone_q4", :high_freq, "rs:fill:200:150"),
      c("rs_fill_webp_residual", :high_freq_webp, "rs:fill:233:151"),
      c("crop_gravity_marker", :marker, "c:120:90/g:nowe"),
      c("trim_border_equal", :border, "t:10"),
      c("alpha_resize", :alpha, "rs:fit:64:64"),
      c("rotate_exif", :exif_jpeg, "rs:fit:120:120"),
      c("enlarge_small", :small, "rs:fit:400:400/el:1"),
      c("min_dims_clamp", :high_freq, "rs:fit:300:300/mw:280/mh:280"),
      c("zoom_marker", :marker, "z:0.5"),
      c("fill_down_marker", :marker, "rs:fill-down:500:500"),
      c("gravity_offset_marker", :marker, "rs:fill:120:120/g:no:10:20"),
      c("padding_border", :border, "rs:fit:120:120/pd:10:20"),
      c("extend_small", :small, "rs:fit:300:200/ex:1"),
      c("extend_ar_small", :small, "rs:fit:300:200/exar:1"),
      c("dpr_marker", :marker, "rs:fit:80:80/dpr:2"),
      c("background_alpha", :alpha, "rs:fit:64:64/bg:255:0:0"),
      c("blur_zone", :high_freq, "rs:fit:240:240/bl:3"),
      c("sharpen_zone", :high_freq, "rs:fit:240:240/sh:2"),
      c("strip_exif", :exif_jpeg, "rs:fit:120:120/sm:1"),

      # --- :diverges (structured metric, not skew-gated) ---
      # scp:0 alone: ImagePipe skips the P3→sRGB conversion while imgproxy always
      # imports to the working space, so a flat saturated-P3 patch diverges
      # systematically. NO tone op — `sa`/saturation is imgproxy Pro-only and would
      # 404 on darthsim non-pro. Re-validate the floor against the real fixture.
      diverge(
        "scp0_colorspace_124",
        :icc_p3,
        "rs:fit:200:200/scp:0",
        %{metric: :region_mean_delta, region: {40, 40, 80, 80}, floor: 4.0, issue: "#124"}
      ),
      diverge(
        "trim_detection_space",
        :icc_p3,
        "t:10",
        %{metric: :region_mean_delta, region: {0, 0, 32, 32}, floor: 3.0, issue: "#124 (trim detection)"}
      ),

      # --- lossy group: contract-only (dims/content-type/decode), no pixel claim ---
      lossy("lossy_webp", :high_freq_webp, "rs:fill:240:180/f:webp"),
      lossy("lossy_jpeg_q40", :high_freq, "rs:fill:240:180/q:40/f:jpg"),
      lossy("lossy_avif", :high_freq, "rs:fill:240:180/f:avif")
    ]
  end

  @doc """
  The imgproxy request path for a constellation, shared by the generator and the
  test so they cannot diverge. Transform-group requests force `f:png` (lossless,
  isolates transform pixels); lossy-group requests keep the format in `opts`.
  """
  def imgproxy_path(%{group: group, opts: opts, source: source}) do
    opts_segment = if group == :transform, do: "#{opts}/f:png", else: opts
    "/unsafe/#{opts_segment}/plain/local:///#{Map.fetch!(@source_files, source)}"
  end

  defp c(id, source, opts),
    do: %{id: id, source: source, opts: opts, verdict: :equal, group: :transform, tol: nil, divergence: nil}

  defp diverge(id, source, opts, divergence),
    do: %{id: id, source: source, opts: opts, verdict: :diverges, group: :transform, tol: nil, divergence: divergence}

  defp lossy(id, source, opts),
    do: %{id: id, source: source, opts: opts, verdict: :equal, group: :lossy, tol: nil, divergence: nil}
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/imgproxy_differential/constellations_test.exs`
Expected: PASS.

- [ ] **Step 5: Verify the Boundary declaration compiles**

Run: `MIX_ENV=test mise exec -- mix compile --warnings-as-errors`
Expected: clean (no boundary violations; the module declares `deps: []`).

- [ ] **Step 6: Commit**

```bash
git add test/support/image_pipe/test/imgproxy_differential/constellations.ex \
        test/image_pipe/imgproxy_differential/constellations_test.exs
git commit -m "feat(test): canonical constellation list + shared imgproxy request path"
```

---

## Task 5: Skew — libvips alignment + CI detection

**Files:**
- Create: `test/support/image_pipe/test/imgproxy_differential/skew.ex`
- Test: `test/image_pipe/imgproxy_differential/skew_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/image_pipe/imgproxy_differential/skew_test.exs
defmodule ImagePipe.Test.ImgproxyDifferential.SkewTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Test.ImgproxyDifferential.Skew

  test "runtime_libvips returns the Vix libvips version string" do
    assert Skew.runtime_libvips() == Vix.Vips.version()
  end

  test "aligned? compares runtime libvips against a manifest's recorded version" do
    assert Skew.aligned?(%{imgproxy_libvips: Vix.Vips.version()})
    refute Skew.aligned?(%{imgproxy_libvips: "0.0.0-not-a-real-version"})
  end

  test "ci? reflects the CI env var" do
    assert Skew.ci?(%{"CI" => "true"})
    assert Skew.ci?(%{"CI" => "1"})
    refute Skew.ci?(%{})
    refute Skew.ci?(%{"CI" => ""})
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/imgproxy_differential/skew_test.exs`
Expected: FAIL — `Skew` undefined.

- [ ] **Step 3: Implement the module**

```elixir
# test/support/image_pipe/test/imgproxy_differential/skew.ex
defmodule ImagePipe.Test.ImgproxyDifferential.Skew do
  @moduledoc """
  libvips skew detection for the differential harness. The committed fixtures were
  baked by `manifest.imgproxy_libvips`; the pixel premise ("same kernels →
  near-exact") only holds when ImagePipe runs that exact version. Exact-match
  because resampling kernels can change on a patch bump.
  """

  @doc "ImagePipe's runtime libvips version."
  @spec runtime_libvips() :: String.t()
  def runtime_libvips, do: Vix.Vips.version()

  @doc "True when runtime libvips exactly matches the manifest's recorded version."
  @spec aligned?(map()) :: boolean()
  def aligned?(%{imgproxy_libvips: version}), do: runtime_libvips() == version

  @doc "True when running under CI (per the given env map; defaults to the system env)."
  @spec ci?(map()) :: boolean()
  def ci?(env \\ System.get_env()), do: Map.get(env, "CI", "") in ["1", "true", "TRUE"]
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/imgproxy_differential/skew_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add test/support/image_pipe/test/imgproxy_differential/skew.ex \
        test/image_pipe/imgproxy_differential/skew_test.exs
git commit -m "feat(test): libvips skew + CI detection for differential conformance"
```

---

## Task 6: Source builder Mix task

**Files:**
- Create: `test/support/mix/tasks/imgproxy.gen_sources.ex`
- Test: `test/image_pipe/imgproxy_differential/gen_sources_test.exs`

The chirp pattern is computed deterministically in Elixir and loaded via
`Vix.Vips.Image.new_from_binary/5`, so it never depends on a libvips test-pattern op
and never changes with a libvips bump (the bytes are fixed once committed).

- [ ] **Step 1: Write the failing test (pure pattern function only)**

```elixir
# test/image_pipe/imgproxy_differential/gen_sources_test.exs
defmodule Mix.Tasks.Imgproxy.GenSourcesTest do
  use ExUnit.Case, async: true

  test "chirp_pixels/2 is deterministic and the right size (3 bands, uchar)" do
    a = Mix.Tasks.Imgproxy.GenSources.chirp_pixels(32, 24)
    b = Mix.Tasks.Imgproxy.GenSources.chirp_pixels(32, 24)
    assert a == b
    assert byte_size(a) == 32 * 24 * 3
  end

  test "chirp_pixels/2 varies spatially (not a flat image)" do
    bin = Mix.Tasks.Imgproxy.GenSources.chirp_pixels(64, 64)
    assert byte_size(bin) == 64 * 64 * 3
    refute bin == :binary.copy(<<:binary.at(bin, 0)>>, byte_size(bin))
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/imgproxy_differential/gen_sources_test.exs`
Expected: FAIL — task module undefined.

- [ ] **Step 3: Implement the task**

```elixir
# test/support/mix/tasks/imgproxy.gen_sources.ex
defmodule Mix.Tasks.Imgproxy.GenSources do
  @shortdoc "Build committed synthetic source images for imgproxy differential conformance"
  @moduledoc """
  One-shot builder for the committed source images. No Docker. Run once; commit
  the outputs. Regenerating sources is a deliberate act (a libvips bump must not
  silently change inputs).

      MIX_ENV=test mise exec -- mix imgproxy.gen_sources
  """
  use Mix.Task

  alias Vix.Vips.Image, as: VipsImage

  @dir "test/support/image_pipe/test/imgproxy_differential/sources"
  @w 1600
  @h 1200

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:image)
    File.mkdir_p!(@dir)

    chirp = chirp_image(@w, @h)
    write!(chirp, "high_freq.jpg", suffix: ".jpg", quality: 92)
    write!(chirp, "high_freq.webp", suffix: ".webp", quality: 92)

    marker =
      @w
      |> Image.new!(@h, color: [30, 30, 30])
      |> Image.Draw.rect!(div(@w, 8), div(@h, 8), div(@w, 6), div(@h, 6), color: [240, 40, 40])

    write!(marker, "marker.png", suffix: ".png")

    border =
      @w
      |> Image.new!(@h, color: [255, 255, 255])
      |> Image.Draw.rect!(120, 90, @w - 240, @h - 180, color: [20, 30, 200])

    write!(border, "border.png", suffix: ".png")

    {:ok, alpha} = Image.new(256, 256, color: [0, 200, 100, 128], bands: 4)
    write!(alpha, "alpha.png", suffix: ".png")

    exif =
      400
      |> Image.new!(300, color: [200, 180, 60])
      |> Image.Draw.rect!(0, 0, 200, 150, color: [40, 40, 200])
      |> Image.set_orientation!(6)

    write!(exif, "exif.jpg", suffix: ".jpg", quality: 95)

    icc =
      512
      |> Image.new!(512, color: [200, 50, 50])
      |> Image.Draw.rect!(0, 0, 64, 64, color: [255, 255, 255])
      |> Image.Draw.rect!(256, 0, 6, 512, color: [0, 255, 0])
      |> Image.Draw.rect!(0, 256, 512, 6, color: [0, 0, 255])

    {:ok, p3} = Image.to_colorspace(icc, :p3, [])
    write!(p3, "icc_p3.png", suffix: ".png")

    small =
      120
      |> Image.new!(90, color: [70, 130, 180])
      |> Image.Draw.rect!(10, 10, 40, 30, color: [255, 220, 0])

    write!(small, "small.png", suffix: ".png")

    Mix.shell().info("Wrote sources to #{@dir}")
  end

  @doc "Deterministic radial-chirp pixel buffer: `w*h*3` uchar bytes, row-major."
  def chirp_pixels(w, h) do
    cx = w / 2
    cy = h / 2
    k = 0.00025

    # Build an iolist then flatten once — avoids O(n^2) binary re-copy that a
    # `for … into: <<>>` accumulation incurs over millions of pixels.
    for y <- 0..(h - 1) do
      for x <- 0..(w - 1) do
        dx = x - cx
        dy = y - cy
        v = trunc(127.5 * (1.0 + :math.cos(k * (dx * dx + dy * dy))))
        <<v, v, v>>
      end
    end
    |> IO.iodata_to_binary()
  end

  defp chirp_image(w, h) do
    {:ok, img} = VipsImage.new_from_binary(chirp_pixels(w, h), w, h, 3, :VIPS_FORMAT_UCHAR)
    img
  end

  defp write!(image, filename, opts) do
    body = Image.write!(image, :memory, opts)
    File.write!(Path.join(@dir, filename), body)
  end
end
```

- [ ] **Step 4: Run the pure-function test**

Run: `mise exec -- mix test test/image_pipe/imgproxy_differential/gen_sources_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the task to actually build the sources**

Run: `MIX_ENV=test mise exec -- mix imgproxy.gen_sources`
Expected: prints `Wrote sources to …`; eight files appear under the sources dir.

Run: `ls -1 test/support/image_pipe/test/imgproxy_differential/sources/`
Expected: `alpha.png border.png exif.jpg high_freq.jpg high_freq.webp icc_p3.png marker.png small.png`

- [ ] **Step 6: Sanity-check a couple of sources decode and carry expected properties**

Run:
```bash
MIX_ENV=test mise exec -- mix run -e '
  d = "test/support/image_pipe/test/imgproxy_differential/sources"
  img = Image.open!(Path.join(d, "icc_p3.png"))
  {:ok, fields} = Vix.Vips.Image.header_field_names(img)
  IO.inspect("icc-profile-data" in fields, label: "icc present")
  exif = Image.open!(Path.join(d, "exif.jpg"))
  IO.inspect(Image.exif(exif), label: "exif")
'
```
Expected: `icc present: true`; EXIF map shows orientation 6.

- [ ] **Step 7: Commit the task and the committed sources**

```bash
git add test/support/mix/tasks/imgproxy.gen_sources.ex \
        test/image_pipe/imgproxy_differential/gen_sources_test.exs \
        test/support/image_pipe/test/imgproxy_differential/sources/
git commit -m "feat(test): synthetic source builder + committed sources for differential conformance"
```

---

## Task 7: Fixture generator + reauthor Mix tasks

**Files:**
- Create: `test/support/mix/tasks/imgproxy.gen_fixtures.ex`
- Create: `test/support/mix/tasks/imgproxy.reauthor.ex`

Both tasks live under `test/support/mix/tasks/`, so they compile **only in `:test`**
(`elixirc_paths(:test)` includes `test/support`) and never touch the `:dev`/`:prod`
compile, the precommit `mix compile`, or the hex package. The generator additionally
references `:testcontainers`, which is absent from a plain `mix test` (IMGPROXY_DIFF
unset) — so its module is wrapped in a **file-level `if Code.ensure_loaded?(Testcontainers)`
guard**: when the dep is absent the module is simply not defined, so the `:test`
compile has no dangling reference and emits no warning. The reauthor task needs no
container and is always defined.

There is no failing-test-first step here: the generator is a Docker-driven manual
script (the spec classifies it as off the hot path), and its compile-safety contract
is enforced by the compile commands in Step 3 and Task 1 Step 3 — **not** by an
ExUnit existence assertion (which the repo's "Tests not to write" rule forbids).

- [ ] **Step 1: Implement the guarded generator task**

```elixir
# test/support/mix/tasks/imgproxy.gen_fixtures.ex
if Code.ensure_loaded?(Testcontainers) do
  defmodule Mix.Tasks.Imgproxy.GenFixtures do
    @shortdoc "Generate imgproxy differential reference fixtures from a pinned container"
    @moduledoc """
    Spins up a pinned `darthsim/imgproxy` via testcontainers, transforms the
    committed sources for every constellation, and writes committed PNG fixtures,
    `manifest.exs`, and `REPORT.md`. Requires Docker.

        MIX_ENV=test IMGPROXY_DIFF=1 mise exec -- mix imgproxy.gen_fixtures
    """
    use Mix.Task

    alias ImagePipe.Test.ImgproxyDifferential.{Constellations, Manifest}

    @image "darthsim/imgproxy@sha256:REPLACE_WITH_PINNED_DIGEST"
    @base "test/support/image_pipe/test/imgproxy_differential"
    @sources_dir "#{@base}/sources"
    @fixtures_dir "#{@base}/fixtures"
    @manifest_path "#{@base}/manifest.exs"
    @report_path "#{@base}/REPORT.md"

    @impl Mix.Task
    def run(_args) do
      {:ok, _} = Application.ensure_all_started(:image)
      {:ok, _} = Application.ensure_all_started(:req)
      {:ok, _} = Testcontainers.start_link()
      File.mkdir_p!(@fixtures_dir)

      # Signature checking is OFF whenever no IMGPROXY_KEY/SALT are set, which lets
      # the `/unsafe/` prefix work. LOCAL_FILESYSTEM_ROOT + a read-only bind serve
      # the committed sources via `local:///<file>`.
      container =
        Testcontainers.Container.new(@image)
        |> Testcontainers.Container.with_exposed_port(8080)
        |> Testcontainers.Container.with_environment("IMGPROXY_LOCAL_FILESYSTEM_ROOT", "/srv")
        |> Testcontainers.Container.with_bind_mount(Path.expand(@sources_dir), "/srv", "ro")

      {:ok, started} = Testcontainers.start_container(container)
      port = Testcontainers.Container.mapped_port(started, 8080)
      base_url = "http://localhost:#{port}"

      wait_until_ready!(base_url)

      imgproxy_libvips = container_libvips(started)
      pipe_libvips = Vix.Vips.version()

      if imgproxy_libvips != pipe_libvips do
        Mix.shell().info(
          "WARNING: imgproxy libvips #{imgproxy_libvips} != ImagePipe libvips #{pipe_libvips}; " <>
            "generation-time validation is not truly same-kernel."
        )
      end

      source_hashes =
        Constellations.source_files()
        |> Map.values()
        |> Map.new(fn f -> {f, Manifest.file_sha256(Path.join(@sources_dir, f))} end)

      entries =
        Constellations.all()
        |> Map.new(fn c -> {c.id, generate_entry(c, base_url)} end)

      manifest = %{
        imgproxy_digest: @image |> String.split("@") |> List.last(),
        imgproxy_libvips: imgproxy_libvips,
        pipe_libvips_at_gen: pipe_libvips,
        sources: source_hashes,
        entries: entries
      }

      Manifest.write!(@manifest_path, manifest)
      write_report!(manifest)
      Mix.shell().info("Wrote #{map_size(entries)} fixtures + manifest + report under #{@base}")
    end

    defp generate_entry(c, base_url) do
      url = base_url <> Constellations.imgproxy_path(c)
      %Req.Response{status: 200, body: body} = resp = Req.get!(url, decode_body: false)
      content_type = resp |> Req.Response.get_header("content-type") |> List.first()
      decoded = Image.open!(body, access: :random, fail_on: :error)

      authored = Manifest.authored_sha256(c)

      case c.group do
        :transform ->
          filename = "#{c.id}.png"
          png = Image.write!(decoded, :memory, suffix: ".png")
          File.write!(Path.join(@fixtures_dir, filename), png)

          %{
            kind: :transform,
            authored_sha256: authored,
            fixture_filename: filename,
            fixture_sha256: Manifest.file_sha256(Path.join(@fixtures_dir, filename))
          }

        :lossy ->
          %{
            kind: :lossy,
            authored_sha256: authored,
            width: Image.width(decoded),
            height: Image.height(decoded),
            content_type: content_type
          }
      end
    end

    defp wait_until_ready!(base_url, attempts \\ 60)

    defp wait_until_ready!(_base_url, 0), do: Mix.raise("imgproxy container did not become ready")

    defp wait_until_ready!(base_url, attempts) do
      case Req.get(base_url <> "/health", retry: false) do
        {:ok, %Req.Response{status: 200}} ->
          :ok

        _ ->
          Process.sleep(500)
          wait_until_ready!(base_url, attempts - 1)
      end
    end

    # imgproxy does NOT expose its libvips version over HTTP; read it from inside
    # the container. The darthsim image ships the `vips` CLI, which prints e.g.
    # "vips-8.16.0".
    defp container_libvips(started) do
      {out, 0} = System.cmd("docker", ["exec", started.container_id, "vips", "--version"])
      out |> String.trim() |> String.replace_prefix("vips-", "")
    end

    defp write_report!(manifest) do
      lines =
        manifest.entries
        |> Enum.sort_by(fn {id, _} -> id end)
        |> Enum.map(fn {id, e} -> "- `#{id}` — #{e.kind}" end)

      body = """
      # imgproxy differential conformance — generation report

      - imgproxy digest: `#{manifest.imgproxy_digest}`
      - imgproxy libvips: `#{manifest.imgproxy_libvips}`
      - ImagePipe libvips at generation: `#{manifest.pipe_libvips_at_gen}`

      ## Constellations

      #{Enum.join(lines, "\n")}
      """

      File.write!(@report_path, body)
    end
  end
end
```

> **Bootstrap-time confirmation (Docker required, container-surface only):** on the
> first run confirm against the pinned image (a) the `/health` readiness contract,
> (b) that `started.container_id` is the testcontainers field holding the Docker id
> (adjust if the struct names it differently), and (c) the `vips --version` output
> shape. These cannot be verified without Docker present.

- [ ] **Step 2: Implement the Docker-free reauthor task**

This refreshes the manifest's `authored_sha256` values from the current
`constellations.ex` **without** re-running the container — for `tol` tweaks and
`:diverges`→`:equal` verdict flips, which change authored fields but not fixture
bytes. It needs no testcontainers, so it is always defined.

```elixir
# test/support/mix/tasks/imgproxy.reauthor.ex
defmodule Mix.Tasks.Imgproxy.Reauthor do
  @shortdoc "Refresh manifest authored-field hashes without re-running imgproxy"
  @moduledoc """
  Recomputes `authored_sha256` for every constellation from `constellations.ex`
  and rewrites the manifest, leaving fixtures and REPORT untouched. Use after a
  `tol` tweak or a `:diverges`→`:equal` verdict flip (no pixels change).

      MIX_ENV=test mise exec -- mix imgproxy.reauthor
  """
  use Mix.Task

  alias ImagePipe.Test.ImgproxyDifferential.{Constellations, Manifest}

  @manifest_path "test/support/image_pipe/test/imgproxy_differential/manifest.exs"

  @impl Mix.Task
  def run(_args) do
    manifest = Manifest.load!(@manifest_path)
    by_id = Map.new(Constellations.all(), fn c -> {c.id, c} end)

    entries =
      Map.new(manifest.entries, fn {id, entry} ->
        {id, %{entry | authored_sha256: Manifest.authored_sha256(Map.fetch!(by_id, id))}}
      end)

    Manifest.write!(@manifest_path, %{manifest | entries: entries})
    Mix.shell().info("Reauthored #{map_size(entries)} manifest entries")
  end
end
```

- [ ] **Step 3: Confirm the compile-safety acceptance criterion (no Docker)**

Run: `MIX_ENV=test mise exec -- mix compile --warnings-as-errors`
Expected: clean. The generator module is not defined (no `:testcontainers`), so there
is no dangling reference; the reauthor task compiles fine.

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean (dev compile never sees `test/support`).

- [ ] **Step 4: Pin the digest, then BOOTSTRAP-generate fixtures (requires Docker)**

Find the current `darthsim/imgproxy` digest and replace `REPLACE_WITH_PINNED_DIGEST`:
```bash
docker pull darthsim/imgproxy:latest
docker inspect --format='{{index .RepoDigests 0}}' darthsim/imgproxy:latest
```
Put the `sha256:…` into `@image` in `imgproxy.gen_fixtures.ex`.

Run: `MIX_ENV=test IMGPROXY_DIFF=1 mise exec -- mix imgproxy.gen_fixtures`
Expected: prints the fixture/manifest/report summary; `fixtures/` fills with PNGs;
`manifest.exs` and `REPORT.md` appear. Resolve the Step-1 bootstrap-confirmation items
if the run errors, then re-run.

- [ ] **Step 5: Commit the tasks, fixtures, manifest, and report**

```bash
git add test/support/mix/tasks/imgproxy.gen_fixtures.ex \
        test/support/mix/tasks/imgproxy.reauthor.ex \
        test/support/image_pipe/test/imgproxy_differential/fixtures/ \
        test/support/image_pipe/test/imgproxy_differential/manifest.exs \
        test/support/image_pipe/test/imgproxy_differential/REPORT.md
git commit -m "feat(test): imgproxy fixture generator + reauthor task + bootstrap fixtures"
```

---

## Task 8: The differential comparison test

**Files:**
- Create: `test/image_pipe/imgproxy_differential_conformance_test.exs`

This is the default-lane test. It makes real `ImagePipe.Plug.call/2` requests using the
imgproxy parser (matching the existing wire test's setup), decodes both sides, and
applies the right assertion per constellation group/verdict. It uses the same
`Constellations.imgproxy_path/1` the generator used, so requests cannot drift.

- [ ] **Step 1: Inspect the existing wire test's Plug setup to mirror it**

Run: `mise exec -- grep -n "Plug.init\|Plug.call\|parser:\|def call_imgproxy\|RootHTTPAdapter\|def default_opts\|conn(" test/image_pipe/imgproxy_wire_conformance_test.exs | head -40`
Expected: shows how it builds `opts` (imgproxy parser + an origin adapter that serves the source) and the `call_imgproxy/2,3` helper. Reuse the same option shape, but the source origin must serve the **committed source files** (read from the sources dir by the local path imgproxy used, e.g. `high_freq.jpg`).

- [ ] **Step 2: Write the test**

```elixir
# test/image_pipe/imgproxy_differential_conformance_test.exs
defmodule ImagePipe.ImgproxyDifferentialConformanceTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias ImagePipe.Test.ImgproxyDifferential.{Constellations, Manifest, PixelCompare, Skew}
  alias ImagePipe.SourceTest.RootHTTPAdapter

  @base "test/support/image_pipe/test/imgproxy_differential"
  @fixtures_dir "#{@base}/fixtures"
  @manifest_path "#{@base}/manifest.exs"

  # Transform-group tolerance: threshold = max per-band delta tolerated per byte;
  # budget = how many band-bytes may exceed it. Tuned against real fixtures during
  # bootstrap; per-constellation `tol` overrides via %{threshold: t, budget: b}.
  @default_tol %{threshold: 2, budget: 64}

  # Serves the committed source files. imgproxy fetched them via local:///<file>,
  # which the imgproxy parser maps to a Plan.Source.Path; RootHTTPAdapter then
  # requests http://origin.test/<file>, so conn.request_path is "/<file>".
  defmodule SourceOrigin do
    @sources_dir "test/support/image_pipe/test/imgproxy_differential/sources"
    def init(opts), do: opts

    def call(conn, _opts) do
      file = Path.basename(conn.request_path)

      conn
      |> Plug.Conn.put_resp_content_type(content_type(file))
      |> Plug.Conn.send_resp(200, File.read!(Path.join(@sources_dir, file)))
    end

    defp content_type(f) do
      case Path.extname(f) do
        ".jpg" -> "image/jpeg"
        ".webp" -> "image/webp"
        _ -> "image/png"
      end
    end
  end

  setup_all do
    manifest = if File.exists?(@manifest_path), do: Manifest.load!(@manifest_path), else: nil
    {:ok, manifest: manifest}
  end

  # Real ExUnit skip on libvips skew, for the skew-gated groups only. :diverges
  # assertions are algorithmic/version-independent and always run; the CI-guard
  # and bootstrap-missing cases are not tagged :differential, so they always run.
  setup context do
    cond do
      context[:differential] != true -> :ok
      is_nil(context[:manifest]) -> :ok
      context[:verdict] == :diverges -> :ok
      Skew.aligned?(context.manifest) -> :ok
      true -> {:skip, "libvips #{Skew.runtime_libvips()} != fixtures' #{context.manifest.imgproxy_libvips}"}
    end
  end

  test "CI must not be green-by-skip: a present manifest under CI must align", %{manifest: manifest} do
    if manifest && Skew.ci?() do
      assert Skew.aligned?(manifest),
             "CI libvips #{Skew.runtime_libvips()} != fixtures' #{manifest.imgproxy_libvips}; " <>
               "regenerate fixtures on CI's libvips."
    end
  end

  for constellation <- Constellations.all() do
    @c constellation
    @tag :differential
    @tag verdict: constellation.verdict

    test "#{@c.id} (#{@c.verdict}/#{@c.group})", %{manifest: manifest} do
      if is_nil(manifest) do
        flunk("No manifest at #{@manifest_path}. Bootstrap: MIX_ENV=test IMGPROXY_DIFF=1 mix imgproxy.gen_fixtures")
      end

      entry = fetch_entry!(manifest, @c.id)

      assert entry.authored_sha256 == Manifest.authored_sha256(@c),
             "#{@c.id}: authored fields changed since generation — run `mix imgproxy.reauthor` " <>
               "(tol/verdict-only edits) or regenerate fixtures."

      run_constellation(@c, entry)
    end
  end

  defp fetch_entry!(manifest, id) do
    case Map.fetch(manifest.entries, id) do
      {:ok, entry} ->
        entry

      :error ->
        flunk("#{id}: no manifest entry. Run: MIX_ENV=test IMGPROXY_DIFF=1 mix imgproxy.gen_fixtures")
    end
  end

  # :diverges — structured regional metric, runs regardless of skew.
  defp run_constellation(%{verdict: :diverges} = c, entry) do
    out = imagepipe_image(c)
    fixture = fixture_image(c, entry)
    assert_same_dims!(c, out, fixture)

    %{metric: :region_mean_delta, region: region, floor: floor} = c.divergence
    delta = PixelCompare.region_mean_delta(out, fixture, region)

    assert delta >= floor,
           "#{c.id}: expected divergence ≥ #{floor} over #{inspect(region)}, got #{Float.round(delta, 3)}. " <>
             "If ImagePipe now matches imgproxy, flip this constellation to :equal and update the matrix."
  end

  # :equal transform — tight count-based pixel agreement (skew-gated via setup).
  defp run_constellation(%{group: :transform} = c, entry) do
    out = imagepipe_image(c)
    fixture = fixture_image(c, entry)
    assert_same_dims!(c, out, fixture)

    tol = c.tol || @default_tol
    outliers = PixelCompare.outliers(out, fixture, tol.threshold)

    assert outliers <= tol.budget,
           "#{c.id}: #{outliers} band-bytes over Δ#{tol.threshold} (budget #{tol.budget})"
  end

  # Lossy — dimension + content-type contract only (skew-gated via setup).
  defp run_constellation(%{group: :lossy} = c, entry) do
    {out, content_type} = imagepipe_response(c)

    assert {Image.width(out), Image.height(out)} == {entry.width, entry.height},
           "#{c.id}: dims #{inspect({Image.width(out), Image.height(out)})} != #{inspect({entry.width, entry.height})}"

    assert content_type == entry.content_type,
           "#{c.id}: content-type #{inspect(content_type)} != #{inspect(entry.content_type)}"
  end

  defp assert_same_dims!(c, out, fixture) do
    assert PixelCompare.same_dims?(out, fixture),
           "#{c.id}: dims #{inspect(PixelCompare.dims(out))} != fixture #{inspect(PixelCompare.dims(fixture))}"
  end

  defp imagepipe_response(c) do
    conn =
      :get
      |> conn(Constellations.imgproxy_path(c))
      |> ImagePipe.Plug.call(plug_opts())

    content_type =
      conn
      |> Plug.Conn.get_resp_header("content-type")
      |> List.first()
      |> then(fn ct -> ct && ct |> String.split(";") |> List.first() end)

    {Image.open!(conn.resp_body, access: :random, fail_on: :error), content_type}
  end

  defp imagepipe_image(c), do: elem(imagepipe_response(c), 0)

  # Reads the committed fixture and verifies it against the manifest sha256 (the
  # byte-corruption/edit guard); missing fixtures fail loudly, not with a KeyError.
  defp fixture_image(c, entry) do
    path = Path.join(@fixtures_dir, entry.fixture_filename)

    unless File.exists?(path) do
      flunk("#{c.id}: missing fixture #{path}. Run: MIX_ENV=test IMGPROXY_DIFF=1 mix imgproxy.gen_fixtures")
    end

    assert Manifest.file_sha256(path) == entry.fixture_sha256,
           "#{c.id}: fixture #{path} sha256 mismatch — corrupted or edited; regenerate."

    Image.open!(File.read!(path), access: :random, fail_on: :error)
  end

  defp plug_opts do
    ImagePipe.Plug.init(
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: SourceOrigin]}
      ]
    )
  end
end
```

> **Wiring note:** the `sources: [path: {RootHTTPAdapter, …, req_options: [plug: SourceOrigin]}]`
> shape is copied verbatim from `imgproxy_wire_conformance_test.exs:491-496` (Step 1).
> `local:///high_freq.jpg` parses to a `Plan.Source.Path`, so `RootHTTPAdapter` builds
> `http://origin.test/high_freq.jpg` and `SourceOrigin` sees `conn.request_path` of
> `/high_freq.jpg` — hence `Path.basename/1`.

- [ ] **Step 3: Run the comparison test (fixtures present from Task 7)**

Run: `mise exec -- mix test test/image_pipe/imgproxy_differential_conformance_test.exs`
Expected (libvips aligned with fixtures): transform constellations PASS within budget; `:diverges` constellations PASS (divergence ≥ floor); lossy constellations PASS the contract. If a transform budget is too tight, inspect `REPORT.md` and the failing constellation, set a per-constellation `tol`, and re-run. If a `:diverges` floor is not met, the divergence source/opts need strengthening (see spec §`:diverges`).
Expected (libvips NOT aligned): transform/lossy show as **skipped** (ExUnit `excluded/skipped` count, with the skew reason); `:diverges` still run; the CI-guard test passes locally (it only asserts under CI).

- [ ] **Step 4: Tune tolerances against real fixtures (no Docker)**

For any transform constellation that exceeds `@default_tol`, add a `tol:` override in
`constellations.ex` (e.g. `%{threshold: 3, budget: 256}` for the WebP residual-scale
case). Editing `:tol` changes the constellation's `authored_sha256`, which would trip
the authored-hash guard — so refresh the manifest's authored hashes with the
Docker-free reauthor task (fixtures are unchanged, so no container run):

Run: `MIX_ENV=test mise exec -- mix imgproxy.reauthor`

Re-run the test until green:
Run: `mise exec -- mix test test/image_pipe/imgproxy_differential_conformance_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit the test and any tolerance overrides**

```bash
git add test/image_pipe/imgproxy_differential_conformance_test.exs \
        test/support/image_pipe/test/imgproxy_differential/constellations.ex \
        test/support/image_pipe/test/imgproxy_differential/manifest.exs
git commit -m "feat(test): imgproxy differential comparison test (transform/diverges/lossy)"
```

---

## Task 9: Docs + full gate

**Files:**
- Modify: `docs/imgproxy_support_matrix.md` (add a "Differential conformance" subsection)
- Create: `test/support/image_pipe/test/imgproxy_differential/README.md`

- [ ] **Step 1: Add the matrix subsection**

Append to `docs/imgproxy_support_matrix.md`, in the conformance-tests area near the
existing wire-conformance reference:

```markdown
## Differential conformance

`test/image_pipe/imgproxy_differential_conformance_test.exs` compares ImagePipe's
decoded pixel output against committed fixtures generated from a pinned real imgproxy
(`mix imgproxy.gen_fixtures`). It is the **behavioral/pixel** enforcement of this
matrix: each constellation carries a verdict that maps to a stage row.

- **`:equal`** (transform group, ✅ stages): tight count-based pixel agreement on PNG
  output, skew-gated to the fixtures' libvips. Stages exercised: trim (sRGB),
  scaleOnLoad (JPEG/WebP), crop, scale (fit/fill/fill-down/auto), rotate, extend,
  extendAspectRatio, padding, flatten, applyFilters (blur/sharpen), stripMetadata.
- **`:diverges`** (⚠️ rows): asserts a *structured* divergence still holds (region
  mean-delta ≥ floor), so an accidental convergence fails and forces a verdict flip
  here + a matrix update. Covers colorspace #124 (`scp:0`) and trim-detection space.
- **lossy group**: dimension + content-type contract only (independent encoders), no
  pixel claim.

Regeneration and the libvips skew model are documented in
`test/support/image_pipe/test/imgproxy_differential/README.md`.
```

- [ ] **Step 2: Write the contributor README**

```markdown
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
```

- [ ] **Step 3: Run the full Elixir gate**

Run: `mise exec -- mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, and `mix test` all pass. (The differential test passes or skips per local libvips; the CI-guard test passes locally.)

- [ ] **Step 4: Commit**

```bash
git add docs/imgproxy_support_matrix.md \
        test/support/image_pipe/test/imgproxy_differential/README.md
git commit -m "docs(imgproxy): document differential conformance lane + regeneration"
```

---

## Notes for the executor

- **Run order matters:** Tasks 2–5 are pure TDD and independent. Task 6 must run its
  task (Step 5) to produce sources before Task 7 can generate fixtures. Task 8 needs
  Task 7's committed manifest/fixtures to go green.
- **Docker is only needed for Task 7 Step 4 (bootstrap generation).** Task 6 Step 5
  (source build), the reauthor task, and everything else run without Docker.
- **The bootstrap run (Task 7 Step 4) is where container-surface unknowns resolve**
  (`vips --version` exec for the libvips version, `/health` contract,
  `started.container_id`/`mapped_port` shapes). Adjust the flagged helpers there, not
  in the pure modules. Note: if the manifest's `imgproxy_libvips` ends up wrong, the
  skew gate silently skips everything locally and the CI guard fails — so confirm it.
- **`async: true`** is safe for the comparison test (read-only fixtures, no shared
  state). Keep it.
- **The skew skip is a real ExUnit skip** (a `{:skip, reason}` return from `setup`),
  not a passing assertion-free test — so a skipped suite shows in the skipped count,
  never as green coverage.
- **Do not** add ExUnit `@tag`/exclude to *exclude* this suite by default — it is a
  default-lane test by design (the per-test `:differential`/`verdict` tags only drive
  the skew skip; skew gate + CI guard handle honesty), unlike the `:image_vision` lane.
