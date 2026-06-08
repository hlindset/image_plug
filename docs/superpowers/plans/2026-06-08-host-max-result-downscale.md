# Host `max_result_*` error→downscale Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change ImagePipe's host result-dimension cap (`max_result_width`/`max_result_height`/`max_result_pixels`) from a 413 error to a uniform downscale-and-serve, matching imgproxy `limitScale`, by reusing the #150 `ImagePipe.Output.Clamp` seam fed `min(host_cap, encoder_limit)`.

**Architecture:** Widen `Output.Clamp.clamp/3`'s second argument from a single square `max_dimension` to a per-axis + pixel **limits map** (`%{max_width, max_height, max_pixels}`). Dimension caps use a linear per-axis scale (satisfied by construction); the pixel cap uses a **bounded verify-and-shrink loop** (a closed form cannot guarantee a rounded *product* ≤ cap). The producer computes the effective limits = `min(host max_result_*, encoder_limit(format))` and passes them in. The old `check_result_*`/413 error path is deleted; `max_input_pixels` stays the only hard error.

**Tech Stack:** Elixir, `Vix.Vips.Image`, the `image` library (`Image.width/1`, `Image.resize/2`), `:telemetry`, ExUnit + StreamData.

**Spec:** `docs/superpowers/specs/2026-06-08-host-max-result-downscale-design.md`

**Tooling note:** all commands run through `mise exec -- …`. The imgproxy upstream checkout for parity is at `/Users/hlindset/src/image_plug/local/imgproxy-master/` (in the **main repo**, not the worktree).

---

## File map

- **Modify** `lib/image_pipe/output/encoder.ex` — `encoder_limit/1` gains `:max_pixels`.
- **Rewrite** `lib/image_pipe/output/clamp.ex` — limits-map signature, per-axis scale, pixel verify-shrink loop, per-axis 1px floor, new `clamp_info`.
- **Modify** `lib/image_pipe/request/source_session/producer.ex` — `effective_limits/2` + `min_limit/2`, the `with`-chain call, `emit_clamp_telemetry` metadata (`max_dimension` → `limits`).
- **Modify** `lib/image_pipe/request/processor.ex` — delete `validate_result_image/2` + `check_result_*` and their use in `process_decoded_source`.
- **Modify** `lib/image_pipe/response/sender.ex` — delete the `{:result_limit, _}` clause + `send_result_limit_error/3`.
- **Modify** `lib/image_pipe/telemetry/logger.ex` — `message/3` for `[:output, :clamp]` renders `limits`, with graceful `:infinity`.
- **Rewrite** `test/image_pipe/output/clamp_test.exs` — limits-map unit tests + pixel property test.
- **Modify** `test/image_pipe/telemetry/logger_test.exs` — `limits` metadata + rendered string.
- **Modify** `test/image_pipe/imgproxy_wire_conformance_test.exs` — update #150 tests' `max_dimension`→`limits`; add #165 downscale tests.
- **Modify** `test/image_pipe/processor_test.exs` — delete the two result-limit tests (~181, ~197).
- **Modify** `test/image_pipe/plug_test.exs` — delete the 413 result-limit test (~2051); keep the within-limits no-clamp control (~2069).
- **Modify** `docs/imgproxy_support_matrix.md`, `docs/telemetry.md`, `docs/operational_notes.md`.

---

## Task 1: Add `:max_pixels` to `encoder_limit/1`

**Files:**
- Modify: `lib/image_pipe/output/encoder.ex:13-22`
- Test: `test/image_pipe/output/clamp_test.exs` (the `encoder_limit/1` describe block)

- [ ] **Step 1: Update the failing tests**

In `test/image_pipe/output/clamp_test.exs`, replace the `encoder_limit/1` describe block with:

```elixir
  describe "encoder_limit/1" do
    test "returns the WebP and AVIF hard dimension limits with unbounded pixels" do
      assert Encoder.encoder_limit(:webp) == %{max_dimension: 16_383, max_pixels: :infinity}
      assert Encoder.encoder_limit(:avif) == %{max_dimension: 16_384, max_pixels: :infinity}
    end

    test "returns the documented JPEG limit and unbounded PNG" do
      assert Encoder.encoder_limit(:jpeg) == %{max_dimension: 65_535, max_pixels: :infinity}
      assert Encoder.encoder_limit(:png) == %{max_dimension: :infinity, max_pixels: :infinity}
    end
  end
```

- [ ] **Step 2: Run, verify failure**

Run: `mise exec -- mix test test/image_pipe/output/clamp_test.exs:18 -v`
Expected: FAIL (current return lacks `:max_pixels`).

- [ ] **Step 3: Implement**

In `lib/image_pipe/output/encoder.ex`, update the doc and the four clauses:

```elixir
  @doc """
  The output encoder's hard per-format limits, used by `ImagePipe.Output.Clamp`
  to keep encoding from failing. `:max_dimension` is the hard per-axis pixel
  limit; `:max_pixels` is a total-resolution budget. `:infinity` means no
  practical limit. Sourced from libvips encoder constraints (cf. imgproxy
  `processing/fix_size.go`). #165 folds these with the host `max_result_*` caps
  via `min/2` at the producer before calling `Clamp.clamp/3`.
  """
  @spec encoder_limit(Format.output_format()) :: %{
          max_dimension: pos_integer() | :infinity,
          max_pixels: pos_integer() | :infinity
        }
  def encoder_limit(:webp), do: %{max_dimension: 16_383, max_pixels: :infinity}
  def encoder_limit(:avif), do: %{max_dimension: 16_384, max_pixels: :infinity}
  def encoder_limit(:jpeg), do: %{max_dimension: 65_535, max_pixels: :infinity}
  def encoder_limit(:png), do: %{max_dimension: :infinity, max_pixels: :infinity}
```

- [ ] **Step 4: Run, verify pass**

Run: `mise exec -- mix test test/image_pipe/output/clamp_test.exs -v`
Expected: the `encoder_limit/1` tests PASS. (The `clamp/3` tests still reference the old signature and will be rewritten in Task 2 — they may fail now; that is expected and fixed in Task 2. If you want a green checkpoint here, run only the `encoder_limit` describe: `mise exec -- mix test test/image_pipe/output/clamp_test.exs:18`.)

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/output/encoder.ex test/image_pipe/output/clamp_test.exs
git commit -m "feat(output): add :max_pixels to encoder_limit/1 (#165)"
```

---

## Task 2: Migrate `Output.Clamp` to a per-axis + pixel limits map

This is the core task. It changes `clamp/3`'s contract, so it updates the clamp, its only call site (the producer), the telemetry metadata, the Logger rendering, and all of their tests **together** — the task ends with the full suite green.

**Files:**
- Rewrite: `lib/image_pipe/output/clamp.ex`
- Modify: `lib/image_pipe/request/source_session/producer.ex:124-128` (the `with` lines), `:160-176` (`emit_clamp_telemetry`)
- Modify: `lib/image_pipe/telemetry/logger.ex:166-171`
- Rewrite: `test/image_pipe/output/clamp_test.exs` (the `clamp/3` describe)
- Modify: `test/image_pipe/telemetry/logger_test.exs:116-135`
- Modify: `test/image_pipe/imgproxy_wire_conformance_test.exs` (#150 tests' `meta.max_dimension` → `meta.limits`)

- [ ] **Step 1: Write the new `clamp/3` unit tests**

Replace the entire `describe "clamp/3"` block in `test/image_pipe/output/clamp_test.exs` with the following (and add `use ExUnitProperties` to the module — keep `use ExUnit.Case, async: true`):

```elixir
  describe "clamp/3" do
    alias ImagePipe.Output.Clamp

    @inf %{max_width: :infinity, max_height: :infinity, max_pixels: :infinity}

    defp image(width, height) do
      {:ok, image} = Image.new(width, height)
      image
    end

    defp limits(opts) do
      %{
        max_width: Keyword.get(opts, :max_width, :infinity),
        max_height: Keyword.get(opts, :max_height, :infinity),
        max_pixels: Keyword.get(opts, :max_pixels, :infinity)
      }
    end

    test "no-op (unchanged image, nil info) when within all caps" do
      img = image(200, 50)
      assert {:ok, ^img, nil} = Clamp.clamp(img, limits(max_width: 1000, max_height: 1000), [])
    end

    test "no-op for an all-:infinity limits map" do
      img = image(200, 50)
      assert {:ok, ^img, nil} = Clamp.clamp(img, @inf, [])
    end

    test "no-op when a cap exactly equals a dimension (no degenerate resize)" do
      img = image(200, 50)
      assert {:ok, ^img, nil} = Clamp.clamp(img, limits(max_width: 200, max_height: 50), [])
    end

    test "downscales linearly when the width cap binds" do
      img = image(200, 50)
      assert {:ok, resized, info} = Clamp.clamp(img, limits(max_width: 100), [])

      assert Image.width(resized) == 100
      assert Image.height(resized) == 25
      assert info.source_dimensions == {200, 50}
      assert info.dimensions == {100, 25}
      assert info.limits == limits(max_width: 100)
      assert_in_delta info.scale, 0.5, 1.0e-6
    end

    test "downscales when the height cap binds" do
      img = image(50, 200)
      assert {:ok, resized, info} = Clamp.clamp(img, limits(max_height: 100), [])

      assert Image.width(resized) == 25
      assert Image.height(resized) == 100
      assert info.dimensions == {25, 100}
    end

    test "respects asymmetric caps without over-shrinking (per-axis)" do
      # 8000x4000, caps w<=10000 (slack), h<=4000 (exactly met) -> no clamp.
      img = image(8000, 4000)
      assert {:ok, ^img, nil} = Clamp.clamp(img, limits(max_width: 10_000, max_height: 4000), [])
    end

    test "downscales on the pixel budget, preserving aspect, realized product <= cap" do
      # 2000x2000 = 4_000_000 px; cap 1_000_000 -> scale 0.5 -> 1000x1000.
      img = image(2000, 2000)
      assert {:ok, resized, info} = Clamp.clamp(img, limits(max_pixels: 1_000_000), [])

      w = Image.width(resized)
      h = Image.height(resized)
      assert w * h <= 1_000_000
      assert_in_delta w / 2000, h / 2000, 1.0e-6
      assert info.dimensions == {w, h}
    end

    test "takes the most-aggressive scale when pixel and dimension caps disagree" do
      # 4000x1000 = 4_000_000 px. max_width 2000 -> dim scale 0.5 (-> 2000x500=1_000_000).
      # max_pixels 250_000 -> sqrt(250000/4e6)=0.25 (-> 1000x250=250_000). Pixels win.
      img = image(4000, 1000)
      assert {:ok, resized, _info} =
               Clamp.clamp(img, limits(max_width: 2000, max_pixels: 250_000), [])

      assert Image.width(resized) <= 2000
      assert Image.width(resized) * Image.height(resized) <= 250_000
    end

    test "keeps each axis >= 1px for an extreme aspect ratio with a tight cap" do
      img = image(40_000, 1)
      assert {:ok, resized, _info} = Clamp.clamp(img, limits(max_width: 100), [])

      assert Image.width(resized) <= 100
      assert Image.height(resized) >= 1
    end
  end

  describe "clamp/3 pixel ≤-cap property" do
    alias ImagePipe.Output.Clamp

    property "realized dims and pixel product never exceed the caps" do
      check all(
              w <- StreamData.integer(1..6000),
              h <- StreamData.integer(1..6000),
              max_w <- StreamData.integer(8..6000),
              max_h <- StreamData.integer(8..6000),
              max_px <- StreamData.integer(64..2_000_000),
              max_runs: 300
            ) do
        {:ok, image} = Image.new(w, h)
        lim = %{max_width: max_w, max_height: max_h, max_pixels: max_px}

        assert {:ok, resized, _info} = Clamp.clamp(image, lim, [])
        rw = Image.width(resized)
        rh = Image.height(resized)

        assert rw >= 1 and rh >= 1
        assert rw <= max_w
        assert rh <= max_h
        assert rw * rh <= max_px
      end
    end
  end
```

- [ ] **Step 2: Run, verify failure**

Run: `mise exec -- mix test test/image_pipe/output/clamp_test.exs -v`
Expected: FAIL — `clamp/3` still takes a scalar `max_dimension`; the map-arg calls won't match / `info.limits` is undefined.

- [ ] **Step 3: Rewrite `lib/image_pipe/output/clamp.ex`**

Replace the whole file with:

```elixir
defmodule ImagePipe.Output.Clamp do
  @moduledoc false
  # Generic, product-neutral uniform downscale of a realized image so it fits a
  # set of result caps: per-axis dimensions (`:max_width`/`:max_height`) and a
  # total pixel budget (`:max_pixels`). The producer passes the EFFECTIVE caps =
  # min(host max_result_*, encoder limit), so encoding cannot fail AND the host
  # result cap downscales rather than errors (imgproxy `limitScale` parity).
  # Knows nothing about formats or hosts.
  #
  # Reads/resizes via the `image` library directly (no Transform/Telemetry dep).
  # Resize is lazy; measuring width/height reads libvips header fields (O(1)).

  alias Vix.Vips.Image, as: VixImage

  @type limit :: pos_integer() | :infinity
  @type limits :: %{max_width: limit(), max_height: limit(), max_pixels: limit()}

  @type clamp_info :: %{
          scale: float(),
          source_dimensions: {pos_integer(), pos_integer()},
          dimensions: {pos_integer(), pos_integer()},
          limits: limits()
        }

  # Bounded escape for the pixel verify-and-shrink loop. Realistic caps converge
  # in one iteration; the bound only guards an adversarially tiny pixel cap (a
  # few hundred px) that needs several geometric steps.
  @max_pixel_iterations 16

  @spec clamp(VixImage.t(), limits(), keyword()) ::
          {:ok, VixImage.t(), clamp_info() | nil}
          | {:error, {:encode, Exception.t(), list()}}
  def clamp(%VixImage{} = image, %{} = limits, opts) do
    w = Image.width(image)
    h = Image.height(image)
    scale = primary_scale(limits, w, h)

    if scale >= 1.0 do
      {:ok, image, nil}
    else
      image_module = Keyword.get(opts, :image_module, Image)

      with {:ok, resized} <- resize(image_module, image, scale),
           {:ok, resized} <- enforce(image_module, image, resized, limits, @max_pixel_iterations) do
        rw = Image.width(resized)
        rh = Image.height(resized)

        {:ok, resized,
         %{
           scale: rw / w,
           source_dimensions: {w, h},
           dimensions: {rw, rh},
           limits: limits
         }}
      end
    end
  end

  # Most-aggressive scale across the per-axis dimension caps (linear) and the
  # pixel budget (sqrt). >= 1.0 means no cap binds -> no-op.
  defp primary_scale(%{max_width: mw, max_height: mh, max_pixels: mp}, w, h) do
    [axis_scale(mw, w), axis_scale(mh, h), pixel_scale(mp, w * h)]
    |> Enum.min()
    |> min(1.0)
  end

  defp axis_scale(:infinity, _dim), do: 1.0
  defp axis_scale(max_dim, dim) when dim <= max_dim, do: 1.0
  defp axis_scale(max_dim, dim), do: max_dim / dim

  defp pixel_scale(:infinity, _px), do: 1.0
  defp pixel_scale(max_px, px) when px <= max_px, do: 1.0
  defp pixel_scale(max_px, px), do: :math.sqrt(max_px / px)

  # Dimension caps are satisfied by the primary resize's construction; only the
  # pixel budget can overshoot (a product of two independently rounded axes), so
  # this loop verifies the realized result and shrinks the dominant axis toward
  # the aspect-preserving pixel budget until it fits. Always resizes from the
  # ORIGINAL (never the already-resized image) to avoid compounding rounding;
  # only ever shrinks, so dimension caps stay satisfied. Checks ALL caps each
  # iteration (defensive). Exhausting the bound is a tagged encode error.
  defp enforce(image_module, original, resized, limits, iters_left) do
    rw = Image.width(resized)
    rh = Image.height(resized)

    cond do
      within_caps?(rw, rh, limits) ->
        {:ok, resized}

      iters_left == 0 ->
        {:error, encode_error(:pixel_enforce_exhausted)}

      true ->
        target_long = shrink_target(rw, rh, limits)
        long_orig = max(Image.width(original), Image.height(original))
        # round-to target_long on the long axis; +0.49 lands on target_long, not target_long+1.
        scale = (target_long + 0.49) / long_orig

        with {:ok, resized} <- resize(image_module, original, scale) do
          enforce(image_module, original, resized, limits, iters_left - 1)
        end
    end
  end

  defp within_caps?(w, h, %{max_width: mw, max_height: mh, max_pixels: mp}) do
    within?(w, mw) and within?(h, mh) and within?(w * h, mp)
  end

  defp within?(_value, :infinity), do: true
  defp within?(value, limit), do: value <= limit

  # Largest dominant-axis length that fits the long axis's own dimension cap and
  # (aspect-preserving) the pixel budget, with a strict -1 progress floor so the
  # loop always advances at least one pixel and therefore terminates. The
  # :infinity terms are naturally ignored by Enum.min (an atom sorts above the
  # always-present `long - 1` integer).
  defp shrink_target(rw, rh, %{max_width: mw, max_height: mh, max_pixels: mp}) do
    long = max(rw, rh)
    short = min(rw, rh)
    long_dim_cap = if rw >= rh, do: mw, else: mh

    Enum.min([long - 1, dim_target(long_dim_cap), pixel_target(mp, long, short)])
  end

  defp dim_target(:infinity), do: :infinity
  defp dim_target(max_dim), do: max_dim

  defp pixel_target(:infinity, _long, _short), do: :infinity
  # long' * (long' * short / long) <= max_px  =>  long' = floor(sqrt(max_px * long / short))
  defp pixel_target(max_px, long, short), do: trunc(:math.sqrt(max_px * long / short))

  # Per-axis 1px floor: never scale an axis below one realized pixel. This is the
  # equivalent of imgproxy's `WScale >= 1/widthToScale` (prepare.go:252-258) and
  # is what keeps an extreme aspect ratio (e.g. 40000x1) from rounding the short
  # axis to 0 under a tight cap.
  defp resize(image_module, image, scale) do
    w = Image.width(image)
    h = Image.height(image)
    hscale = max(scale, 1.0 / w)
    vscale = max(scale, 1.0 / h)

    case image_module.resize(image, hscale, vertical_scale: vscale) do
      {:ok, resized} -> {:ok, resized}
      {:error, reason} -> {:error, encode_error(reason)}
    end
  end

  defp encode_error(reason) do
    {:encode, RuntimeError.exception("clamp resize failed: #{inspect(reason)}"), []}
  end
end
```

- [ ] **Step 4: Run the clamp tests, verify pass**

Run: `mise exec -- mix test test/image_pipe/output/clamp_test.exs`
Expected: PASS (unit + property). If the property test finds a counterexample (a 0px axis or an over-cap product), the bug is in `resize`/`shrink_target` — fix it; do not weaken the assertion.

- [ ] **Step 5: Wire the producer to the limits map**

In `lib/image_pipe/request/source_session/producer.ex`, in `prepare_first_chunk/1`'s `with` chain, replace the two clamp lines:

```elixir
# REMOVE:
           %{max_dimension: max_dimension} = Encoder.encoder_limit(resolved_output.format),
           {:ok, image, clamp_info} <-
             Clamp.clamp(final_state.image, max_dimension, request.opts),
# WITH:
           limits = effective_limits(resolved_output.format, request.opts),
           {:ok, image, clamp_info} <-
             Clamp.clamp(final_state.image, limits, request.opts),
```

Add these private helpers to the module (near `emit_clamp_telemetry`):

```elixir
  # Effective per-axis + pixel result caps: the tighter of the host `max_result_*`
  # config and the chosen encoder's hard limit. The clamp does not care which
  # source won the `min`.
  defp effective_limits(format, opts) do
    %{max_dimension: enc_dim, max_pixels: enc_px} = Encoder.encoder_limit(format)

    %{
      max_width: min_limit(Keyword.fetch!(opts, :max_result_width), enc_dim),
      max_height: min_limit(Keyword.fetch!(opts, :max_result_height), enc_dim),
      max_pixels: min_limit(Keyword.fetch!(opts, :max_result_pixels), enc_px)
    }
  end

  # `:infinity` means "no limit from this source". Host caps are always integers.
  defp min_limit(a, :infinity), do: a
  defp min_limit(:infinity, b), do: b
  defp min_limit(a, b), do: min(a, b)
```

Update `emit_clamp_telemetry/3`'s metadata map (`max_dimension:` → `limits:`):

```elixir
  defp emit_clamp_telemetry(%{} = info, format, opts) do
    Telemetry.execute(
      Telemetry.telemetry_opts(opts),
      [:output, :clamp],
      %{scale: info.scale},
      %{
        format: format,
        source_dimensions: info.source_dimensions,
        dimensions: info.dimensions,
        limits: info.limits
      }
    )

    :ok
  end
```

- [ ] **Step 6: Update the Logger rendering**

In `lib/image_pipe/telemetry/logger.ex`, replace the `[:output, :clamp | _]` `message/3` clause (currently ~166-171):

```elixir
  defp message([:output, :clamp | _], _m, meta) do
    {sw, sh} = meta[:source_dimensions]
    {w, h} = meta[:dimensions]
    %{max_width: mw, max_height: mh, max_pixels: mp} = meta[:limits]

    "image_pipe output clamp: #{sw}x#{sh} -> #{w}x#{h} for #{meta[:format]} " <>
      "(caps w:#{cap(mw)} h:#{cap(mh)} px:#{cap(mp)})"
  end
```

Add a small private renderer (place it among the other `defp`s, e.g. just below the `message/3` clauses):

```elixir
  defp cap(:infinity), do: "∞"
  defp cap(value), do: value
```

- [ ] **Step 7: Update the Logger test**

In `test/image_pipe/telemetry/logger_test.exs:116-135`, replace the event metadata and the asserted string:

```elixir
        :telemetry.execute(
          [:image_pipe, :output, :clamp],
          %{scale: 0.91},
          %{
            format: :webp,
            source_dimensions: {18_000, 9_000},
            dimensions: {8_192, 4_096},
            limits: %{max_width: 8_192, max_height: 8_192, max_pixels: 40_000_000}
          }
        )
```

```elixir
    assert log =~ "[warning]"
    assert log =~ "output clamp: 18000x9000 -> 8192x4096 for webp (caps w:8192 h:8192 px:40000000)"
```

- [ ] **Step 8: Update the #150 conformance assertions**

In `test/image_pipe/imgproxy_wire_conformance_test.exs`, the `describe "output encoder dimension clamp (#150)"` block asserts `meta.max_dimension`. Replace each such assertion with a `limits` check. For the WebP test (~2357-2363):

```elixir
      assert scale < 1.0
      assert meta.format == :webp
      assert meta.limits.max_width == 16_383
      assert meta.limits.max_height == 16_383
      assert meta.dimensions == {w, h}
      {sw, sh} = meta.source_dimensions
      assert max(sw, sh) > 16_383
```

For the AVIF test (~2380-2384):

```elixir
      assert scale < 1.0
      assert meta.format == :avif
      assert meta.limits.max_width == 16_384
      assert meta.limits.max_height == 16_384
      assert meta.dimensions == {w, h}
```

(The `@clamp_opts` already raise the host caps to 40_000 / 2_000_000_000, so the *encoder* limit wins the `min` and `limits.max_width == 16_383`/`16_384` as asserted.)

- [ ] **Step 9: Run the full suite, verify green**

Run: `mise exec -- mix test`
Expected: PASS. (The result-limit *error* tests in `processor_test.exs`/`plug_test.exs` still assert 413 and still pass here, because `validate_result_image` is not removed until Task 3.)

- [ ] **Step 10: Commit**

```bash
git add lib/image_pipe/output/clamp.ex \
        lib/image_pipe/request/source_session/producer.ex \
        lib/image_pipe/telemetry/logger.ex \
        test/image_pipe/output/clamp_test.exs \
        test/image_pipe/telemetry/logger_test.exs \
        test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "feat(output): per-axis + pixel limits map for Clamp; fold host caps at producer (#165)"
```

---

## Task 3: Delete the `check_result_*` error path

With Task 2 wired, the producer now clamps at `min(host, encoder)`. Removing `validate_result_image` lets host-cap-exceeding results reach that clamp and downscale instead of 413.

**Files:**
- Modify: `lib/image_pipe/request/processor.ex:143-145` (the `with` line) and `:291-315` (the functions)
- Modify: `lib/image_pipe/response/sender.ex:129-130, 196-203`
- Modify: `test/image_pipe/processor_test.exs` (delete ~181 and ~197 tests)
- Modify: `test/image_pipe/plug_test.exs` (delete the ~2051 413 test)

- [ ] **Step 1: Delete the result-limit tests first (they assert the old behavior)**

In `test/image_pipe/processor_test.exs`, delete both tests:
- "process_source rejects final images wider than configured result limit" (~181)
- "process_source accepts final images within configured result limits" (~197)

In `test/image_pipe/plug_test.exs`, delete the test "rejects static result dimensions above configured limits before encoding" (~2051). **Keep** "allows static result dimensions within configured limits" (~2069) — it is the no-clamp control.

- [ ] **Step 2: Remove `validate_result_image` from the transform pipeline**

In `lib/image_pipe/request/processor.ex`, in `process_decoded_source/3`, remove the `validate_result_image` step from the `with`:

```elixir
        result =
          with {:ok, final_state} <-
                 execute_transform_plan(initial_state, plan, opts),
               {:ok, final_state} <-
                 materialize_before_delivery(final_state, opts, source_response) do
            {:ok, final_state}
          end
```

Delete the now-unused functions `validate_result_image/2`, `check_result_width/2`, `check_result_height/2`, `check_result_pixels/2` (the block at ~291-315).

- [ ] **Step 3: Remove the `{:result_limit, _}` response handling**

In `lib/image_pipe/response/sender.ex`, delete the clause:

```elixir
  defp handle_processing_error(conn, {:result_limit, error}, response_headers),
    do: send_result_limit_error(conn, error, response_headers)
```

and the function `send_result_limit_error/3` (~196-203).

- [ ] **Step 4: Compile with warnings-as-errors (catches any leftover reference)**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean compile. (No unused-function or undefined-reference warnings; the `{:result_limit, _}` tag now has zero emitters and zero handlers.)

- [ ] **Step 5: Run the full suite, verify green**

Run: `mise exec -- mix test`
Expected: PASS. Oversized-result requests now downscale (covered by Task 2's clamp); the deleted 413 tests are gone; `max_input_pixels` 413 tests still pass.

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/request/processor.ex lib/image_pipe/response/sender.ex \
        test/image_pipe/processor_test.exs test/image_pipe/plug_test.exs
git commit -m "feat(request): host result cap downscales instead of 413; drop check_result_* (#165)"
```

---

## Task 4: Wire-level #165 conformance tests

Add real-`call/2` downscale coverage at **default** host caps (the common path), plus per-axis and pixel-cap cases.

**Files:**
- Modify: `test/image_pipe/imgproxy_wire_conformance_test.exs` (add a new describe block near the #150 one)

- [ ] **Step 1: Add the #165 describe block**

After the `describe "output encoder dimension clamp (#150)"` block, add:

```elixir
  describe "host result cap downscale (#165, limitScale parity)" do
    # Default host caps: max_result_width/height = 8192, max_result_pixels = 40M.
    @host_default_opts [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: OriginImage]}
      ],
      output_capabilities: %{avif: true, webp: true}
    ]

    test "downscales a result above the default 8192 host cap and serves 200" do
      attach_clamp_telemetry()

      conn =
        call_imgproxy("/_/el:1/rs:force:12000:200/f:jpeg/plain/images/beach.jpg", @host_default_opts)

      assert conn.status == 200
      assert content_type(conn) == ["image/jpeg"]

      {w, h} = dimensions(conn)
      assert max(w, h) <= 8192

      assert_received {:telemetry_event, [:image_pipe, :output, :clamp], %{scale: scale}, meta}
      assert scale < 1.0
      assert meta.limits.max_width == 8192
      assert meta.limits.max_height == 8192
      assert meta.dimensions == {w, h}
      {sw, _sh} = meta.source_dimensions
      assert sw > 8192
    end

    test "honors asymmetric per-axis caps without over-shrinking" do
      attach_clamp_telemetry()

      # Realize ~6000x200, raise width cap above it, keep height cap slack:
      # both axes within caps -> NO clamp, served at full requested size.
      conn =
        call_imgproxy(
          "/_/el:1/rs:force:6000:200/f:jpeg/plain/images/beach.jpg",
          Keyword.merge(@host_default_opts, max_result_width: 10_000, max_result_height: 8192)
        )

      assert conn.status == 200
      {w, h} = dimensions(conn)
      assert w == 6000
      assert h == 200
      refute_received {:telemetry_event, [:image_pipe, :output, :clamp], _m, _meta}
    end

    test "downscales on the host pixel cap with dims within the per-axis caps" do
      attach_clamp_telemetry()

      # ~5000x5000 = 25M px. Per-axis caps slack (8000), pixel cap 4M -> clamp on pixels.
      conn =
        call_imgproxy(
          "/_/el:1/rs:force:5000:5000/f:jpeg/plain/images/beach.jpg",
          Keyword.merge(@host_default_opts,
            max_result_width: 8000,
            max_result_height: 8000,
            max_result_pixels: 4_000_000
          )
        )

      assert conn.status == 200
      {w, h} = dimensions(conn)
      assert w <= 8000 and h <= 8000
      assert w * h <= 4_000_000

      assert_received {:telemetry_event, [:image_pipe, :output, :clamp], %{scale: scale}, _meta}
      assert scale < 1.0
    end

    test "does not clamp or emit when the result is within all default caps" do
      attach_clamp_telemetry()

      conn = call_imgproxy("/_/w:300/f:jpeg/plain/images/beach.jpg", @host_default_opts)

      assert conn.status == 200
      {w, _h} = dimensions(conn)
      assert w == 300
      refute_received {:telemetry_event, [:image_pipe, :output, :clamp], _m, _meta}
    end
  end
```

- [ ] **Step 2: Run the conformance file, verify pass**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS. If `rs:force:` geometry or `OriginImage` source size differs from the assumed dimensions, adjust the geometry tokens / source so the realized pre-clamp size actually exceeds (or stays under) the asserted cap — verify by temporarily logging `meta.source_dimensions`. The **contract** asserted (status 200, decoded dims ≤ caps, pixel product ≤ cap, telemetry fired/not-fired) must not change.

- [ ] **Step 3: Confirm the kept no-clamp control still passes**

Run: `mise exec -- mix test test/image_pipe/plug_test.exs`
Expected: PASS, including "allows static result dimensions within configured limits" (the `StreamingOnlyImage` no-op control — `max_result_width: 64` == realized `w:64`, so the producer clamp no-ops and the stub streams `"streamed jpeg"`).

- [ ] **Step 4: Commit**

```bash
git add test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "test(imgproxy): wire-level host result-cap downscale conformance (#165)"
```

---

## Task 5: Documentation sync

**Files:**
- Modify: `docs/imgproxy_support_matrix.md`
- Modify: `docs/telemetry.md`
- Modify: `docs/operational_notes.md`

- [ ] **Step 1: Support matrix — the host-result-cap row**

In `docs/imgproxy_support_matrix.md`, the "Surrounding stages" table row for the host result-dimension cap currently reads ⚠️ and points at `check_result_*`. Replace it with:

```markdown
| Host result-dimension cap (`limitScale`, `processing/prepare.go`) | `lib/image_pipe/output/clamp.ex` via the producer (`min(host max_result_*, encoder_limit)`) | ✅ | imgproxy downscales the result to fit `max_result_*`; ImagePipe now matches (#165), reusing the #150 `Output.Clamp`. **Diverges (superset):** ImagePipe honors independent `max_result_width`/`max_result_height` and a result `max_result_pixels` cap (sqrt), where imgproxy's `limitScale` has a single `MaxResultDimension` and no result-pixel cap. **Diverges (composition):** ImagePipe clamps the **composited** final image, whereas imgproxy folds the downscale into the resize scale before padding/extend (`prepare.go:233-263`) — both land ≤ cap; padded/extended requests differ in internal composition. Matches imgproxy's sub-1px floor via a per-axis `max(scale, 1/dim)`. |
```

- [ ] **Step 2: Support matrix — fix the stale `fixSize` row (row 13)**

Replace the trailing sentence of the `fixSize` row ("The `max_pixels`/sqrt branch (imgproxy's `fixGifSize`) is deferred to #165.") with:

```markdown
The host `max_result_*` caps fold into this same clamp via `min(host, encoder)` (#165); ImagePipe's result-pixel cap uses an **independent linear-dimension + sqrt-pixel** rule, deliberately **not** `fixGifSize`'s combined-sqrt (which can leave a result over the dimension limit).
```

- [ ] **Step 3: Support matrix — the "standing divergences" takeaway**

The "Key takeaways" bullet currently reads "The standing divergences are color management (#124) and the host result cap (#165)." Update it to drop the host-result-cap divergence (now matched) and note the superset:

```markdown
- **The standing divergence is color management (#124).** The host result cap now
  downscales to match imgproxy (#165), with a deliberate, strictly-safe superset:
  independent per-axis width/height + a result-pixel cap, and a composited-image
  clamp point. Everything else either matches or is an explicitly missing/out-of-scope
  surface documented in the tables below.
```

- [ ] **Step 4: Support matrix — input/output safety-limits section**

In the "Input and output safety limits" prose (~426-437), update the sentence that frames `max_result_*` as an error to state it now downscales-to-fit (imgproxy `limitScale` parity), while `max_input_pixels` remains the hard image-bomb gate. (Edit the existing sentences in place; keep the `max_input_pixels`/`max_body_bytes` description unchanged.)

- [ ] **Step 5: telemetry.md — rewrite the Output dimension clamp section**

Replace the "Output dimension clamp" section body so it covers both the host and encoder caps and the `limits` metadata:

```markdown
## Output dimension clamp (`[:output, :clamp]`)

When the realized final image exceeds the effective result caps — the tighter of
the host `max_result_width`/`max_result_height`/`max_result_pixels` config and the
negotiated output encoder's hard limit (`min(host, encoder)`) — ImagePipe uniformly
downscales it to fit before encoding and emits a one-shot (non-span) marker. This
both keeps encoding from failing (WebP caps each dimension at 16383, AVIF at 16384;
JPEG/PNG effectively unbounded) and serves the host result cap as a downscale rather
than an error (imgproxy `limitScale` parity). The common trigger is the host cap
(default 8192 per axis), which is below the encoder limits.

​```text
[:image_pipe, :output, :clamp]
​```

Measurements:

- `:scale` — the uniform downscale factor applied (a float `< 1.0`).

Metadata:

- `:format` — the negotiated output format atom (e.g. `:webp`, `:avif`).
- `:source_dimensions` — `{w, h}` before the clamp.
- `:dimensions` — `{w, h}` after the clamp.
- `:limits` — the effective caps applied: `%{max_width, max_height, max_pixels}`
  (each a `pos_integer` or `:infinity`).

This metadata is product-neutral and non-sensitive (no URLs, secrets, or PII).

The opt-in default Logger attaches to this event and renders it at `:warning`,
matching imgproxy's `slog.Warn` for the same condition, e.g.:

​```text
output clamp: 18000x9000 -> 8192x4096 for webp (caps w:8192 h:8192 px:40000000)
​```
```

(Remove the leading zero-width characters from the fenced-code backticks above — they are only here to keep this plan's markdown from closing early. Use plain triple backticks.)

- [ ] **Step 6: operational_notes.md**

In `docs/operational_notes.md`, update the `max_result_*` mention (the 413 "result image is too large" behavior) to: the result caps now downscale the served image to fit (imgproxy `limitScale` parity); `max_input_pixels` remains a hard 413 image-bomb gate.

- [ ] **Step 7: Commit**

```bash
git add docs/imgproxy_support_matrix.md docs/telemetry.md docs/operational_notes.md
git commit -m "docs: host result cap downscales (limitScale parity); clamp telemetry limits metadata (#165)"
```

---

## Task 6: Full gate

- [ ] **Step 1: Run the Elixir precommit gate**

Run: `mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` all pass. Fix any formatting/credo findings in place and re-run.

- [ ] **Step 2: Commit any gate fixups (if needed)**

```bash
git add -A && git commit -m "chore: precommit fixups (#165)"
```

---

## Notes for the implementer

- **The pixel ≤-cap property test is the safety net.** It is the test that would have caught the closed-form overshoot the design review found. If you change `shrink_target`/`resize`, keep it passing; do not narrow its input ranges to dodge a failure — a failure means the loop is wrong.
- **Do not reintroduce a `{:result_limit, _}` tag** anywhere. After Task 3 it has no emitter and no handler; a stray one would crash with `FunctionClauseError` in the sender.
- **`max_result_*` must stay out of the cache key and ETag** (`lib/image_pipe/cache/key.ex`, `lib/image_pipe/request/http_cache.ex`) — they are absent today and this change must not add them. The clamp output is deterministic from inputs already in the key (source identity + plan + negotiated format) for a given deployment.
- **No demo UI change** — `max_result_*` are host config, not URL/transform knobs.
- **Out of scope:** the shrink-on-load decode fold (`DecodePlanner`) and #164 look-ahead pre-clamp.
