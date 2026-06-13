# IIIF tiles & sizes (Phase 4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Emit a IIIF `tiles` scheme and `sizes` ladder in `info.json` (computed from source dimensions) and verify deep-zoom viewers (OpenSeadragon) are served correctly.

**Architecture:** A pure `ImagePipe.Parser.IIIF.Tiling` module computes the Cantaloupe-faithful power-of-two pyramid (scale factors bounded by short-side < 64px; one `round`-ed derivative size per factor, smallest-first; one tile entry clamped to the source). A new `tile_size` config option (default 512) is carried in the info `params` map and consumed at *render* time by `Info.document/2` (dimensions are unknown at parse time). The image request-path is unchanged — OpenSeadragon's `regionByPx` + `sizeByWh` requests are already serviceable; this phase is info.json emission + a deterministic viewer-simulation gate.

**Tech Stack:** Elixir, NimbleOptions (config), StreamData (`ExUnitProperties`), Vix/Image (libvips, test fixtures), Plug.Test (wire tests).

**Spec:** `docs/superpowers/specs/2026-06-13-iiif-tiles-sizes-design.md`

---

## Setup (once, before Task 1)

This is a fresh worktree. Ensure the toolchain is trusted and deps are present:

```bash
mise trust && mise exec -- mix deps.get
```

Sanity-check the IIIF suite compiles/passes today:

```bash
mise exec -- mix test test/parser/iiif/ test/parser/iiif_wire_test.exs test/parser/iiif_test.exs
```
Expected: all green (baseline before changes).

---

## File Structure

- **Create** `lib/image_pipe/parser/iiif/tiling.ex` — pure pyramid math (scale factors, sizes, tile dims). Atom-keyed product-neutral return.
- **Modify** `lib/image_pipe/parser/iiif.ex` — add `tile_size` to the NimbleOptions `@schema`.
- **Modify** `lib/image_pipe/parser/iiif/plan_builder.ex` — add `tile_size` to the info `params` map; fix the stale `@doc`.
- **Modify** `lib/image_pipe/parser/iiif/info.ex` — call `Tiling`, inject `"tiles"`/`"sizes"`.
- **Create** `test/parser/iiif/tiling_test.exs` — unit + property + tautology self-check + OSD-adoption fixture.
- **Modify** `test/parser/iiif/info_test.exs` — add `tile_size` to `@params`; assert `tiles`/`sizes`, incl. orientation swap.
- **Modify** `test/parser/iiif_wire_test.exs` — extend the info.json contract (tiles/sizes present + match + non-default `tile_size`).
- **Create** `test/parser/iiif/openseadragon_sim_test.exs` — viewer-simulation gate (gradient fixture + OSD `getTileUrl` replica + pixel oracle).
- **Create** `test/transform/iiif_tile_decode_test.exs` — perf characterization of `DecodePlanner.open_options/5` for the tile shape.
- **Modify** `docs/iiif_3_support_matrix.md` — tiling subsection (surface), pipeline note (stage/order), verification (behavioral/pixel).

---

## Task 1: `Tiling` module + unit tests

**Files:**
- Create: `lib/image_pipe/parser/iiif/tiling.ex`
- Test: `test/parser/iiif/tiling_test.exs`

- [ ] **Step 1: Write the failing unit tests**

Create `test/parser/iiif/tiling_test.exs`:

```elixir
defmodule ImagePipe.Parser.IIIF.TilingTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.IIIF.Tiling

  test "Cantaloupe reference: 1500x1200, tile 512" do
    result = Tiling.tiles_and_sizes(1500, 1200, 512)

    assert result.scale_factors == [1, 2, 4, 8, 16]
    assert result.tile == %{width: 512, height: 512}
    # round (half-up for positive), smallest-first, full last.
    # 1500/16 = 93.75 -> 94 (floor would give 93 -> proves round).
    assert result.sizes == [
             %{width: 94, height: 75},
             %{width: 188, height: 150},
             %{width: 375, height: 300},
             %{width: 750, height: 600},
             %{width: 1500, height: 1200}
           ]
  end

  test "source smaller than tile in a dimension: tile clamps to source" do
    result = Tiling.tiles_and_sizes(300, 200, 512)

    # short side 200 -> 100, 50<64 at i=1 -> maxRF=1
    assert result.scale_factors == [1, 2]
    assert result.tile == %{width: 300, height: 200}
    assert result.sizes == [%{width: 150, height: 100}, %{width: 300, height: 200}]
  end

  test "tiny sources collapse to a single level" do
    assert Tiling.tiles_and_sizes(64, 64, 512) == %{
             scale_factors: [1],
             tile: %{width: 64, height: 64},
             sizes: [%{width: 64, height: 64}]
           }

    assert Tiling.tiles_and_sizes(1, 1, 512) == %{
             scale_factors: [1],
             tile: %{width: 1, height: 1},
             sizes: [%{width: 1, height: 1}]
           }
  end

  test "extreme aspect ratio: ladder bounded by the short side" do
    # short side 65 -> 32.5<64 at i=0 -> maxRF=0 -> single level
    result = Tiling.tiles_and_sizes(2000, 65, 512)
    assert result.scale_factors == [1]
    assert result.sizes == [%{width: 2000, height: 65}]
    assert result.tile == %{width: 512, height: 65}
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/parser/iiif/tiling_test.exs`
Expected: FAIL — `Tiling.__struct__/...` / `module ImagePipe.Parser.IIIF.Tiling is not available`.

- [ ] **Step 3: Write the module**

Create `lib/image_pipe/parser/iiif/tiling.ex`:

```elixir
defmodule ImagePipe.Parser.IIIF.Tiling do
  @moduledoc """
  Computes the IIIF Image API 3.0 `tiles` scheme and `sizes` ladder for an
  info.json from a source image's display dimensions and a chosen tile size.

  Mirrors the de-facto reference server (Cantaloupe): a power-of-two scale-factor
  ladder whose depth is bounded by the short side dropping below `@min_size`
  (64px), one derivative size per scale factor (`round/1` per axis, smallest-first,
  full size last), and a single tile entry clamped to the source dimensions.

  Returns product-neutral atom-keyed data; `ImagePipe.Parser.IIIF.Info` owns the
  IIIF JSON string-key vocabulary.
  """

  # Short-side floor for the scale-factor ladder (Cantaloupe's DEFAULT_MIN_SIZE).
  @min_size 64

  @type size :: %{width: pos_integer(), height: pos_integer()}
  @type t :: %{scale_factors: [pos_integer(), ...], tile: size(), sizes: [size(), ...]}

  @spec tiles_and_sizes(pos_integer(), pos_integer(), pos_integer()) :: t()
  def tiles_and_sizes(width, height, tile_size)
      when is_integer(width) and width > 0 and
             is_integer(height) and height > 0 and
             is_integer(tile_size) and tile_size > 0 do
    factors = scale_factors(width, height)

    %{
      scale_factors: factors,
      tile: %{width: min(tile_size, width), height: min(tile_size, height)},
      sizes: sizes(width, height, factors)
    }
  end

  # Power-of-two ladder [1, 2, …, 2^maxRF]. `maxRF` = halvings of the short side
  # until it drops below @min_size (Cantaloupe ImageInfoUtil.maxReductionFactor:
  # halve, then test).
  defp scale_factors(width, height) do
    max_rf = max_reduction_factor(min(width, height), 0)
    for i <- 0..max_rf, do: Integer.pow(2, i)
  end

  defp max_reduction_factor(short_side, i) do
    next = short_side / 2.0
    if next < @min_size, do: i, else: max_reduction_factor(next, i + 1)
  end

  # One derivative size per scale factor, smallest-first (largest factor first).
  # `round/1` rounds half away from zero, identical to Java Math.round half-up for
  # positive dimensions (matches Cantaloupe).
  defp sizes(width, height, factors) do
    factors
    |> Enum.reverse()
    |> Enum.map(fn sf -> %{width: round(width / sf), height: round(height / sf)} end)
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- mix test test/parser/iiif/tiling_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/parser/iiif/tiling.ex test/parser/iiif/tiling_test.exs
git commit -m "feat(iiif): Tiling module — Cantaloupe-faithful tiles/sizes math"
```

---

## Task 2: `Tiling` property test + tautology self-check + OSD-adoption fixture

**Files:**
- Test: `test/parser/iiif/tiling_test.exs` (extend)

- [ ] **Step 1: Write the failing property + adoption tests**

Append to `test/parser/iiif/tiling_test.exs`. First add `use ExUnitProperties` directly under `use ExUnit.Case, async: true` at the top of the module, then add:

```elixir
  # Invariants that hold for ALL valid inputs. Deliberately does NOT assert the
  # `round(W/size.width) == sf` round-trip — that is FALSE for some inputs (round
  # then inverse-round can land on sf±1); OSD treats sizes as an optional hint and
  # falls back gracefully. Adoption is checked on fixtures below.
  property "scale factors and sizes obey the universal invariants" do
    check all(
            w <- integer(1..8000),
            h <- integer(1..8000),
            t <- integer(1..2048),
            max_runs: 200
          ) do
      assert ok?(Tiling.tiles_and_sizes(w, h, t), w, h, t)
    end
  end

  test "tautology self-check: a floor-computed ladder is REJECTED by the invariants" do
    # Proves the invariant predicate can actually fail (not vacuously true): a
    # deliberately-wrong (floor instead of round) sizes list must not pass ok?/4.
    %{scale_factors: factors, tile: tile} = Tiling.tiles_and_sizes(1500, 1200, 512)

    wrong =
      %{
        scale_factors: factors,
        tile: tile,
        sizes:
          factors
          |> Enum.reverse()
          |> Enum.map(fn sf -> %{width: floor(1500 / sf), height: floor(1200 / sf)} end)
      }

    # floor gives 93x75 for sf=16 where round gives 94x75 -> invariant rejects it.
    refute ok?(wrong, 1500, 1200, 512)

    # A wrong (non-power-of-two) scale ladder is also rejected.
    bad_factors = %{Tiling.tiles_and_sizes(1500, 1200, 512) | scale_factors: [1, 3, 9]}
    refute ok?(bad_factors, 1500, 1200, 512)
  end

  test "OSD levelSizes adoption holds for representative sources" do
    for {w, h} <- [{1500, 1200}, {1024, 768}, {4000, 3000}] do
      assert osd_adopts?(Tiling.tiles_and_sizes(w, h, 512), w, h),
             "OSD would reject levelSizes for #{w}x#{h}"
    end
  end

  # --- helpers -------------------------------------------------------------

  # The universal invariants (see property doc above).
  defp ok?(%{scale_factors: factors, tile: tile, sizes: sizes}, w, h, t) do
    powers_of_two_from_one = factors == for(i <- 0..(length(factors) - 1), do: Integer.pow(2, i))
    same_length = length(sizes) == length(factors)
    widths_strictly_ascending = strictly_ascending?(Enum.map(sizes, & &1.width))
    largest_is_full = List.last(sizes) == %{width: w, height: h}
    tile_clamped = tile == %{width: min(t, w), height: min(t, h)}

    sizes_match_factors =
      sizes ==
        factors
        |> Enum.reverse()
        |> Enum.map(fn sf -> %{width: round(w / sf), height: round(h / sf)} end)

    powers_of_two_from_one and same_length and widths_strictly_ascending and
      largest_is_full and tile_clamped and sizes_match_factors
  end

  defp strictly_ascending?(list), do: list == Enum.sort(list) and list == Enum.dedup(list)

  # OSD adopts `sizes` as levelSizes only if len == maxLevel+1, len(scaleFactors)
  # == len(sizes), and BOTH axes round-trip to the scale factor (factors reversed,
  # since sizes are smallest-first).
  defp osd_adopts?(%{scale_factors: factors, sizes: sizes}, w, h) do
    max_level = round(:math.log2(List.last(factors)))
    reversed = Enum.reverse(factors)

    length(sizes) == max_level + 1 and length(factors) == length(sizes) and
      sizes
      |> Enum.zip(reversed)
      |> Enum.all?(fn {s, sf} ->
        round(w / s.width) == sf and round(h / s.height) == sf
      end)
  end
```

- [ ] **Step 2: Run to verify behavior**

Run: `mise exec -- mix test test/parser/iiif/tiling_test.exs`
Expected: PASS (property + tautology self-check + adoption fixture all green). The tautology test proves the predicate can fail (the floor list and bad-factor list are rejected).

- [ ] **Step 3: Commit**

```bash
git add test/parser/iiif/tiling_test.exs
git commit -m "test(iiif): Tiling property invariants + tautology guard + OSD adoption"
```

---

## Task 3: Config `tile_size` + params + `Info.document` injection

**Files:**
- Modify: `lib/image_pipe/parser/iiif.ex:27-32` (schema)
- Modify: `lib/image_pipe/parser/iiif/plan_builder.ex:18,22-31`
- Modify: `lib/image_pipe/parser/iiif/info.ex`
- Test: `test/parser/iiif/info_test.exs`

- [ ] **Step 1: Write the failing `Info.document` tests**

Edit `test/parser/iiif/info_test.exs`. Update `@params` to carry `tile_size`, and add two tests:

```elixir
  @params %{
    id: "http://x/iiif/abc",
    level: "level2",
    offers: [],
    formats: [:jpg, :png],
    qualities: [:default, :color, :gray, :bitonal],
    tile_size: 512
  }
```

```elixir
  test "document emits tiles and sizes computed from display dims" do
    # 1000x600 source: short side 600 -> 300,150,75,37.5<64 at i=3 -> [1,2,4,8]
    doc = Info.document(@info, @params)

    assert doc["tiles"] == [%{"width" => 512, "height" => 512, "scaleFactors" => [1, 2, 4, 8]}]

    assert doc["sizes"] == [
             %{"width" => 125, "height" => 75},
             %{"width" => 250, "height" => 150},
             %{"width" => 500, "height" => 300},
             %{"width" => 1000, "height" => 600}
           ]
  end

  test "tiles/sizes use display (orientation-swapped) dims for EXIF 5-8" do
    doc =
      Info.document(
        %SourceInfo{format: :jpeg, width: 1000, height: 600, orientation: 6},
        @params
      )

    # display dims are 600x1000 -> short side 600 -> [1,2,4,8]; tile clamps height to 512
    assert doc["width"] == 600 and doc["height"] == 1000
    assert doc["tiles"] == [%{"width" => 512, "height" => 512, "scaleFactors" => [1, 2, 4, 8]}]
    assert List.last(doc["sizes"]) == %{"width" => 600, "height" => 1000}
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/parser/iiif/info_test.exs`
Expected: FAIL — `doc["tiles"]` is `nil` (and/or `KeyError` on `params.tile_size` once Info is edited). The existing tests using `@params` should still pass after the `tile_size` addition because they don't reference tiles/sizes.

- [ ] **Step 3: Inject tiles/sizes in `Info.document`**

Edit `lib/image_pipe/parser/iiif/info.ex`. Add the alias and the two keys.

Add under the existing `alias ImagePipe.Plan.SourceInfo`:

```elixir
  alias ImagePipe.Parser.IIIF.Tiling
```

Replace the `document/2` body's map literal: after `{w, h} = SourceInfo.display_dimensions(info)`, compute the tiling and add the keys:

```elixir
  def document(%SourceInfo{} = info, params) do
    {w, h} = SourceInfo.display_dimensions(info)
    %{scale_factors: factors, tile: tile, sizes: sizes} = Tiling.tiles_and_sizes(w, h, params.tile_size)

    %{
      "@context" => @context,
      "id" => params.id,
      "type" => "ImageService3",
      "protocol" => "http://iiif.io/api/image",
      "profile" => params.level,
      "width" => w,
      "height" => h,
      "tiles" => [%{"width" => tile.width, "height" => tile.height, "scaleFactors" => factors}],
      "sizes" => Enum.map(sizes, &%{"width" => &1.width, "height" => &1.height}),
      "extraQualities" =>
        params.qualities |> Enum.reject(&(&1 == :default)) |> Enum.map(&to_string/1),
      "extraFormats" =>
        params.formats |> Enum.reject(&(&1 in [:jpg, :png])) |> Enum.map(&to_string/1),
      "extraFeatures" => @extra_features
    }
  end
```

- [ ] **Step 4: Add `tile_size` to the config schema**

Edit `lib/image_pipe/parser/iiif.ex`, in `@schema` (after the `qualities:` line):

```elixir
            qualities: [type: {:list, :atom}, default: [:default, :color, :gray, :bitonal]],
            tile_size: [type: :pos_integer, default: 512]
```

- [ ] **Step 5: Carry `tile_size` into the info params + fix stale doc**

Edit `lib/image_pipe/parser/iiif/plan_builder.ex`. Change the `@doc` opts line (line 18) from:

```
  `opts` accepts `max_width`, `max_height`, `max_area`, `formats`, `qualities`.
```
to:
```
  `opts` accepts `formats`, `qualities`, `tile_size`.
```

And add `tile_size` to the `params` map (after the `qualities:` entry):

```elixir
      qualities: Keyword.get(opts, :qualities, [:default, :color, :gray, :bitonal]),
      tile_size: Keyword.get(opts, :tile_size, 512)
```

- [ ] **Step 6: Run to verify it passes**

Run: `mise exec -- mix test test/parser/iiif/info_test.exs test/parser/iiif/plan_builder_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/parser/iiif.ex lib/image_pipe/parser/iiif/plan_builder.ex \
        lib/image_pipe/parser/iiif/info.ex test/parser/iiif/info_test.exs
git commit -m "feat(iiif): emit tiles/sizes in info.json + tile_size config option"
```

---

## Task 4: Wire test — info.json carries tiles/sizes end-to-end

**Files:**
- Test: `test/parser/iiif_wire_test.exs` (extend; OriginImage is 200×300)

- [ ] **Step 1: Write the failing wire assertions**

Add a new test after contract 5 in `test/parser/iiif_wire_test.exs`. The `iiif_opts/1` helper hardcodes the resolver; add a second helper for a non-default tile size and a test:

```elixir
  defp iiif_opts_tile(origin_plug, tile_size) do
    [
      parser: ImagePipe.Parser.IIIF,
      iiif: [resolver: static_resolver(), tile_size: tile_size],
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin_plug]}
      ]
    ]
  end

  test "contract 5b: info.json emits tiles/sizes from source dims" do
    conn = call_iiif("/img/info.json", iiif_opts(OriginImage))
    json = JSON.decode!(conn.resp_body)

    # 200x300 source, default tile 512: short side 200 -> 100, 50<64 at i=1 -> [1,2]
    assert json["tiles"] == [%{"width" => 200, "height" => 300, "scaleFactors" => [1, 2]}]

    assert json["sizes"] == [
             %{"width" => 100, "height" => 150},
             %{"width" => 200, "height" => 300}
           ]
  end

  test "contract 5c: non-default tile_size flows to tiles[].width" do
    conn = call_iiif("/img/info.json", iiif_opts_tile(OriginImage, 128))
    json = JSON.decode!(conn.resp_body)

    # tile clamps to min(128, dim): width 128, height 128 (both < 200/300)
    assert [%{"width" => 128, "height" => 128, "scaleFactors" => factors}] = json["tiles"]
    # short side 200 -> [1,2] regardless of tile size (ladder is dimension-only)
    assert factors == [1, 2]
  end
```

- [ ] **Step 2: Run to verify the end-to-end path**

Run: `mise exec -- mix test test/parser/iiif_wire_test.exs`
Expected: the two new tests PASS — this is an end-to-end confirmation of behavior wired in Task 3, not a red step (the consumer already exists). If `iiif_opts_tile` collides with an existing name, rename it.

- [ ] **Step 3: Commit**

```bash
git add test/parser/iiif_wire_test.exs
git commit -m "test(iiif): wire-level info.json tiles/sizes + non-default tile_size"
```

---

## Task 5: Viewer-simulation gate (OpenSeadragon)

**Files:**
- Create: `test/parser/iiif/openseadragon_sim_test.exs`

This is the deterministic stand-in for a real viewer. The OSD `getTileUrl` replica is the **stimulus generator**; an independent gradient-derived expectation is the **oracle** (no shared resize code).

- [ ] **Step 1: Write the gate**

Create `test/parser/iiif/openseadragon_sim_test.exs`:

```elixir
defmodule ImagePipe.Parser.IIIF.OpenSeadragonSimTest do
  @moduledoc """
  Replicates OpenSeadragon's IIIF v3 getTileUrl algorithm (src/iiiftilesource.js)
  to drive a full pan/zoom tile traversal against a live ImagePipe IIIF endpoint,
  then verifies the served tiles. The OSD replica is the STIMULUS generator; an
  independent 2D-gradient expectation (NOT the ImagePipe planner / resize path)
  is the ORACLE.

  Note on fidelity: the replica computes `level_w = ceil(W*scale)`. The real OSD,
  once it adopts our `sizes` as `levelSizes`, reads the level dims from `sizes`
  instead — but the two coincide at every level for this fixture, so the replica
  is behaviorally faithful here.
  """
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Parser.IIIF.CORS
  alias ImagePipe.Parser.IIIF.Resolver.Static, as: StaticResolver
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.SourceTest.RootHTTPAdapter

  @w 1024
  @h 768

  # --- 2D-gradient origin: pixel(x,y) ~ [255*x/(w-1), 0, 255*y/(h-1)] ----------
  # A served tile from source region (xr,yr,wr,hr) decodes so its corners track
  # the region's source corners — independent of any resize kernel.
  defmodule GradientOrigin do
    def init(opts), do: opts

    def call(conn, _opts) do
      w = 1024
      h = 768
      ramp = Vix.Vips.Operation.xyz!(w, h)
      scaled = Vix.Vips.Operation.linear!(ramp, [255.0 / (w - 1), 255.0 / (h - 1)], [0.0, 0.0])
      g = Vix.Vips.Operation.black!(w, h)
      rgb = Vix.Vips.Operation.bandjoin!([scaled[0], g, scaled[1]])
      uchar = Vix.Vips.Operation.cast!(rgb, :VIPS_FORMAT_UCHAR)
      {:ok, body} = Vix.Vips.Image.write_to_buffer(uchar, ".png")

      conn |> put_resp_content_type("image/png") |> send_resp(200, body)
    end
  end

  defp opts do
    [
      parser: ImagePipe.Parser.IIIF,
      iiif: [resolver: {StaticResolver, map: %{"grad" => %SourcePath{segments: ["grad.png"]}}}],
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: GradientOrigin]}
      ]
    ]
  end

  defp call_iiif(path) do
    initialized = ImagePipe.Plug.init(opts())
    conn = :get |> conn(path) |> Map.put(:script_name, ["iiif"])
    cors = CORS.call(conn, CORS.init([]))
    if cors.halted, do: cors, else: ImagePipe.Plug.call(cors, initialized)
  end

  # --- OSD getTileUrl replica (per iiiftilesource.js, v3) ----------------------
  # Each tile -> a uniform map: %{region, size, w, h, src: {xr,yr,wr,hr}} where
  # (w,h) is the served output size and `src` is the SOURCE region the tile covers
  # (full image for the single-tile branch). Uniform maps avoid fragile
  # positional tuples.
  defp osd_tiles(info) do
    [%{"width" => tile_w} = tile] = info["tiles"]
    tile_h = Map.get(tile, "height", tile_w)
    factors = tile["scaleFactors"]
    max_level = round(:math.log2(Enum.max(factors)))

    Enum.flat_map(0..max_level, &level_requests(&1, max_level, tile_w, tile_h))
  end

  defp level_requests(level, max_level, tile_w, tile_h) do
    scale = :math.pow(0.5, max_level - level)
    level_w = ceil(@w * scale)
    level_h = ceil(@h * scale)

    if level_w < tile_w and level_h < tile_h do
      # Single-tile branch: whole (downscaled) image fits one tile -> region full.
      # The `max` arm is unreachable for sources LARGER than the tile (level_w<tile_w
      # implies level_w<@w); it mirrors OSD's guard for sub-tile sources.
      size = if level_w == @w and level_h == @h, do: "max", else: "#{level_w},#{level_h}"
      [%{region: "full", size: size, w: level_w, h: level_h, src: {0, 0, @w, @h}}]
    else
      iiif_tile_w = round(tile_w / scale)
      iiif_tile_h = round(tile_h / scale)
      cols = ceil(level_w / tile_w)
      rows = ceil(level_h / tile_h)

      for x <- 0..(cols - 1), y <- 0..(rows - 1) do
        tile_x = x * iiif_tile_w
        tile_y = y * iiif_tile_h
        region_w = min(iiif_tile_w, @w - tile_x)
        region_h = min(iiif_tile_h, @h - tile_y)

        region =
          if x == 0 and y == 0 and region_w == @w and region_h == @h,
            do: "full",
            else: "#{tile_x},#{tile_y},#{region_w},#{region_h}"

        size_w = min(tile_w, level_w - x * tile_w)
        size_h = min(tile_h, level_h - y * tile_h)
        size = if size_w == @w and size_h == @h, do: "max", else: "#{size_w},#{size_h}"
        %{region: region, size: size, w: size_w, h: size_h, src: {tile_x, tile_y, region_w, region_h}}
      end
    end
  end

  setup do
    info = JSON.decode!(call_iiif("/grad/info.json").resp_body)
    {:ok, info: info}
  end

  # Single gate loop: fire each tile ONCE; assert status + served dims + the
  # independent pixel oracle (TL, center, BR). Covers both OSD branches and the
  # full pan/zoom traversal. For 1024x768/512 (factors [1,2,4,8], maxLevel=3):
  #   level 0 (sf8): single-tile full / 128,96
  #   level 1 (sf4): single-tile full / 256,192
  #   level 2 (sf2): TILED, 1x1 grid, region=full / 512,384  (full region, downscaled)
  #   level 3 (sf1): TILED, 2x2 grid -> (0,0) interior, (1,0) right edge,
  #                  (0,1) bottom edge, (1,1) bottom-right corner (512,256 clamps)
  test "OSD traversal: every tile served 200 with correct dims + source geometry",
       %{info: info} do
    for %{region: region, size: size, w: sw, h: sh, src: {xr, yr, wr, hr}} <- osd_tiles(info) do
      conn = call_iiif("/grad/#{region}/#{size}/0/default.png")
      assert conn.status == 200, "#{region}/#{size} -> #{conn.status}"

      img = Image.open!(conn.resp_body, access: :random, fail_on: :error)
      assert {Image.width(img), Image.height(img)} == {sw, sh},
             "#{region}/#{size}: served #{Image.width(img)}x#{Image.height(img)}, expected #{sw}x#{sh}"

      # Oracle: expected gradient values at TL / center / BR, derived from the
      # SOURCE region geometry (red tracks x, blue tracks y). No resize involved.
      [tl_r, _, tl_b | _] = Image.get_pixel!(img, 0, 0)
      [c_r, _, c_b | _] = Image.get_pixel!(img, div(sw, 2), div(sh, 2))
      [br_r, _, br_b | _] = Image.get_pixel!(img, sw - 1, sh - 1)

      assert_close(tl_r, 255 * xr / (@w - 1), "tl red @ #{region}")
      assert_close(tl_b, 255 * yr / (@h - 1), "tl blue @ #{region}")
      assert_close(c_r, 255 * (xr + wr / 2) / (@w - 1), "center red @ #{region}")
      assert_close(c_b, 255 * (yr + hr / 2) / (@h - 1), "center blue @ #{region}")
      assert_close(br_r, 255 * (xr + wr - 1) / (@w - 1), "br red @ #{region}")
      assert_close(br_b, 255 * (yr + hr - 1) / (@h - 1), "br blue @ #{region}")

      # Edge/corner tiles must be clamped, not the full tile size.
      if wr < 512, do: assert(sw < 512)
      if hr < 512, do: assert(sh < 512)
    end
  end

  test "single-tile branch yields region=full with a downscaled w,h size", %{info: info} do
    # level 0 (sf=8) -> 128x96 single tile, region full (no HTTP call needed).
    assert Enum.any?(osd_tiles(info), &match?(%{region: "full", size: "128,96"}, &1))
  end

  # Downscale averaging shifts corner samples inward; ±24 catches off-by-a-tile
  # (which shifts by ~128) and unclamped edges while tolerating resize blur.
  defp assert_close(actual, expected, label) do
    assert abs(actual - expected) <= 24,
           "#{label}: got #{actual}, expected ~#{Float.round(expected * 1.0, 1)}"
  end
end
```

- [ ] **Step 2: Run the gate**

Run: `mise exec -- mix test test/parser/iiif/openseadragon_sim_test.exs`
Expected: PASS. If the gradient fixture build fails (Vix API mismatch), fix the `GradientOrigin.call/2` construction in iex (`mise exec -- iex -S mix`) until `Vix.Vips.Image.write_to_buffer(uchar, ".png")` returns valid PNG bytes, keeping the band semantics (band 0 = x ramp, band 2 = y ramp). If a corner-sample tolerance trips, widen `assert_close` to ±32 — but first confirm the region geometry is right (a tile-offset bug shifts by ~128, far beyond any reasonable tolerance).

- [ ] **Step 3: Commit**

```bash
git add test/parser/iiif/openseadragon_sim_test.exs
git commit -m "test(iiif): OpenSeadragon viewer-simulation gate (tile pan/zoom)"
```

---

## Task 6: Perf characterization — shrink-on-load for the tile shape

**Files:**
- Create: `test/transform/iiif_tile_decode_test.exs`

This task verifies the perf claim by testing the in-repo producer (`DecodePlanner`) directly — no telemetry hook. The plan review **ran** this probe: for the tile shape, `open_options` returns `[access: :sequential, fail_on: :error, shrink: 4]` — shrink-on-load **engages** (factor 4). Pin that.

- [ ] **Step 1: Write the failing test**

Create `test/transform/iiif_tile_decode_test.exs`:

```elixir
defmodule ImagePipe.Transform.IIIFTileDecodeTest do
  @moduledoc """
  Verifies a IIIF tile request (region crop + downscale) engages shrink-on-load.
  DecodePlanner is the in-repo producer of the decode load options; we assert its
  actual output rather than inventing a telemetry hook.
  """
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Operation
  alias ImagePipe.Transform.DecodePlanner

  test "tile region+downscale engages shrink-on-load" do
    # OSD tile at scale factor 8 against a 6000x4000 source: crop a 4096x4096
    # region, downscale to a 512x512 tile.
    {:ok, crop} = Operation.crop_region({:px, 0}, {:px, 0}, {:px, 4096}, {:px, 4096})
    {:ok, resize} = Operation.resize(:stretch, {:px, 512}, {:px, 512})

    opts = DecodePlanner.open_options([crop, resize], :jpeg, {6000, 4000})

    assert Keyword.get(opts, :access) == :sequential
    # Shrink-on-load fires for the crop-then-downscale tile shape: the source is
    # decoded at 1/4 resolution rather than full-res. (Observed factor: 4.)
    assert Keyword.get(opts, :shrink) == 4
  end
end
```

- [ ] **Step 2: Run to verify it passes**

Run: `mise exec -- mix test test/transform/iiif_tile_decode_test.exs`
Expected: PASS. If the observed `:shrink` value differs from 4 (e.g. a planner change), pin the actual observed value and update the comment — do not assert a value you did not observe.

- [ ] **Step 3: Commit**

```bash
git add test/transform/iiif_tile_decode_test.exs
git commit -m "test(iiif): characterize decode load options for the tile access pattern"
```

---

## Task 7: Documentation — support matrix

**Files:**
- Modify: `docs/iiif_3_support_matrix.md`

- [ ] **Step 1: Add the tiling subsection (surface axis)**

In `docs/iiif_3_support_matrix.md`, under the `## info.json` section (after the existing field table), add:

```markdown
### Tiling (`tiles` / `sizes`)

Emitted from the **display** dimensions (`SourceInfo.display_dimensions/1`, so EXIF 5–8 sources use swapped dims) by `ImagePipe.Parser.IIIF.Tiling`:

- **`scaleFactors`** — power-of-two ladder `1,2,4,…,2^maxRF`, where `maxRF` = halvings of the **short side** until it drops below **64px** (Cantaloupe's `minSize`). Dimension-only; independent of `tile_size`.
- **`sizes`** — one `{round(W/sf), round(H/sf)}` per scale factor, `round`-half-up (matches Java `Math.round` for positive dims), **smallest-first, full-size last**.
- **`tiles`** — a single entry `{width: min(tile_size, W), height: min(tile_size, H), scaleFactors}`.

**Config:** `iiif: [tile_size: 512]` (default 512). Worked example — 1500×1200/512 → `scaleFactors [1,2,4,8,16]`, `tiles [{512,512,…}]`, `sizes [94×75 … 1500×1200]`.

**Divergence (mechanism, not pixels):** Cantaloupe derives the tile dimension from a separate request-independent `minTileSize`; we use one `tile_size` knob that sets the advertised tile dim directly. Numbers coincide at the 512 default. The IIIF implementation-notes edge round-up (`(width−xr+s−1)/s`) is an equivalent formulation of OpenSeadragon's edge math for power-of-two scale factors; the viewer-sim gate follows OpenSeadragon (the binding client). Granular tiling config (tile_width/height, explicit scale_factors/sizes, configurable minSize) is deferred (follow-up).
```

- [ ] **Step 2: Add the stage/order note**

In the `## HTTP behavior` / pipeline area (or the processing-order section), add a row/note:

```markdown
- **Tiled region extraction** — tiled `{x,y,w,h}/{w,h}` requests reuse the existing region-crop + resize path (`regionByPx` + `sizeByWh` → `:stretch`); there is no IIIF-specific tiling stage. Shrink-on-load **engages** for the crop+downscale tile shape (verified: a deep-scale-factor tile decodes the source at reduced resolution — `DecodePlanner` returns `shrink: 4` for a 4096-region→512 tile from a 6000×4000 source; see `test/transform/iiif_tile_decode_test.exs`). End-to-end memory high-water + info/derivative caching are tracked as a follow-up.
```

- [ ] **Step 3: Update Verification**

In the `## Verification` section, add:

```markdown
- **Tiling unit/property:** `test/parser/iiif/tiling_test.exs` — Cantaloupe reference values, universal invariants with a tautology self-check, OSD `levelSizes` adoption on representative sources.
- **Viewer-simulation gate:** `test/parser/iiif/openseadragon_sim_test.exs` — replicates OpenSeadragon's `getTileUrl` to drive a full tile traversal through `ImagePipe.call/2`, asserting status + decoded dims for every tile and an independent gradient-derived pixel oracle for interior/edge/corner tiles at multiple scale factors.
```

- [ ] **Step 4: Commit**

```bash
git add docs/iiif_3_support_matrix.md
git commit -m "docs(iiif): document tiles/sizes tiling scheme + viewer-sim gate"
```

---

## Task 8: Full gate + follow-up issues

**Files:** none (verification + issue filing)

- [ ] **Step 1: Run the Elixir gate**

Run: `mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, and `mix test` all pass. Fix any formatting/credo findings the new code introduced.

- [ ] **Step 2: Confirm no architecture-boundary regressions**

Run: `mise exec -- mix test test/image_pipe/architecture_boundary_test.exs`
Expected: PASS — `Tiling` is inside the IIIF parser boundary and introduces no cross-boundary reference.

- [ ] **Step 3: File the three follow-up issues**

(Confirm with the user whether to file now or after merge.) Then:

```bash
gh issue create --title "IIIF: configurable tiling (tile_width/height, explicit scale_factors/sizes, minSize)" \
  --label "compat:iiif,enhancement" \
  --body "Follow-up to #256. Today a single \`tile_size\` (default 512) drives the advertised tile dim and the scale-factor ladder uses a fixed 64px minSize. Expose granular config: separate tile_width/height, explicit scale_factors and sizes overrides, and a configurable minSize. The \`ImagePipe.Parser.IIIF.Tiling\` module already isolates the math."

gh issue create --title "IIIF: fiddle OpenSeadragon demo + headless pan/zoom check" \
  --label "compat:iiif,area:tests" \
  --body "Follow-up to #256. Add a real OpenSeadragon page to the fiddle pointing at a live ImagePipe IIIF endpoint, and an optional headless-browser (Playwright) gate driving pan/zoom. The deterministic Elixir viewer-simulation gate (test/parser/iiif/openseadragon_sim_test.exs) already covers the request contract; this adds real-viewer human/visual verification."

gh issue create --title "IIIF: info-response/derivative caching + tile-pattern memory high-water benchmark" \
  --label "compat:iiif,type:performance" \
  --body "Follow-up to #256. The Phase 4 perf pass characterized decode load options for the tile shape (test/transform/iiif_tile_decode_test.exs) but the end-to-end memory high-water for a tile traversal is unmeasured, and info-response/derivative caching is not implemented. Add a memory benchmark for the tile access pattern and design info/derivative caching."
```

- [ ] **Step 4: Final verification before handoff**

Run: `mise exec -- mix test`
Expected: full suite green. The branch is ready to rename (descriptive name, e.g. `feat/iiif-tiles-sizes`) and push.

---

## Self-review notes

- **Spec coverage:** tiles/sizes emission (Tasks 1,3,4), Cantaloupe-faithful algorithm + round/ordering (Task 1), property + tautology self-check + OSD adoption (Task 2), `tile_size` config (Task 3), orientation via display dims (Tasks 3,4), viewer-sim gate with independent oracle + both OSD branches + edge/corner (Task 5), perf via `open_options/5` not telemetry (Task 6), support-matrix surface/stage/behavioral axes (Task 7), three follow-ups (Task 8). All spec sections map to a task.
- **No request-path changes:** confirmed — OSD's `regionByPx`+`sizeByWh` are already served; the sim gate exercises the existing path.
- **Type consistency:** `Tiling.tiles_and_sizes/3` returns `%{scale_factors, tile: %{width,height}, sizes: [%{width,height}]}` everywhere it's consumed (Info.document, tests). `Info.document/2` reads `params.tile_size` (always set by `info_plan/3`; tests updated).
```
