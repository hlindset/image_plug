# IIIF Phase 2B — Parser, info.json, CORS/redirect, docs & validator gate

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `ImagePipe.Parser.IIIF` (IIIF Image API 3.0, Level 2) — positional grammar → `ImagePipe.Plan`, `info.json` via the Phase 1 `Renderer`, base-URI 303, CORS, optional canonical `Link` — and gate it with the official Python `image-validator`.

**Architecture:** A new parser mirroring `ImagePipe.Parser.Imgproxy`'s sub-module decomposition, consuming the Phase 2A primitives (`gray`, `Resize :reject`, `{:bad_request}`→400, `{:redirect,…}`, render `offers`). Identifier→Source goes through a small `Resolver` behaviour (Static built-in). `info.json` rides the existing render path with a parser-supplied `offers` param.

**Tech Stack:** Elixir, `Plug`, `NimbleOptions`, `ExUnit`/`StreamData`, `Boundary`; Docker + docker-compose for the validator gate. Run via `mise exec -- mix …`.

**Depends on:** Phase 2A (`docs/superpowers/plans/2026-06-13-iiif-phase-2a-native-primitives.md`) — must be merged/available first.
**Spec:** `docs/superpowers/specs/2026-06-13-iiif-phase-2-design.md`.
**Template:** `lib/image_pipe/parser/imgproxy/**` and `test/parser/imgproxy_test.exs` — read these; the IIIF modules mirror their structure. Reuse imgproxy's source-translation and response/cache plumbing patterns; only the grammar, dispatch, plan-building, resolver, and info renderer are IIIF-specific.

**Conventions:** focused tests via `mise exec -- mix test <file>`; before each commit `mise exec -- mix compile --warnings-as-errors` + `mise exec -- mix format`. Boundary: all `ImagePipe.Parser.IIIF.*` modules live under the parser boundary and must **not** alias concrete `ImagePipe.Transform.Operation.*` modules — emit `ImagePipe.Plan.Operation.*` only.

---

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `lib/image_pipe/parser/iiif/resolver.ex` | `@behaviour` `resolve/2` | B1 |
| `lib/image_pipe/parser/iiif/resolver/static.ex` | static-map resolver | B1 |
| `lib/image_pipe/parser/iiif/path.ex` | dispatch by segment count; base-URI; quality.format split | B2 |
| `lib/image_pipe/parser/iiif/grammar.ex` | region/size/rotation/quality/format token parsers | B3 |
| `lib/image_pipe/parser/iiif/parsed_request.ex` | intermediate struct | B4 |
| `lib/image_pipe/parser/iiif/plan_builder.ex` | ParsedRequest → Plan / render / redirect | B4 |
| `lib/image_pipe/parser/iiif/info.ex` | builds the info.json document map | B6 |
| `lib/image_pipe/parser/iiif/info_renderer.ex` | `@behaviour Renderer` | B6 |
| `lib/image_pipe/parser/iiif.ex` | `@behaviour Parser`: `parse/2`, `handle_error/2`, `validate_options!/1`; CORS | B5, B7 |
| `docs/iiif_3_support_matrix.md` | conformance matrix | B9 |
| `test/parser/iiif_test.exs`, `test/parser/iiif/*_test.exs` | parser unit + property | B2–B6 |
| `test/parser/iiif_wire_test.exs` | wire-level Plug tests | B8 |
| `test/support/fixtures/iiif/67352ccc-…` | committed validator reference image | B10 |
| `validator/Dockerfile`, `validator/docker-compose.yml`, `mise.toml` task, CI workflow | validator gate | B10 |

---

## Task B1: Resolver behaviour + Static built-in

**Files:**
- Create: `lib/image_pipe/parser/iiif/resolver.ex`, `lib/image_pipe/parser/iiif/resolver/static.ex`
- Test: `test/parser/iiif/resolver_static_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ImagePipe.Parser.IIIF.Resolver.StaticTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.IIIF.Resolver.Static
  alias ImagePipe.Plan.Source.Path, as: SourcePath

  @map %{"abc" => %SourcePath{segments: ["images", "beach.jpg"]}}

  test "resolves a known identifier to its configured source" do
    assert {:ok, %SourcePath{segments: ["images", "beach.jpg"]}} = Static.resolve("abc", map: @map)
  end

  test "unknown identifier -> {:error, :not_found}" do
    assert {:error, :not_found} = Static.resolve("nope", map: @map)
  end
end
```

- [ ] **Step 2: Run it (FAIL: module undefined).**

`mise exec -- mix test test/parser/iiif/resolver_static_test.exs`

- [ ] **Step 3: Implement the behaviour + Static resolver**

`lib/image_pipe/parser/iiif/resolver.ex`:

```elixir
defmodule ImagePipe.Parser.IIIF.Resolver do
  @moduledoc """
  Host extension point mapping an opaque IIIF identifier to a product-neutral
  `ImagePipe.Plan.Source`. Configured via `iiif: [resolver: {Module, opts}]`.
  """

  @callback resolve(identifier :: String.t(), opts :: keyword()) ::
              {:ok, ImagePipe.Plan.Source.t()} | {:error, term()}
end
```

`lib/image_pipe/parser/iiif/resolver/static.ex`:

```elixir
defmodule ImagePipe.Parser.IIIF.Resolver.Static do
  @moduledoc """
  Resolves an identifier from a static `%{identifier => Plan.Source.t()}` map.
  Opaque IDs, no source-structure leakage. Unknown id -> `{:error, :not_found}`.
  """

  @behaviour ImagePipe.Parser.IIIF.Resolver

  @impl true
  def resolve(identifier, opts) when is_binary(identifier) do
    map = Keyword.fetch!(opts, :map)

    case Map.fetch(map, identifier) do
      {:ok, %_{} = source} -> {:ok, source}
      :error -> {:error, :not_found}
    end
  end
end
```

- [ ] **Step 4: Run it (PASS). Commit.**

```bash
git add lib/image_pipe/parser/iiif/resolver.ex lib/image_pipe/parser/iiif/resolver/static.ex test/parser/iiif/resolver_static_test.exs
git commit -m "feat(iiif): resolver behaviour + static-map resolver"
```

---

## Task B2: Path dispatch, base-URI, quality.format split

**Files:**
- Create: `lib/image_pipe/parser/iiif/path.ex`
- Test: `test/parser/iiif/path_test.exs`

`conn.path_info` is the post-mount remainder; `conn.script_name` is the mount prefix. The IIIF endpoint is selected by **exact segment count**.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ImagePipe.Parser.IIIF.PathTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias ImagePipe.Parser.IIIF.Path

  defp conn_for(path), do: conn(:get, path)

  test "single segment -> :redirect with absolute info.json location" do
    conn = %{conn_for("/abc") | script_name: ["iiif"]}
    assert {:redirect, "abc", location} = Path.classify(conn)
    assert String.ends_with?(location, "/iiif/abc/info.json")
  end

  test "two segments ending in info.json -> :info" do
    assert {:info, "abc"} = Path.classify(conn_for("/abc/info.json"))
  end

  test "four segments -> :image with split quality.format" do
    assert {:image, "abc", %{region: "full", size: "max", rotation: "0", quality: "default", format: "jpg"}} =
             Path.classify(conn_for("/abc/full/max/0/default.jpg"))
  end

  test "unescaped-slash identifier (extra segment) -> :not_found" do
    assert :not_found = Path.classify(conn_for("/a/b/full/max/0/default.jpg"))
  end
end
```

- [ ] **Step 2: Run it (FAIL).**

- [ ] **Step 3: Implement `Path`**

```elixir
defmodule ImagePipe.Parser.IIIF.Path do
  @moduledoc """
  Dispatches an IIIF request by exact `conn.path_info` segment count and
  reconstructs the absolute base URI (for the info.json `id` and base redirect).
  """

  @spec classify(Plug.Conn.t()) ::
          {:redirect, String.t(), String.t()}
          | {:info, String.t()}
          | {:image, String.t(), map()}
          | :not_found
  def classify(%Plug.Conn{path_info: [id]} = conn),
    do: {:redirect, decode(id), base_uri(conn) <> "/" <> id <> "/info.json"}

  def classify(%Plug.Conn{path_info: [id, "info.json"]}),
    do: {:info, decode(id)}

  def classify(%Plug.Conn{path_info: [id, region, size, rotation, quality_format]}) do
    case split_quality_format(quality_format) do
      {:ok, quality, format} ->
        {:image, decode(id),
         %{region: region, size: size, rotation: rotation, quality: quality, format: format}}

      :error ->
        :not_found
    end
  end

  def classify(%Plug.Conn{}), do: :not_found

  @doc "Absolute base URI up to and including the mount prefix (no trailing slash)."
  @spec base_uri(Plug.Conn.t()) :: String.t()
  def base_uri(%Plug.Conn{} = conn) do
    authority = conn.host <> port_suffix(conn.scheme, conn.port)
    prefix = conn.script_name |> Enum.map(&("/" <> &1)) |> Enum.join()
    "#{conn.scheme}://#{authority}#{prefix}"
  end

  defp split_quality_format(segment) do
    case String.split(segment, ".") do
      parts when length(parts) >= 2 ->
        format = List.last(parts)
        quality = parts |> Enum.drop(-1) |> Enum.join(".")
        if quality == "" or format == "", do: :error, else: {:ok, quality, format}

      _ ->
        :error
    end
  end

  defp port_suffix("http", 80), do: ""
  defp port_suffix("https", 443), do: ""
  defp port_suffix(_scheme, port), do: ":#{port}"

  defp decode(segment), do: URI.decode(segment)
end
```

- [ ] **Step 4: Run it (PASS). Commit.**

```bash
git add lib/image_pipe/parser/iiif/path.ex test/parser/iiif/path_test.exs
git commit -m "feat(iiif): path dispatch + base-URI reconstruction"
```

---

## Task B3: Grammar — region/size/rotation/quality/format token parsers

**Files:**
- Create: `lib/image_pipe/parser/iiif/grammar.ex`
- Test: `test/parser/iiif/grammar_test.exs` (+ a property test for `pct` ratio conversion)

Each parser returns `{:ok, value}` or `{:error, {:invalid_<part>, raw}}`. The value types are consumed by the PlanBuilder (B4):

- region → `:full | :square | {:px, x,y,w,h} | {:pct, xr,yr,wr,hr}` where each ratio is `{:ratio, n, d}`
- size → `{:max, upscale?} | {:w, w, up?} | {:h, h, up?} | {:wh, w, h, up?} | {:confined, w, h, up?} | {:pct, ratio, up?}`
- rotation → `0 | 90 | 180 | 270`
- quality → `:default | :color | :gray`
- format → `:jpg | :png | :webp | :avif`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ImagePipe.Parser.IIIF.GrammarTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Parser.IIIF.Grammar

  test "region" do
    assert Grammar.region("full") == {:ok, :full}
    assert Grammar.region("square") == {:ok, :square}
    assert Grammar.region("0,10,200,300") == {:ok, {:px, 0, 10, 200, 300}}
    assert {:ok, {:pct, {:ratio, 105, 1000}, _, _, _}} = Grammar.region("pct:10.5,0,50,50")
    assert {:error, {:invalid_region, "0,0,0,300"}} = Grammar.region("0,0,0,300")  # zero w
    assert {:error, {:invalid_region, "garbage"}} = Grammar.region("garbage")
  end

  test "size + ^ upscaling flag" do
    assert Grammar.size("max") == {:ok, {:max, false}}
    assert Grammar.size("^max") == {:ok, {:max, true}}
    assert Grammar.size("200,") == {:ok, {:w, 200, false}}
    assert Grammar.size(",300") == {:ok, {:h, 300, false}}
    assert Grammar.size("200,300") == {:ok, {:wh, 200, 300, false}}
    assert Grammar.size("!200,300") == {:ok, {:confined, 200, 300, false}}
    assert {:ok, {:pct, {:ratio, 50, 100}, false}} = Grammar.size("pct:50")
    assert {:ok, {:pct, {:ratio, 200, 100}, true}} = Grammar.size("^pct:200")
    assert {:error, {:invalid_size, "pct:200"}} = Grammar.size("pct:200")  # >100 needs ^
    assert {:error, {:invalid_size, "0,0"}} = Grammar.size("0,0")
  end

  test "rotation / quality / format" do
    assert Grammar.rotation("0") == {:ok, 0}
    assert Grammar.rotation("90") == {:ok, 90}
    assert {:error, {:invalid_rotation, "45"}} = Grammar.rotation("45")
    assert {:error, {:invalid_rotation, "!90"}} = Grammar.rotation("!90")  # mirroring deferred
    assert Grammar.quality("gray") == {:ok, :gray}
    assert {:error, {:invalid_quality, "bitonal"}} = Grammar.quality("bitonal")
    assert Grammar.format("jpg") == {:ok, :jpg}
    assert {:error, {:invalid_format, "tif"}} = Grammar.format("tif")
  end

  property "pct percentages convert to exact integer ratios" do
    check all n <- integer(0..10_000) do
      decimal = n / 100
      {:ok, {:ratio, num, den}} = Grammar.pct_to_ratio(Float.to_string(decimal))
      assert num / den == decimal
    end
  end
end
```

- [ ] **Step 2: Run it (FAIL).**

- [ ] **Step 3: Implement `Grammar`**

```elixir
defmodule ImagePipe.Parser.IIIF.Grammar do
  @moduledoc "Parses IIIF positional tokens into typed values for the PlanBuilder."

  @formats %{"jpg" => :jpg, "png" => :png, "webp" => :webp, "avif" => :avif}
  @qualities %{"default" => :default, "color" => :color, "gray" => :gray}

  # --- region ---------------------------------------------------------------
  def region("full"), do: {:ok, :full}
  def region("square"), do: {:ok, :square}

  def region("pct:" <> rest = raw) do
    with [x, y, w, h] <- String.split(rest, ","),
         {:ok, xr} <- pct_to_ratio(x),
         {:ok, yr} <- pct_to_ratio(y),
         {:ok, {:ratio, wn, _} = wr} when wn > 0 <- pct_to_ratio(w),
         {:ok, {:ratio, hn, _} = hr} when hn > 0 <- pct_to_ratio(h) do
      {:ok, {:pct, xr, yr, wr, hr}}
    else
      _ -> {:error, {:invalid_region, raw}}
    end
  end

  def region(raw) do
    with [x, y, w, h] <- String.split(raw, ","),
         {x, ""} <- Integer.parse(x),
         {y, ""} <- Integer.parse(y),
         {w, ""} when w > 0 <- Integer.parse(w),
         {h, ""} when h > 0 <- Integer.parse(h),
         true <- x >= 0 and y >= 0 do
      {:ok, {:px, x, y, w, h}}
    else
      _ -> {:error, {:invalid_region, raw}}
    end
  end

  # --- size -----------------------------------------------------------------
  def size("^" <> rest), do: size_body(rest, true, "^" <> rest)
  def size(raw), do: size_body(raw, false, raw)

  defp size_body("max", up?, _raw), do: {:ok, {:max, up?}}

  defp size_body("pct:" <> n, up?, raw) do
    with {:ok, {:ratio, num, den}} <- pct_to_ratio(n) do
      cond do
        num <= 0 -> {:error, {:invalid_size, raw}}
        num > den and not up? -> {:error, {:invalid_size, raw}}  # >100 needs ^
        true -> {:ok, {:pct, {:ratio, num, den}, up?}}
      end
    else
      _ -> {:error, {:invalid_size, raw}}
    end
  end

  defp size_body("!" <> wh, up?, raw) do
    with {:ok, w, h} <- two_dims(wh), do: {:ok, {:confined, w, h, up?}}, else: (_ -> {:error, {:invalid_size, raw}})
  end

  defp size_body(body, up?, raw) do
    case String.split(body, ",") do
      [w, ""] -> pos_or_error(w, fn v -> {:w, v, up?} end, raw)
      ["", h] -> pos_or_error(h, fn v -> {:h, v, up?} end, raw)
      [w, h] -> with {:ok, w, h} <- two_dims(w <> "," <> h), do: {:ok, {:wh, w, h, up?}}, else: (_ -> {:error, {:invalid_size, raw}})
      _ -> {:error, {:invalid_size, raw}}
    end
  end

  defp two_dims(wh) do
    with [w, h] <- String.split(wh, ","),
         {w, ""} when w > 0 <- Integer.parse(w),
         {h, ""} when h > 0 <- Integer.parse(h) do
      {:ok, w, h}
    else
      _ -> :error
    end
  end

  defp pos_or_error(s, wrap, raw) do
    case Integer.parse(s) do
      {v, ""} when v > 0 -> {:ok, wrap.(v)}
      _ -> {:error, {:invalid_size, raw}}
    end
  end

  # --- rotation / quality / format -----------------------------------------
  def rotation(raw) do
    case Integer.parse(raw) do
      {n, ""} when n in [0, 90, 180, 270] -> {:ok, n}
      _ -> {:error, {:invalid_rotation, raw}}
    end
  end

  def quality(raw) do
    case Map.fetch(@qualities, raw), do: ({:ok, q} -> {:ok, q}; :error -> {:error, {:invalid_quality, raw}})
  end

  def format(raw) do
    case Map.fetch(@formats, raw), do: ({:ok, f} -> {:ok, f}; :error -> {:error, {:invalid_format, raw}})
  end

  # --- helpers --------------------------------------------------------------
  @doc "Convert a decimal-percent string to an exact integer ratio {:ratio, num, den}."
  @spec pct_to_ratio(String.t()) :: {:ok, {:ratio, non_neg_integer(), pos_integer()}} | :error
  def pct_to_ratio(s) do
    case String.split(s, ".") do
      [int] ->
        case Integer.parse(int) do
          {n, ""} when n >= 0 -> {:ok, {:ratio, n, 100}}
          _ -> :error
        end

      [int, frac] when frac != "" ->
        with {i, ""} when i >= 0 <- Integer.parse(int),
             {f, ""} when f >= 0 <- Integer.parse(frac) do
          den = 100 * pow10(String.length(frac))
          num = (i * pow10(String.length(frac)) + f) * 100
          {:ok, reduce({:ratio, num, den})}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp pow10(0), do: 1
  defp pow10(n), do: 10 * pow10(n - 1)

  defp reduce({:ratio, num, den}) do
    g = Integer.gcd(num, den) |> max(1)
    {:ratio, div(num, g), div(den, g)}
  end
end
```

> Verify the `case … do (… -> …)` inline syntax compiles; if your formatter rejects it, expand to multi-line `case`. The property test asserts exact ratio equality — keep `pct_to_ratio` exact (no floats in the result).

- [ ] **Step 4: Run it (PASS). Commit.**

```bash
git add lib/image_pipe/parser/iiif/grammar.ex test/parser/iiif/grammar_test.exs
git commit -m "feat(iiif): positional grammar token parsers"
```

---

## Task B4: ParsedRequest + PlanBuilder (image / info / redirect)

**Files:**
- Create: `lib/image_pipe/parser/iiif/parsed_request.ex`, `lib/image_pipe/parser/iiif/plan_builder.ex`
- Test: `test/parser/iiif/plan_builder_test.exs`

The PlanBuilder maps grammar values → `Plan` (emitting `Plan.Operation.*` in IIIF order region→size→rotation→quality), or a render plan for info, or `{:redirect,…}`.

Key mappings (use `ImagePipe.Plan.Operation` constructors; gray is a bare struct):
- region `:full` → no op; `:square` → `Operation.crop_guided(:full_axis, :full_axis, {:anchor, :center, :center}, aspect_ratio: {:ratio, 1, 1})`; `{:px,x,y,w,h}` → `Operation.crop_region({:px,x},{:px,y},{:px,w},{:px,h})`; `{:pct,…}` → `Operation.crop_region/4` with `{:ratio,…}` args.
- size → `Operation.resize(mode, width, height, enlargement: enlargement)` where:
  - `{:max, up?}` → `resize(:fit, :auto, :auto, enlargement: up? && :allow || :deny)` (apply max_width/height later if configured — for v1, `:auto`/`:auto`)
  - `{:w, w, up?}` → `resize(:fit, {:px, w}, :auto, enlargement: enl(up?, :reject))`
  - `{:h, h, up?}` → `resize(:fit, :auto, {:px, h}, enlargement: enl(up?, :reject))`
  - `{:wh, w, h, up?}` → `resize(:stretch, {:px, w}, {:px, h}, enlargement: enl(up?, :reject))`
  - `{:confined, w, h, up?}` → `resize(:fit, {:px, w}, {:px, h}, enlargement: enl(up?, :reject))`
  - `{:pct, ratio, up?}` → resize by ratio (zoom) with `enlargement: enl(up?, :reject)`
  - `enl(true, _) = :allow; enl(false, fallback) = fallback`
- rotation `0` → none; `90|180|270` → `Operation.rotate(angle)`
- quality `:default`/`:color` → none; `:gray` → `%ImagePipe.Plan.Operation.Gray{}`
- format → `%ImagePipe.Plan.Output{mode: {:explicit, jpg→:jpeg | png→:png | webp→:webp | avif→:avif}}`

- [ ] **Step 1: Write the failing test** (representative — extend as needed)

```elixir
defmodule ImagePipe.Parser.IIIF.PlanBuilderTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.IIIF.PlanBuilder
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation.{CropRegion, Resize, Rotate, Gray}
  alias ImagePipe.Plan.Source.Path, as: SourcePath

  @source %SourcePath{segments: ["images", "beach.jpg"]}

  defp build(tokens), do: PlanBuilder.image_plan(@source, tokens, auto_rotate: true)

  test "region+size+rotation+gray emit ops in IIIF order" do
    {:ok, %Plan{pipelines: [%{operations: ops}], output: out}} =
      build(%{region: {:px, 0, 0, 200, 300}, size: {:wh, 100, 150, false}, rotation: 90, quality: :gray, format: :png})

    assert [%CropRegion{}, %Resize{mode: :stretch}, %Rotate{angle: 90}, %Gray{}] = ops
    assert out.mode == {:explicit, :png}
  end

  test "size w, without ^ uses enlargement: :reject" do
    {:ok, %Plan{pipelines: [%{operations: [%Resize{enlargement: :reject}]}]}} =
      build(%{region: :full, size: {:w, 9999, false}, rotation: 0, quality: :default, format: :jpg})
  end

  test "^ size uses enlargement: :allow" do
    {:ok, %Plan{pipelines: [%{operations: [%Resize{enlargement: :allow}]}]}} =
      build(%{region: :full, size: {:w, 9999, true}, rotation: 0, quality: :default, format: :jpg})
  end
end
```

- [ ] **Step 2: Run it (FAIL).**

- [ ] **Step 3: Implement `ParsedRequest` + `PlanBuilder`**

`parsed_request.ex` — a thin struct holding `id`, `source`, the typed grammar values, `offers`, `auto_rotate`, and the absolute `id` URI for info. Keep it minimal; the PlanBuilder is where the work is.

`plan_builder.ex` (core; mirror `imgproxy/plan_builder.ex` for `Plan` assembly, source/response defaults):

```elixir
defmodule ImagePipe.Parser.IIIF.PlanBuilder do
  @moduledoc "Maps IIIF grammar values into an ImagePipe.Plan (image / render / redirect)."

  alias ImagePipe.Plan
  alias ImagePipe.Plan.{Operation, Output, Pipeline, Response}
  alias ImagePipe.Plan.Operation.Gray
  alias ImagePipe.Parser.IIIF.{Info, InfoRenderer}

  @spec image_plan(Plan.Source.t(), map(), keyword()) :: {:ok, Plan.t()} | {:error, term()}
  def image_plan(source, %{} = t, opts) do
    with {:ok, region_ops} <- region_ops(t.region),
         {:ok, size_ops} <- size_ops(t.size),
         {:ok, rotate_ops} <- rotation_ops(t.rotation),
         quality_ops <- quality_ops(t.quality),
         {:ok, output} <- output(t.format) do
      operations = region_ops ++ size_ops ++ rotate_ops ++ quality_ops

      {:ok,
       %Plan{
         source: source,
         pipelines: [%Pipeline{operations: operations}],
         output: output,
         auto_rotate: Keyword.get(opts, :auto_rotate, true),
         response: %Response{},
         render: :image
       }}
    end
  end

  @spec info_plan(Plan.Source.t(), String.t(), keyword()) :: {:ok, Plan.t()}
  def info_plan(source, id_uri, opts) do
    params = %{
      id: id_uri,
      offers: [{"application/ld+json;profile=\"http://iiif.io/api/image/3/context.json\"", ["application/ld+json"]}],
      level: "level2",
      max_width: Keyword.get(opts, :max_width),
      max_height: Keyword.get(opts, :max_height),
      max_area: Keyword.get(opts, :max_area),
      formats: Keyword.get(opts, :formats, [:jpg, :png, :webp, :avif]),
      qualities: Keyword.get(opts, :qualities, [:default, :color, :gray])
    }

    {:ok,
     %Plan{
       source: source,
       pipelines: [],
       output: nil,
       auto_rotate: false,
       response: %Response{},
       render: {:custom, InfoRenderer, params}
     }}
  end

  # --- region ---------------------------------------------------------------
  defp region_ops(:full), do: {:ok, []}

  defp region_ops(:square) do
    with {:ok, op} <-
           Operation.crop_guided(:full_axis, :full_axis, {:anchor, :center, :center},
             aspect_ratio: {:ratio, 1, 1}
           ),
         do: {:ok, [op]}
  end

  defp region_ops({:px, x, y, w, h}) do
    with {:ok, op} <- Operation.crop_region({:px, x}, {:px, y}, {:px, w}, {:px, h}), do: {:ok, [op]}
  end

  defp region_ops({:pct, xr, yr, wr, hr}) do
    with {:ok, op} <- Operation.crop_region(xr, yr, wr, hr), do: {:ok, [op]}
  end

  # --- size -----------------------------------------------------------------
  defp size_ops({:max, up?}), do: wrap(Operation.resize(:fit, :auto, :auto, enlargement: enl(up?, :deny)))
  defp size_ops({:w, w, up?}), do: wrap(Operation.resize(:fit, {:px, w}, :auto, enlargement: enl(up?, :reject)))
  defp size_ops({:h, h, up?}), do: wrap(Operation.resize(:fit, :auto, {:px, h}, enlargement: enl(up?, :reject)))
  defp size_ops({:wh, w, h, up?}), do: wrap(Operation.resize(:stretch, {:px, w}, {:px, h}, enlargement: enl(up?, :reject)))
  defp size_ops({:confined, w, h, up?}), do: wrap(Operation.resize(:fit, {:px, w}, {:px, h}, enlargement: enl(up?, :reject)))

  defp size_ops({:pct, {:ratio, num, den}, up?}) do
    factor = num / den
    wrap(Operation.resize(:fit, :auto, :auto, zoom_x: factor, zoom_y: factor, enlargement: enl(up?, :reject)))
  end

  defp enl(true, _fallback), do: :allow
  defp enl(false, fallback), do: fallback

  # --- rotation / quality / output -----------------------------------------
  defp rotation_ops(0), do: {:ok, []}
  defp rotation_ops(angle), do: wrap(Operation.rotate(angle))

  defp quality_ops(q) when q in [:default, :color], do: []
  defp quality_ops(:gray), do: [%Gray{}]

  defp output(:jpg), do: {:ok, %Output{mode: {:explicit, :jpeg}}}
  defp output(:png), do: {:ok, %Output{mode: {:explicit, :png}}}
  defp output(:webp), do: {:ok, %Output{mode: {:explicit, :webp}}}
  defp output(:avif), do: {:ok, %Output{mode: {:explicit, :avif}}}

  defp wrap({:ok, op}), do: {:ok, [op]}
  defp wrap({:error, _} = err), do: err
end
```

> Confirm `Operation.crop_guided/4` accepts `aspect_ratio:` and `Operation.resize/4` accepts `zoom_x:`/`zoom_y:`/`enlargement:` (read `lib/image_pipe/plan/operation.ex:167,327`). If `Operation.resize/4` doesn't expose `zoom_*`, express `pct` as a derived scale via the supported opts; otherwise keep zoom. Confirm `%Output{}` defaults (quality `:default`) are acceptable when only `mode` is set.

- [ ] **Step 4: Run it (PASS). Commit.**

```bash
git add lib/image_pipe/parser/iiif/parsed_request.ex lib/image_pipe/parser/iiif/plan_builder.ex test/parser/iiif/plan_builder_test.exs
git commit -m "feat(iiif): plan builder (region/size/rotation/quality/format -> Plan)"
```

---

## Task B5: Main parser module — `parse/2`, `handle_error/2`, `validate_options!/1`, CORS

**Files:**
- Create: `lib/image_pipe/parser/iiif.ex`
- Test: `test/parser/iiif_test.exs`

`parse/2` ties Path → Grammar → Resolver → PlanBuilder. `handle_error/2` maps parse errors to status (per the spec's status table): grammar `{:invalid_*}` → **400**, resolver miss / `:not_found` / shape → **404**.

**CORS (revised after Phase 2A review):** `Sender.send_redirect/3` is product-neutral and does **not** set CORS, and the 303 redirect short-circuits in the Plug before the parser can touch the response conn — so CORS must be applied at the **mount level**, not per-response in the parser. Apply `Access-Control-Allow-Origin: *` (and handle the `OPTIONS` preflight → 200 with `Access-Control-Allow-Methods`) via a thin CORS step that runs on **every** IIIF request — e.g. a small CORS plug the host mounts ahead of `ImagePipe.Plug`, or a `Plug.Conn.register_before_send/2` hook installed at the very start of `parse/2` (which fires for the image, info.json, redirect, *and* error responses uniformly). Do **not** rely on `handle_error/2` alone (it misses image/info/redirect responses). Decide the exact mechanism during B5 implementation and add a wire test (B8) asserting CORS on an image response, an info response, and the 303 redirect.

- [ ] **Step 1: Write the failing test** (parser-level; wire tests are B8)

```elixir
defmodule ImagePipe.Parser.IIIFTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias ImagePipe.Parser.IIIF
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Source.Path, as: SourcePath

  @opts [
    iiif: [
      resolver: {ImagePipe.Parser.IIIF.Resolver.Static, map: %{"abc" => %SourcePath{segments: ["beach.jpg"]}}}
    ]
  ]

  test "image request -> {:ok, %Plan{}}" do
    assert {:ok, %Plan{render: :image, output: %{mode: {:explicit, :jpeg}}}} =
             IIIF.parse(conn(:get, "/abc/full/max/0/default.jpg"), @opts)
  end

  test "info request -> render plan" do
    assert {:ok, %Plan{render: {:custom, ImagePipe.Parser.IIIF.InfoRenderer, _}}} =
             IIIF.parse(conn(:get, "/abc/info.json"), @opts)
  end

  test "bare identifier -> {:redirect, 303, location}" do
    conn = %{conn(:get, "/abc") | script_name: ["iiif"]}
    assert {:redirect, 303, "http://www.example.com/iiif/abc/info.json"} = IIIF.parse(conn, @opts)
  end

  test "unknown identifier -> {:error, :not_found}" do
    assert {:error, :not_found} = IIIF.parse(conn(:get, "/nope/full/max/0/default.jpg"), @opts)
  end

  test "bad token -> {:error, {:invalid_*}}" do
    assert {:error, {:invalid_rotation, "45"}} = IIIF.parse(conn(:get, "/abc/full/max/45/default.jpg"), @opts)
  end
end
```

- [ ] **Step 2: Run it (FAIL).**

- [ ] **Step 3: Implement the parser** (mirror `lib/image_pipe/parser/imgproxy.ex` for `@behaviour Parser`, NimbleOptions `validate_options!/1`, and `handle_error/2` structure):

```elixir
defmodule ImagePipe.Parser.IIIF do
  @moduledoc "IIIF Image API 3.0 (Level 2) parser. Positional grammar -> ImagePipe.Plan."

  @behaviour ImagePipe.Parser

  use Boundary, deps: [ImagePipe.Format, ImagePipe.Parser, ImagePipe.Plan, ImagePipe.Renderer]

  import Plug.Conn, only: [put_resp_header: 3, send_resp: 3]

  alias ImagePipe.Parser.IIIF.{Grammar, Path, PlanBuilder, Resolver}

  @schema NimbleOptions.new!(
            resolver: [type: {:custom, __MODULE__, :validate_resolver, []}, required: true],
            auto_rotate: [type: :boolean, default: true],
            max_width: [type: {:or, [:pos_integer, nil]}, default: nil],
            max_height: [type: {:or, [:pos_integer, nil]}, default: nil],
            max_area: [type: {:or, [:pos_integer, nil]}, default: nil],
            formats: [type: {:list, :atom}, default: [:jpg, :png, :webp, :avif]],
            qualities: [type: {:list, :atom}, default: [:default, :color, :gray]]
          )

  @impl true
  def validate_options!(opts) do
    iiif = Keyword.get(opts, :iiif, [])
    validated = NimbleOptions.validate!(iiif, @schema)
    Keyword.put(opts, :iiif, validated)
  end

  @doc false
  def validate_resolver({mod, ropts} = r) when is_atom(mod) and is_list(ropts) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :resolve, 2),
      do: {:ok, r},
      else: {:error, "resolver module must export resolve/2"}
  end

  def validate_resolver(_), do: {:error, "resolver must be {Module, opts}"}

  @impl true
  def parse(%Plug.Conn{method: "OPTIONS"} = conn, _opts), do: {:redirect, 303, ""} |> preflight(conn)

  def parse(%Plug.Conn{} = conn, opts) do
    iiif = Keyword.fetch!(opts, :iiif)

    case Path.classify(conn) do
      {:redirect, _id, location} ->
        {:redirect, 303, location}

      {:info, id} ->
        with {:ok, source} <- resolve(id, iiif) do
          PlanBuilder.info_plan(source, Path.base_uri(conn) <> "/" <> URI.encode(id), iiif)
        end

      {:image, id, tokens} ->
        with {:ok, source} <- resolve(id, iiif),
             {:ok, parsed} <- parse_tokens(tokens) do
          PlanBuilder.image_plan(source, parsed, iiif)
        end

      :not_found ->
        {:error, :not_found}
    end
  end

  @impl true
  def handle_error(%Plug.Conn{} = conn, error) do
    {status, body} = status_for(error)

    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> send_resp(status, body)
  end

  defp resolve(id, iiif) do
    {mod, ropts} = Keyword.fetch!(iiif, :resolver)

    case mod.resolve(id, ropts) do
      {:ok, %_{} = source} -> {:ok, source}
      {:error, _} -> {:error, :not_found}
    end
  end

  defp parse_tokens(%{region: r, size: s, rotation: rot, quality: q, format: f}) do
    with {:ok, region} <- Grammar.region(r),
         {:ok, size} <- Grammar.size(s),
         {:ok, rotation} <- Grammar.rotation(rot),
         {:ok, quality} <- Grammar.quality(q),
         {:ok, format} <- Grammar.format(f) do
      {:ok, %{region: region, size: size, rotation: rotation, quality: quality, format: format}}
    end
  end

  defp status_for(:not_found), do: {404, "not found"}
  defp status_for({tag, _raw}) when tag in [:invalid_region, :invalid_size, :invalid_rotation, :invalid_quality, :invalid_format], do: {400, "bad request"}
  defp status_for(_), do: {400, "bad request"}

  defp preflight({_r}, conn) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "GET, OPTIONS")
    |> send_resp(200, "")
  end
end
```

> The `OPTIONS` handling above is sketched as returning a sent conn from `parse/2`, which doesn't fit the `parse/2` contract — instead, handle `OPTIONS` in the IIIF mount/router or add a dedicated `:preflight` parse outcome. Simplest: detect `OPTIONS` in `parse/2` and return `{:error, {:preflight, conn}}`, then `handle_error/2` sends the 200 preflight. Decide during implementation and add a wire test (B8). Confirm the imgproxy parser's `validate_options!/1` + `Boundary` shape and mirror exactly.

- [ ] **Step 4: Run it (PASS). Commit.**

```bash
git add lib/image_pipe/parser/iiif.ex test/parser/iiif_test.exs
git commit -m "feat(iiif): main parser (parse/handle_error/validate_options) + CORS"
```

---

## Task B6: `Info` document + `InfoRenderer`

**Files:**
- Create: `lib/image_pipe/parser/iiif/info.ex`, `lib/image_pipe/parser/iiif/info_renderer.ex`
- Test: `test/parser/iiif/info_test.exs`

`InfoRenderer` implements `ImagePipe.Renderer`; `requires/1 → [:header]`; `render/3` reads `SourceInfo` + the parser params and builds the doc via `Info.document/2`, returning `{:ok, {"application/json", iodata}}`. Display dims via `SourceInfo.display_dimensions/1` (Phase 2A).

- [ ] **Step 1: Write the failing test**

```elixir
defmodule ImagePipe.Parser.IIIF.InfoTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.IIIF.{Info, InfoRenderer}
  alias ImagePipe.Plan.{RenderContext, SourceInfo}

  @info %SourceInfo{format: :jpeg, width: 1000, height: 600, orientation: 1}
  @params %{id: "http://x/iiif/abc", level: "level2", offers: [], max_width: nil, max_height: nil, max_area: nil, formats: [:jpg, :png], qualities: [:default, :gray]}

  test "document has required IIIF 3.0 fields with display dims" do
    doc = Info.document(@info, @params)
    assert doc["@context"] == "http://iiif.io/api/image/3/context.json"
    assert doc["id"] == "http://x/iiif/abc"
    assert doc["type"] == "ImageService3"
    assert doc["protocol"] == "http://iiif.io/api/image"
    assert doc["profile"] == "level2"
    assert doc["width"] == 1000 and doc["height"] == 600
  end

  test "renderer returns application/json body" do
    {:ok, {"application/json", body}} = InfoRenderer.render(%RenderContext{info: @info}, @params, [])
    assert IO.iodata_to_binary(body) =~ "ImageService3"
  end
end
```

- [ ] **Step 2: Run it (FAIL).**

- [ ] **Step 3: Implement `Info` + `InfoRenderer`**

```elixir
defmodule ImagePipe.Parser.IIIF.Info do
  @moduledoc "Builds the IIIF Image API 3.0 info.json document map."

  alias ImagePipe.Plan.SourceInfo

  @context "http://iiif.io/api/image/3/context.json"

  @spec document(SourceInfo.t(), map()) :: map()
  def document(%SourceInfo{} = info, params) do
    {w, h} = SourceInfo.display_dimensions(info)

    %{
      "@context" => @context,
      "id" => params.id,
      "type" => "ImageService3",
      "protocol" => "http://iiif.io/api/image",
      "profile" => params.level,
      "width" => w,
      "height" => h,
      "extraQualities" => Enum.map(params.qualities, &to_string/1),
      "extraFormats" => params.formats |> Enum.reject(&(&1 in [:jpg, :png])) |> Enum.map(&to_string/1),
      "extraFeatures" => [
        "regionByPx", "regionByPct", "regionSquare",
        "sizeByW", "sizeByH", "sizeByWh", "sizeByPct", "sizeByConfinedWh", "sizeUpscaling",
        "rotationBy90s", "baseUriRedirect", "cors", "jsonldMediaType"
      ]
    }
    |> maybe_put("maxWidth", params.max_width)
    |> maybe_put("maxHeight", params.max_height)
    |> maybe_put("maxArea", params.max_area)
  end

  defp maybe_put(map, _k, nil), do: map
  defp maybe_put(map, k, v), do: Map.put(map, k, v)
end
```

```elixir
defmodule ImagePipe.Parser.IIIF.InfoRenderer do
  @moduledoc "Renders the IIIF info.json via the Phase 1 Renderer mechanism."

  @behaviour ImagePipe.Renderer

  alias ImagePipe.Parser.IIIF.Info
  alias ImagePipe.Plan.RenderContext

  @impl true
  def requires(_params), do: [:header]

  @impl true
  def render(%RenderContext{info: info}, params, _opts) do
    {:ok, {"application/json", JSON.encode_to_iodata!(Info.document(info, params))}}
  end
end
```

- [ ] **Step 4: Run it (PASS). Commit.**

```bash
git add lib/image_pipe/parser/iiif/info.ex lib/image_pipe/parser/iiif/info_renderer.ex test/parser/iiif/info_test.exs
git commit -m "feat(iiif): info.json document + renderer"
```

---

## Task B7: Canonical `Link` header (optional)

**Files:**
- Modify: `lib/image_pipe/parser/iiif.ex` (compute the canonical URL; the response layer must emit `Link`)
- Test: covered at the wire level in B8.

- [ ] **Step 1:** Decide the emission point. The cleanest is to carry a `Link` value in the `Plan.Response` (if it supports arbitrary headers) or set it where IIIF responses are finalized. Read `lib/image_pipe/plan/response.ex` to see whether it can carry extra headers; if not, treat `Link` as out-of-scope-deferred and note it in the matrix (it's `_may_` per spec). Implement only if `Response` already supports custom headers cheaply.
- [ ] **Step 2:** If implemented, add a wire test in B8 asserting `Link: <…>;rel="canonical"`. Otherwise mark optional/deferred in `docs/iiif_3_support_matrix.md` and skip. Commit either the implementation or the matrix note.

---

## Task B8: Wire-level Plug tests

**Files:**
- Create: `test/parser/iiif_wire_test.exs` (real `ImagePipe.call/2`, mirror `test/parser/imgproxy_*` wire tests for setup/origin)

- [ ] **Step 1:** Set up a test mount: `ImagePipe.Plug` with `parser: ImagePipe.Parser.IIIF` and a Static resolver mapping a test id to a fixture image served via the test origin/file source (mirror how `imgproxy` wire tests provide source bytes).

- [ ] **Step 2: Write the wire tests** (one assertion group per contract):

```elixir
# status + content-type + decoded dims for a representative image request
test "GET /{id}/full/100,/0/default.png -> 200 png, width 100"
# gray pixel check on an opaque source: bands equal
test "GET /{id}/full/max/0/gray.jpg -> 200, decoded pixels desaturated"
# gray on an RGBA source to a non-alpha format: flattens (the B_W+alpha->flatten path #269 deferred here)
test "GET /{rgba_id}/full/max/0/gray.jpg -> 200 valid (opaque) JPEG (alpha flattened via #269)"
# gray on an RGBA source to png keeps transparency
test "GET /{rgba_id}/full/max/0/gray.png -> 200, alpha band intact"
# info.json + negotiation
test "GET /{id}/info.json (no Accept) -> application/json, profile level2, display dims"
test "GET /{id}/info.json (Accept: application/ld+json) -> ld+json, Vary: Accept"
# base-URI 303
test "GET /{id} -> 303, Location ends with /{id}/info.json"
# CORS
test "any IIIF response carries Access-Control-Allow-Origin: *"
test "OPTIONS /{id}/full/max/0/default.jpg -> 200 with Allow-Methods"
# status mapping
test "GET /{id}/full/9999,/0/default.jpg (no ^) -> 400"     # upscale reject
test "GET /{id}/full/!4000,4000/0/default.jpg (no ^) -> 400" # confined upscale
test "GET /{id}/99999,99999,10,10/max/0/default.jpg -> 400"  # wholly out of bounds
test "GET /{id}/full/max/45/default.jpg -> 400"              # bad rotation
test "GET /{id}/full/max/0/default.tif -> 400"               # bad format
test "GET /unknown/full/max/0/default.jpg -> 404"            # resolver miss, no source fetch
test "GET /a/b/full/max/0/default.jpg -> 404"                # unescaped slash
# §T1 combined region+rotation+gray pixel test (EXIF-oriented source) — see spec Tests §T1
test "region+90+gray on an orientation-6 source matches the autorotate->crop->rot->bw baseline"
# negative Vary on image responses
test "image response has no Vary: Accept"
# format bypass
test "explicit .webp ignores Accept and returns image/webp"
# cache reuse (T3)
test "two equivalent IIIF URLs reuse the cache entry"
# ETag/304 (T2)
test "If-None-Match on info.json -> 304 before source fetch"
```

Fill each with the concrete `conn`, headers, and assertions, decoding response bodies with `Image.open/1` for pixel/dimension checks (mirror the imgproxy wire tests' decode helpers). For §T1, build the baseline exactly as the spec prescribes: `Image.autorotate/1` → `Image.crop/5` the display rectangle → `Vix.Vips.Operation.rot/2` → `Image.to_colorspace(:bw)`, and add the wrong-order negative control.

- [ ] **Step 2b: Run + commit** after each contract group goes green:

```bash
mise exec -- mix test test/parser/iiif_wire_test.exs
git add test/parser/iiif_wire_test.exs && git commit -m "test(iiif): wire-level conformance tests"
```

---

## Task B9: Conformance matrix doc

**Files:**
- Create: `docs/iiif_3_support_matrix.md` (mirror `docs/imgproxy_support_matrix.md` structure)

- [ ] **Step 1:** Read `docs/imgproxy_support_matrix.md` for structure (per-feature tables, surface/stage/behavioral axes, "Diverges" notes).
- [ ] **Step 2:** Write `docs/iiif_3_support_matrix.md` with: region/size/rotation/quality/format/info.json/HTTP feature tables keyed to the Level 0/1/2 compliance matrix; the `extraFeatures`/`extraQualities`/`extraFormats` we advertise; and the explicit divergences/notes:
  - upscale-without-`^` (incl. `!w,h`) and wholly-out-of-bounds region → **400** (spec-conformant; general customizable error→status is **#267**).
  - `gray`/any quality on an explicit **non-alpha** format with an alpha source **flattens onto the background** (valid output) via **#269** (landed); gray preserves alpha for alpha-supporting formats.
  - `jp2`/`gif`/`tif`/`pdf`, bitonal, arbitrary rotation, mirroring (`!n`) — unsupported `extraFeatures`.
  - `auto_rotate` defaults true (display-frame coordinates) — intentional, not a divergence.
  - canonical `Link` — implemented or deferred (per B7).
- [ ] **Step 3: Commit.**

```bash
git add docs/iiif_3_support_matrix.md && git commit -m "docs(iiif): IIIF 3.0 Level 2 support matrix"
```

---

## Task B10: Validator CI gate

**Files:**
- Create: `test/support/fixtures/iiif/67352ccc-d1b0-11e1-89ae-279075081939` (the committed reference image — download from the IIIF validator test images set)
- Create: `validator/Dockerfile`, `validator/docker-compose.yml`
- Modify: `mise.toml` (a `validator` task), CI workflow (`.github/workflows/*.yml`)

- [ ] **Step 1:** Add a tiny example app / mount that serves the reference image via `Parser.IIIF` + the Static resolver (identifier `67352ccc-…` → the fixture). This can be a small `Plug` in `validator/` or a `test`-env endpoint. Commit the reference image fixture (verify its license permits redistribution; if not, fetch it in the CI step instead of committing).

- [ ] **Step 2:** `validator/Dockerfile` (per spec — the slim CLI image, **not** the repo's Apache/WSGI Dockerfile):

```dockerfile
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends libmagic1 \
    && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir iiif-validator
ENTRYPOINT ["iiif-validate.py"]
```

- [ ] **Step 3:** `validator/docker-compose.yml` — two services on a shared network: the ImagePipe IIIF endpoint and the validator, the validator's `--server` pointing at the ImagePipe service name. Command: `iiif-validate.py -s <imagepipe-service> -p <prefix> -i 67352ccc-d1b0-11e1-89ae-279075081939 --version=3.0` at Level 2.

- [ ] **Step 4:** `mise.toml` task `validator` that builds + runs the compose and asserts the validator exits `0`. Wire it into the CI workflow (a job that runs the compose and fails the build on non-zero exit). Note in the task/CI comment that the gate goes green only once info.json is in place (B6).

- [ ] **Step 5: Run locally** (Docker required): `mise run validator`. Expected: exit 0. **Commit.**

```bash
git add validator/ mise.toml .github/workflows/ test/support/fixtures/iiif/
git commit -m "ci(iiif): Level 2 image-validator gate (docker-compose)"
```

---

## Final verification (Phase 2B)

- [ ] `mise exec -- mise run precommit` (Elixir gate) — green.
- [ ] `mise run validator` (Docker) — exit 0 at Level 2.
- [ ] Rename considered: branch already `feat/iiif-phase-2-parser` (descriptive) — no rename needed before push.

## Spec coverage (self-review)

- Parser grammar → Plan (region/size/rotation/quality/format) → **B3, B4** ✓
- Resolver behaviour + Static → **B1** ✓
- Path dispatch / base-URI / segment-count / unescaped-slash 404 → **B2** ✓
- `parse/2` + `handle_error/2` status mapping (400/404) + `validate_options!/1` → **B5** ✓
- info.json via Renderer + display dims + extra\* lists → **B6** ✓
- Accept negotiation (offers param) → **B6** params + Phase 2A delivery ✓
- Base-URI 303 → **B2/B5** (consumes Phase 2A `{:redirect}`) ✓
- CORS + OPTIONS preflight → **B5** ✓
- Canonical `Link` (optional) → **B7** ✓
- Wire-level tests incl. §T1/T2/T3, status mapping, negative-Vary, format-bypass → **B8** ✓
- Conformance matrix → **B9** ✓
- Validator CI gate → **B10** ✓

## Open confirmations for the implementer (resolve while coding; none block the design)

1. `Operation.resize/4` opts surface (`zoom_x`/`zoom_y`/`enlargement`) and `Operation.crop_guided/4` `aspect_ratio:` — confirm against `lib/image_pipe/plan/operation.ex` and adjust the `pct`/`square` construction if the opt names differ.
2. `%Output{}` minimal construction (only `mode` set) vs an imgproxy-style `output_plan` builder — match whatever `Plan.validate_shape/1` requires.
3. `OPTIONS` preflight routing — via a `:preflight` parse outcome through `handle_error/2`, or at the mount; pick one and wire the B8 test to it.
4. Reference-image licensing for committing the fixture vs fetching it in CI (B10).
