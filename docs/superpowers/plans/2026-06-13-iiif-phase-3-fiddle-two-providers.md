# Fiddle Two-Provider (imgproxy + IIIF) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the `fiddle/` demo from one provider (imgproxy) to two (imgproxy + IIIF Image API 3.0), with a provider selector, per-provider controls, and per-provider URL state that never leaks across dialects.

**Architecture:** Backend mounts a second image service (`/iiif-image`) wired to `ImagePipe.Parser.IIIF` with a static resolver over the existing sample images, CORS composed ahead (interim — see #284). Frontend holds an in-memory `AppState = { provider, imgproxy, iiif }` container but **serializes only the active slice** to the browser URL (`/imgproxy/…` or `/iiif/…`); a dispatcher layer owns the provider prefix while the existing imgproxy builders stay prefix-free. `App.svelte` keeps the shell; imgproxy tool sections move to `ImgproxyControls.svelte` and a new `IiifControls.svelte` holds the grouped IIIF panel, each bound to its slice via a `$bindable()` `state` prop.

**Tech Stack:** Elixir/Phoenix (`fiddle/`), **Svelte 5 runes** (`$state`/`$derived`/`$effect`/`$props`/`$bindable` — the codebase migrated to runes in #291; do NOT use legacy `export let`/`$:`), TypeScript, Vitest, Vite (`virtual:sample-images`), `mise`, `pnpm`.

**Spec:** `docs/superpowers/specs/2026-06-13-iiif-phase-3-fiddle-two-providers-design.md`

**Baseline note (post-#291 rename):** the fiddle's identifier family is `Fiddle*`/`fiddle*`: `FiddleState`, `defaultFiddleState`, `fiddleObjClasses`, `fiddlePathForState`, `parseFiddlePath`, `resetFiddleSettings`, and the URL-state module is `fiddle-url-state.ts`. (The backend Elixir app was always `ImagePipeFiddle`, unaffected.)

**Commands:**
- JS single file: `mise exec -- pnpm -C fiddle/assets exec vitest run <pattern>`
- JS all: `mise exec -- pnpm -C fiddle/assets test`
- JS typecheck/lint/format: `mise exec -- pnpm -C fiddle/assets run check` / `… run lint` / `… run format:check`
- Fiddle Elixir tests: `(cd fiddle && mise exec -- mix test test/image_pipe_fiddle_web/wire_test.exs)` (bash cwd resets to the worktree root between calls and `fiddle/` is a separate mix project, so the `cd fiddle` subshell is required)
- Full demo gate: `mise run precommit:fiddle`

---

## File Structure

**Backend (`fiddle/`):**
- Create `lib/image_pipe_fiddle_web/iiif.ex` — IIIF mount plug (CORS ahead of `ImagePipe.Plug`).
- Modify `lib/image_pipe_fiddle_web/router.ex` — add `forward "/iiif-image", …`.
- Modify `lib/image_pipe_fiddle/application.ex` — build + store `iiif_opts`; `iiif_source_map/0`.
- Modify `test/image_pipe_fiddle_web/wire_test.exs` — IIIF wire + OPTIONS coverage.

**Frontend (`fiddle/assets/`):**
- Create `iiif-path.ts` — `IiifState` types, defaults, id derivation, segment/path builders + parsers, control limits.
- Create `iiif-path.test.ts`.
- Modify `fiddle-url-state.ts` — provider-dispatch layer (`appPathForState` / `parseAppPath`); add `AppState`/`Provider`/`providers`.
- Create `fiddle-url-state.test.ts` — dispatcher + no-leakage + popstate tests.
- Create `ImgproxyControls.svelte` — extracted imgproxy tool sections (Resize…Metadata), `$bindable()` `state` + `source` props. **Signature stays in App** (see Task 4 note).
- Create `IiifControls.svelte` — grouped IIIF parameters panel, `$bindable()` `state` + `source` props.
- Modify `App.svelte` — shell: provider dropdown, shared Request (source + imgproxy-gated signature), preview/label/param branching, cross-provider source reset, dispatcher wiring.

---

## Task 1: Backend — IIIF image service mount

**Files:**
- Create: `fiddle/lib/image_pipe_fiddle_web/iiif.ex`
- Modify: `fiddle/lib/image_pipe_fiddle_web/router.ex:17`
- Modify: `fiddle/lib/image_pipe_fiddle/application.ex`
- Test: `fiddle/test/image_pipe_fiddle_web/wire_test.exs`

- [ ] **Step 1: Write the failing wire tests**

Append to `fiddle/test/image_pipe_fiddle_web/wire_test.exs` (before the final `defp sign`):

```elixir
  test "GET /iiif-image processes a IIIF full/max request", %{conn: conn} do
    conn = get(conn, "/iiif-image/dog/full/max/0/default.jpg")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/"
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  test "GET /iiif-image honors region + size geometry", %{conn: conn} do
    conn = get(conn, "/iiif-image/dog/0,0,100,100/50,/0/default.jpg")
    assert conn.status == 200
    image = Image.open!(conn.resp_body, access: :random, fail_on: :error)
    assert Image.width(image) == 50
    assert Image.height(image) == 50
  end

  test "GET /iiif-image rejects a bad rotation with 400", %{conn: conn} do
    conn = get(conn, "/iiif-image/dog/full/max/45/default.jpg")
    assert conn.status == 400
  end

  test "GET /iiif-image returns 404 for an unknown identifier", %{conn: conn} do
    conn = get(conn, "/iiif-image/nope/full/max/0/default.jpg")
    assert conn.status == 404
  end

  test "OPTIONS /iiif-image answers CORS preflight", %{conn: conn} do
    conn = options(conn, "/iiif-image/dog/full/max/0/default.jpg")
    assert conn.status == 200
    assert get_resp_header(conn, "access-control-allow-methods") |> hd() =~ "GET"
  end

  test "IIIF browser deep-link still serves the SPA shell", %{conn: conn} do
    conn = get(conn, "/iiif/dog/full/max/0/default.jpg")
    assert html_response(conn, 200) =~ ~s(id="fiddle-app")
  end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `(cd fiddle && mise exec -- mix test test/image_pipe_fiddle_web/wire_test.exs)`
Expected: the new tests FAIL (no `/iiif-image` route → 404/serves SPA shell instead of an image; OPTIONS has no `Allow-Methods`).

- [ ] **Step 3: Create the IIIF mount plug**

Create `fiddle/lib/image_pipe_fiddle_web/iiif.ex`:

```elixir
defmodule ImagePipeFiddleWeb.IIIF do
  @moduledoc """
  Forwards /iiif-image requests to ImagePipe.Plug with opts built at boot.

  Composes ImagePipe.Parser.IIIF.CORS ahead of ImagePipe.Plug so OPTIONS
  preflight is answered and `Access-Control-Allow-Origin: *` lands on every
  response. Interim manual composition — #284 moves CORS behind a Parser hook,
  after which this plug delegates straight to ImagePipe.Plug.
  """
  @behaviour Plug

  alias ImagePipe.Parser.IIIF.CORS

  @impl true
  def init(_opts), do: []

  @impl true
  def call(conn, _opts) do
    cors_conn = CORS.call(conn, CORS.init([]))

    if cors_conn.halted do
      cors_conn
    else
      ImagePipe.Plug.call(
        cors_conn,
        :persistent_term.get({ImagePipeFiddle.Application, :iiif_opts})
      )
    end
  end
end
```

- [ ] **Step 4: Add the route**

In `fiddle/lib/image_pipe_fiddle_web/router.ex`, immediately after the existing `forward "/img", ImagePipeFiddleWeb.Imgproxy` (line 17), add:

```elixir
  forward "/iiif-image", ImagePipeFiddleWeb.IIIF
```

- [ ] **Step 5: Build and store the IIIF opts in application.ex**

In `fiddle/lib/image_pipe_fiddle/application.ex`, add the persistent_term put right after the existing imgproxy one (line 10):

```elixir
    :persistent_term.put({__MODULE__, :iiif_opts}, build_iiif_opts())
```

Then add these private functions next to `build_imgproxy_opts/0`:

```elixir
  defp build_iiif_opts do
    static_root = Application.app_dir(:image_pipe_fiddle, "priv/static")

    [
      parser: ImagePipe.Parser.IIIF,
      iiif: [resolver: {ImagePipe.Parser.IIIF.Resolver.Static, map: iiif_source_map()}],
      sources: [
        path: {ImagePipe.Source.File, root: static_root, root_id: "static", stable: :trusted}
      ]
    ]
    |> maybe_put_cache(Application.get_env(:image_pipe_fiddle, :cache))
    |> ImagePipe.Plug.init()
  end

  # Maps each sample image to a slash-free, extension-stripped IIIF identifier
  # (images/dog.jpg -> "dog"). Sample filenames are URL-safe by convention, so the
  # id needs no encoding and matches the frontend's iiifIdForSource. Stems must be
  # unique across the set; raises if not.
  defp iiif_source_map do
    files =
      :image_pipe_fiddle
      |> Application.app_dir("priv/static/images")
      |> File.ls!()
      |> Enum.filter(&(Path.extname(&1) in ~w(.avif .jpeg .jpg .png .webp)))

    map =
      Map.new(files, fn file ->
        {Path.rootname(file), %ImagePipe.Plan.Source.Path{segments: ["images", file]}}
      end)

    if map_size(map) < length(files) do
      raise "IIIF identifier stem collision among sample images (two files share a basename)"
    end

    map
  end
```

(`detector_required:` is intentionally omitted — IIIF Level 2 has no smart/object crop. The existing `cache_children/1` supervisor child stays a single instance; both plugs share it.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `(cd fiddle && mise exec -- mix test test/image_pipe_fiddle_web/wire_test.exs)`
Expected: PASS (all tests, including the pre-existing imgproxy ones).

- [ ] **Step 7: Commit**

```bash
git add fiddle/lib/image_pipe_fiddle_web/iiif.ex fiddle/lib/image_pipe_fiddle_web/router.ex fiddle/lib/image_pipe_fiddle/application.ex fiddle/test/image_pipe_fiddle_web/wire_test.exs
git commit -m "feat(fiddle): mount IIIF image service at /iiif-image (#254)"
```

---

## Task 2: Frontend — `iiif-path.ts` (state, builders, parsers)

**Files:**
- Create: `fiddle/assets/iiif-path.ts`
- Test: `fiddle/assets/iiif-path.test.ts`

- [ ] **Step 1: Write the failing test**

Create `fiddle/assets/iiif-path.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import {
  defaultIiifState,
  iiifIdForSource,
  sourceForIiifId,
  iiifPathTail,
  iiifBrowserPath,
  iiifFetchPath,
  parseIiifTail,
  type IiifState,
} from "./iiif-path";

describe("iiif id derivation", () => {
  it("derives a slash-free, extension-stripped id", () => {
    expect(iiifIdForSource("images/dog.jpg")).toBe("dog");
    expect(iiifIdForSource("images/concert.jpeg")).toBe("concert");
  });

  it("round-trips id -> source -> id", () => {
    const id = iiifIdForSource("images/dog.jpg");
    expect(sourceForIiifId(id)).toBe("images/dog.jpg");
  });

  it("rejects an unknown id", () => {
    expect(sourceForIiifId("nope")).toBeNull();
  });

  it("derives unique ids across all sample images (stem-collision guard)", async () => {
    const { sampleImages } = await import("./processing-path");
    const ids = sampleImages.map((image) => iiifIdForSource(image.path));
    expect(new Set(ids).size).toBe(ids.length);
  });
});

describe("iiif segment building", () => {
  it("builds the default tail", () => {
    expect(iiifPathTail(defaultIiifState)).toBe("dog/full/max/0/default.jpg");
  });

  it("encodes each region form", () => {
    expect(iiifPathTail({ ...defaultIiifState, region: { kind: "square" } }))
      .toBe("dog/square/max/0/default.jpg");
    expect(iiifPathTail({ ...defaultIiifState, region: { kind: "px", x: 0, y: 0, w: 100, h: 100 } }))
      .toBe("dog/0,0,100,100/max/0/default.jpg");
    expect(iiifPathTail({ ...defaultIiifState, region: { kind: "pct", x: 10.5, y: 0, w: 50, h: 50 } }))
      .toBe("dog/pct:10.5,0,50,50/max/0/default.jpg");
  });

  it("encodes each size form and the upscale flag", () => {
    expect(iiifPathTail({ ...defaultIiifState, size: { kind: "w", w: 400 } }))
      .toBe("dog/full/400,/0/default.jpg");
    expect(iiifPathTail({ ...defaultIiifState, size: { kind: "h", h: 300 } }))
      .toBe("dog/full/,300/0/default.jpg");
    expect(iiifPathTail({ ...defaultIiifState, size: { kind: "wh", w: 400, h: 300 } }))
      .toBe("dog/full/400,300/0/default.jpg");
    expect(iiifPathTail({ ...defaultIiifState, size: { kind: "confined", w: 400, h: 300 } }))
      .toBe("dog/full/!400,300/0/default.jpg");
    expect(iiifPathTail({ ...defaultIiifState, size: { kind: "pct", n: 50 } }))
      .toBe("dog/full/pct:50/0/default.jpg");
    expect(iiifPathTail({ ...defaultIiifState, size: { kind: "pct", n: 200 }, upscale: true }))
      .toBe("dog/full/^pct:200/0/default.jpg");
  });

  it("encodes rotation, quality, format", () => {
    expect(iiifPathTail({ ...defaultIiifState, rotation: 90, quality: "gray", format: "png" }))
      .toBe("dog/full/max/90/gray.png");
  });

  it("builds browser and fetch paths with distinct prefixes", () => {
    expect(iiifBrowserPath(defaultIiifState)).toBe("/iiif/dog/full/max/0/default.jpg");
    expect(iiifFetchPath(defaultIiifState)).toBe("/iiif-image/dog/full/max/0/default.jpg");
  });
});

describe("iiif tail parsing round-trips", () => {
  const cases: IiifState[] = [
    defaultIiifState,
    { ...defaultIiifState, region: { kind: "square" } },
    { ...defaultIiifState, region: { kind: "px", x: 1, y: 2, w: 100, h: 80 } },
    { ...defaultIiifState, region: { kind: "pct", x: 10.5, y: 0, w: 50, h: 50 } },
    { ...defaultIiifState, size: { kind: "w", w: 400 } },
    { ...defaultIiifState, size: { kind: "h", h: 300 } },
    { ...defaultIiifState, size: { kind: "wh", w: 400, h: 300 } },
    { ...defaultIiifState, size: { kind: "confined", w: 400, h: 300 } },
    { ...defaultIiifState, size: { kind: "pct", n: 50 } },
    { ...defaultIiifState, size: { kind: "pct", n: 200 }, upscale: true },
    { ...defaultIiifState, rotation: 270, quality: "bitonal", format: "webp" },
  ];

  for (const state of cases) {
    it(`round-trips ${iiifPathTail(state)}`, () => {
      expect(parseIiifTail(iiifPathTail(state))).toEqual(state);
    });
  }

  it("rejects a malformed tail", () => {
    expect(parseIiifTail("dog/full/max/0")).toBeNull(); // missing quality.format
    expect(parseIiifTail("dog/full/max/45/default.jpg")).toBeNull(); // bad rotation
    expect(parseIiifTail("nope/full/max/0/default.jpg")).toBeNull(); // unknown id
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- pnpm -C fiddle/assets exec vitest run iiif-path`
Expected: FAIL — `Cannot find module './iiif-path'`.

- [ ] **Step 3: Implement `iiif-path.ts`**

Create `fiddle/assets/iiif-path.ts`:

```ts
import { sampleImages, type SourceImage } from "./processing-path";

export type IiifRegion =
  | { kind: "full" }
  | { kind: "square" }
  | { kind: "px"; x: number; y: number; w: number; h: number } // ints; x,y>=0; w,h>=1
  | { kind: "pct"; x: number; y: number; w: number; h: number }; // decimals; x,y>=0; w,h>0

export type IiifSize =
  | { kind: "max" }
  | { kind: "w"; w: number } // w,    positive int
  | { kind: "h"; h: number } // ,h    positive int
  | { kind: "wh"; w: number; h: number } // w,h positive ints (may distort)
  | { kind: "confined"; w: number; h: number } // !w,h positive ints
  | { kind: "pct"; n: number }; // pct:n  >0; >100 only with upscale

export type IiifRotation = 0 | 90 | 180 | 270;
export type IiifQuality = "default" | "color" | "gray" | "bitonal";
export type IiifFormat = "jpg" | "png" | "webp" | "avif";

export type IiifState = {
  source: SourceImage;
  region: IiifRegion;
  size: IiifSize;
  upscale: boolean;
  rotation: IiifRotation;
  quality: IiifQuality;
  format: IiifFormat;
};

const iiifQualities: readonly IiifQuality[] = ["default", "color", "gray", "bitonal"];
const iiifFormats: readonly IiifFormat[] = ["jpg", "png", "webp", "avif"];
const iiifRotations: readonly IiifRotation[] = [0, 90, 180, 270];

// images/dog.jpg -> "dog". Sample filenames are URL-safe (no spaces/% / #), so the
// path basename equals the real filename and matches the backend's Path.rootname —
// no decode/encode needed. (Keep sample images URL-safe by convention.)
export function iiifIdForSource(source: SourceImage): string {
  return source.replace(/^images\//, "").replace(/\.[^.]+$/, "");
}

const idToSource = new Map<string, SourceImage>(
  sampleImages.map((image) => [iiifIdForSource(image.path as SourceImage), image.path as SourceImage]),
);

export function sourceForIiifId(id: string): SourceImage | null {
  return idToSource.get(id) ?? null;
}

export const defaultIiifState: IiifState = {
  source: "images/dog.jpg",
  region: { kind: "full" },
  size: { kind: "max" },
  upscale: false,
  rotation: 0,
  quality: "default",
  format: "jpg",
};

export type NumericLimit = { min: number; max: number; step: number };

// px region inputs clamp per-axis to the source's real dimensions (UX nicety; the
// backend clips partial out-of-bounds). Size dimensions are positive ints.
export const iiifControlLimits = {
  size: { min: 1, max: 8000, step: 1 },
  pct: { min: 1, max: 1000, step: 1 },
} satisfies { size: NumericLimit; pct: NumericLimit };

function regionSegment(region: IiifRegion): string {
  switch (region.kind) {
    case "full":
      return "full";
    case "square":
      return "square";
    case "px":
      return `${region.x},${region.y},${region.w},${region.h}`;
    case "pct":
      return `pct:${region.x},${region.y},${region.w},${region.h}`;
  }
}

function sizeSegment(size: IiifSize, upscale: boolean): string {
  const prefix = upscale ? "^" : "";
  switch (size.kind) {
    case "max":
      return `${prefix}max`;
    case "w":
      return `${prefix}${size.w},`;
    case "h":
      return `${prefix},${size.h}`;
    case "wh":
      return `${prefix}${size.w},${size.h}`;
    case "confined":
      return `${prefix}!${size.w},${size.h}`;
    case "pct":
      return `${prefix}pct:${size.n}`;
  }
}

export function iiifPathTail(state: IiifState): string {
  const id = iiifIdForSource(state.source);
  const region = regionSegment(state.region);
  const size = sizeSegment(state.size, state.upscale);
  return `${id}/${region}/${size}/${state.rotation}/${state.quality}.${state.format}`;
}

export function iiifBrowserPath(state: IiifState): string {
  return `/iiif/${iiifPathTail(state)}`;
}

export function iiifFetchPath(state: IiifState): string {
  return `/iiif-image/${iiifPathTail(state)}`;
}

// --- parsing (mirror lib/image_pipe/parser/iiif/grammar.ex) ---

function parsePositiveInt(value: string): number | null {
  return /^\d+$/.test(value) && Number(value) > 0 ? Number(value) : null;
}

function parseNonNegInt(value: string): number | null {
  return /^\d+$/.test(value) ? Number(value) : null;
}

function parseDecimal(value: string): number | null {
  return /^\d+(\.\d+)?$/.test(value) ? Number(value) : null;
}

function parseRegion(token: string): IiifRegion | null {
  if (token === "full") return { kind: "full" };
  if (token === "square") return { kind: "square" };

  if (token.startsWith("pct:")) {
    const parts = token.slice(4).split(",");
    if (parts.length !== 4) return null;
    const [x, y, w, h] = parts.map(parseDecimal);
    if (x === null || y === null || w === null || h === null) return null;
    if (w <= 0 || h <= 0) return null;
    return { kind: "pct", x, y, w, h };
  }

  const parts = token.split(",");
  if (parts.length !== 4) return null;
  const x = parseNonNegInt(parts[0]!);
  const y = parseNonNegInt(parts[1]!);
  const w = parsePositiveInt(parts[2]!);
  const h = parsePositiveInt(parts[3]!);
  if (x === null || y === null || w === null || h === null) return null;
  return { kind: "px", x, y, w, h };
}

function parseSize(rawToken: string): { size: IiifSize; upscale: boolean } | null {
  const upscale = rawToken.startsWith("^");
  const token = upscale ? rawToken.slice(1) : rawToken;

  if (token === "max") return { size: { kind: "max" }, upscale };

  if (token.startsWith("pct:")) {
    const n = parseDecimal(token.slice(4));
    if (n === null || n <= 0) return null;
    if (!upscale && n > 100) return null;
    return { size: { kind: "pct", n }, upscale };
  }

  if (token.startsWith("!")) {
    const [w, h] = token.slice(1).split(",").map(parsePositiveInt);
    if (w === null || h === null) return null;
    return { size: { kind: "confined", w, h }, upscale };
  }

  const parts = token.split(",");
  if (parts.length !== 2) return null;
  const [left, right] = parts;
  if (left !== "" && right === "") {
    const w = parsePositiveInt(left!);
    return w === null ? null : { size: { kind: "w", w }, upscale };
  }
  if (left === "" && right !== "") {
    const h = parsePositiveInt(right!);
    return h === null ? null : { size: { kind: "h", h }, upscale };
  }
  if (left !== "" && right !== "") {
    const w = parsePositiveInt(left!);
    const h = parsePositiveInt(right!);
    if (w === null || h === null) return null;
    return { size: { kind: "wh", w, h }, upscale };
  }
  return null;
}

function parseRotation(token: string): IiifRotation | null {
  const value = Number(token);
  return iiifRotations.includes(value as IiifRotation) && /^\d+$/.test(token)
    ? (value as IiifRotation)
    : null;
}

export function parseIiifTail(tail: string): IiifState | null {
  const segments = tail.split("/").filter(Boolean);
  if (segments.length !== 5) return null;

  const [id, regionToken, sizeToken, rotationToken, qualityFormat] = segments as [
    string,
    string,
    string,
    string,
    string,
  ];

  const source = sourceForIiifId(id);
  if (source === null) return null;

  const region = parseRegion(regionToken);
  if (region === null) return null;

  const parsedSize = parseSize(sizeToken);
  if (parsedSize === null) return null;

  const rotation = parseRotation(rotationToken);
  if (rotation === null) return null;

  const dot = qualityFormat.lastIndexOf(".");
  if (dot <= 0 || dot === qualityFormat.length - 1) return null;
  const quality = qualityFormat.slice(0, dot);
  const format = qualityFormat.slice(dot + 1);
  if (!iiifQualities.includes(quality as IiifQuality)) return null;
  if (!iiifFormats.includes(format as IiifFormat)) return null;

  return {
    source,
    region,
    size: parsedSize.size,
    upscale: parsedSize.upscale,
    rotation,
    quality: quality as IiifQuality,
    format: format as IiifFormat,
  };
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- pnpm -C fiddle/assets exec vitest run iiif-path`
Expected: PASS.

- [ ] **Step 5: Typecheck**

Run: `mise exec -- pnpm -C fiddle/assets run check`
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add fiddle/assets/iiif-path.ts fiddle/assets/iiif-path.test.ts
git commit -m "feat(fiddle): IIIF path state, builders, and parser (#254)"
```

---

## Task 3: Frontend — provider-dispatch URL layer

**Files:**
- Modify: `fiddle/assets/fiddle-url-state.ts`
- Test: Create `fiddle/assets/fiddle-url-state.test.ts`

The existing imgproxy `fiddlePathForState` / `parseFiddlePath` stay (prefix-free). We add a provider-aware layer on top.

- [ ] **Step 1: Write the failing test**

Create `fiddle/assets/fiddle-url-state.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { defaultFiddleState } from "./processing-path";
import { defaultIiifState } from "./iiif-path";
import { appPathForState, parseAppPath, type AppState } from "./fiddle-url-state";

function baseAppState(): AppState {
  return {
    provider: "imgproxy",
    imgproxy: { ...defaultFiddleState },
    iiif: { ...defaultIiifState },
  };
}

describe("appPathForState", () => {
  it("prefixes the imgproxy signed path", () => {
    expect(appPathForState(baseAppState())).toBe("/imgproxy/plain/local:///images/dog.jpg");
  });

  it("emits the IIIF browser path when the provider is iiif", () => {
    const state: AppState = { ...baseAppState(), provider: "iiif" };
    expect(appPathForState(state)).toBe("/iiif/dog/full/max/0/default.jpg");
  });
});

describe("parseAppPath dispatch", () => {
  it("routes an imgproxy-prefixed path to the imgproxy slice", () => {
    const parsed = parseAppPath("/imgproxy/rs:fill:200:200/plain/local:///images/dog.jpg");
    expect(parsed.provider).toBe("imgproxy");
    expect(parsed.imgproxy.resizeEnabled).toBe(true);
    expect(parsed.imgproxy.width).toBe(200);
  });

  it("routes an iiif-prefixed path to the iiif slice", () => {
    const parsed = parseAppPath("/iiif/dog/0,0,100,100/50,/90/gray.png");
    expect(parsed.provider).toBe("iiif");
    expect(parsed.iiif.region).toEqual({ kind: "px", x: 0, y: 0, w: 100, h: 100 });
    expect(parsed.iiif.size).toEqual({ kind: "w", w: 50 });
    expect(parsed.iiif.rotation).toBe(90);
  });

  it("defaults to imgproxy for root or unknown prefix", () => {
    expect(parseAppPath("/").provider).toBe("imgproxy");
    expect(parseAppPath("/g:sm/plain/local:///images/dog.jpg").provider).toBe("imgproxy");
    expect(parseAppPath("/g:sm/plain/local:///images/dog.jpg").imgproxy.gravityEnabled).toBe(false);
  });

  it("does not leak the inactive slice into the active URL", () => {
    const state: AppState = {
      provider: "iiif",
      imgproxy: { ...defaultFiddleState, resizeEnabled: true, width: 999 },
      iiif: { ...defaultIiifState },
    };
    const url = appPathForState(state);
    expect(url.startsWith("/iiif/")).toBe(true);
    expect(url).not.toContain("999");
    expect(url).not.toContain("plain");
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mise exec -- pnpm -C fiddle/assets exec vitest run fiddle-url-state`
Expected: FAIL — `appPathForState` / `parseAppPath` / `AppState` not exported.

- [ ] **Step 3: Add the dispatcher layer to `fiddle-url-state.ts`**

Add to the imports of `fiddle/assets/fiddle-url-state.ts`:

```ts
import {
  defaultIiifState,
  iiifBrowserPath,
  parseIiifTail,
  type IiifState,
} from "./iiif-path";
```

`fiddle-url-state.ts` already imports `defaultFiddleState` and `type FiddleState` from `./processing-path` and defines `fiddlePathForState` / `parseFiddlePath`. Append:

```ts
export type Provider = "imgproxy" | "iiif";

export const providers: readonly { id: Provider; label: string }[] = [
  { id: "imgproxy", label: "imgproxy" },
  { id: "iiif", label: "IIIF (Image API 3.0)" },
];

export type AppState = {
  provider: Provider;
  imgproxy: FiddleState;
  iiif: IiifState;
};

export function defaultAppState(): AppState {
  return { provider: "imgproxy", imgproxy: { ...defaultFiddleState }, iiif: { ...defaultIiifState } };
}

// Builds the browser URL for the ACTIVE provider only. The /imgproxy prefix lives
// here, never in the imgproxy signed-path builder (fiddlePathForState).
export function appPathForState(state: AppState): string {
  if (state.provider === "iiif") {
    return iiifBrowserPath(state.iiif);
  }

  return `/imgproxy${fiddlePathForState(state.imgproxy)}`;
}

// Parses a browser URL into an AppState. The inactive slice is defaulted here;
// App.svelte merges to preserve the in-memory inactive slice across popstate.
// Dispatch is on the first path segment.
export function parseAppPath(pathname: string): AppState {
  const [, first = "", ...rest] = pathname.split("/");

  if (first === "iiif") {
    const iiif = parseIiifTail(rest.join("/"));
    return iiif === null
      ? defaultAppState()
      : { provider: "iiif", imgproxy: { ...defaultFiddleState }, iiif };
  }

  if (first === "imgproxy") {
    return {
      provider: "imgproxy",
      imgproxy: parseFiddlePath("/" + rest.join("/")),
      iiif: { ...defaultIiifState },
    };
  }

  return defaultAppState();
}
```

(`fiddlePathForState` returns the unprefixed signed path, e.g. `/plain/local:///images/dog.jpg`; we prepend `/imgproxy`. `parseFiddlePath` is keyed on `/plain/` + `local:///`, so `"/" + rest.join("/")` reconstructs a path it accepts — the empty segments from `local:///` survive the split/join.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `mise exec -- pnpm -C fiddle/assets exec vitest run fiddle-url-state`
Expected: PASS.

- [ ] **Step 5: Run the full JS suite + typecheck (no imgproxy regression)**

Run: `mise exec -- pnpm -C fiddle/assets test` then `mise exec -- pnpm -C fiddle/assets run check`
Expected: PASS — existing `processing-path.test.ts` unchanged and green.

- [ ] **Step 6: Commit**

```bash
git add fiddle/assets/fiddle-url-state.ts fiddle/assets/fiddle-url-state.test.ts
git commit -m "feat(fiddle): provider-dispatch URL layer (#254)"
```

---

## Task 4: Frontend — extract `ImgproxyControls.svelte` (pure refactor)

Behavior-preserving move: the imgproxy tool sections, their `$derived` summaries, and their handlers move into a child component bound to a `$bindable()` `state: FiddleState` prop. App still drives a single `fiddleState` (no provider yet). Verified by the unchanged test suite + check/build.

**Files:**
- Create: `fiddle/assets/ImgproxyControls.svelte`
- Modify: `fiddle/assets/App.svelte`

- [ ] **Step 1: Create `ImgproxyControls.svelte` (runes)**

Create `fiddle/assets/ImgproxyControls.svelte`. Runes mode, matching the codebase:

```svelte
<script lang="ts">
  import { Collapsible, Select, Switch, Tabs } from "bits-ui";
  import CropDimensionControl from "./CropDimensionControl.svelte";
  import RangeNumber from "./RangeNumber.svelte";
  import ResizeDimensionControl from "./ResizeDimensionControl.svelte";
  import ToolToggleHeader from "./ToolToggleHeader.svelte";
  import { fiddleObjClasses, expandedToolboxesForState } from "./fiddle-url-state";
  import {
    controlLimits,
    cropOptionSegment,
    cropPixelLimit,
    focalPointFromBounds,
    gravitySegment,
    resizeOptionSegment,
    resetCropPixelsToSource,
    trimOptionSegment,
    type FiddleState,
    type SourceImage,
  } from "./processing-path";

  let { state = $bindable(), source }: { state: FiddleState; source: SourceImage } = $props();

  // Imgproxy accordion open-state lives here now (these sections moved here).
  let orientationOpen = $state(true);
  let scaleOptionsOpen = $state(true);
  let effectsOpen = $state(true);

  const fiddleObjClassesForPicker = fiddleObjClasses as readonly string[];

  const cropWidthLimit = $derived(cropPixelLimit(source, "width"));
  const cropHeightLimit = $derived(cropPixelLimit(source, "height"));
  $effect(() => {
    const open = expandedToolboxesForState(state);
    if (open.orientationOpen) orientationOpen = true;
    if (open.scaleOptionsOpen) scaleOptionsOpen = true;
    if (open.effectsOpen) effectsOpen = true;
  });
  // Move here verbatim the imgproxy-only `$derived` summaries and helpers/handlers
  // from App.svelte: flipSegment, backgroundOpacitySummary, metadataSegments,
  // effectSegments, objClassTriggerLabel, the resize/crop/orientation/trim/aspect/
  // padding/background/effects/metadata `$derived` summaries, requestSignatureLabel
  // is imgproxy-only too, and the handlers updateCropEnabled, updateStripMetadata,
  // syncObjClasses, and the focal-point handlers (updateFocalPoint,
  // startFocalPointDrag, moveFocalPoint, dragFocalPoint, roundedFocalPoint).
</script>

<!-- Move here verbatim, in order, the imgproxy tool <section> blocks from App.svelte
     (the Resize ToolToggleHeader at ~line 757 through the end of the "Metadata &
     color" section at ~line 1600, before <div class="drawer-actions">): Resize,
     Crop, Crop aspect ratio, Gravity, Scale options, Orientation, Trim, Aspect
     canvas, Padding, Background, Effects, Format, Quality, Metadata & color.
     The shared Request Collapsible (source <select> + the signature controls) and
     its `requestOpen` STAY in App — do NOT move signature. Locate sections by their
     <h2>/ToolToggleHeader titles rather than trusting exact line numbers. -->
```

**Signature stays in App** (deviation from the spec, for a reason): the signing flow (`updateProcessingPath`, `signProcessingPath`), `signingError`, `requestSignatureLabel`, and `requestSummary` all live in App and are intertwined with `path`. Moving the signature *controls* to the child would require plumbing `signingError` across the boundary. Instead the signature controls stay in App's Request section and get gated to imgproxy in Task 6.

Mechanics (runes — much simpler than legacy):
- `state` is a `$bindable()` prop. The parent passes `bind:state={…}`. Because `state` is a deep `$state` proxy, **in-place mutation propagates** — the moved focal-point handlers keep `state.gravityFocalX = focalPoint.x` etc., and whole-object reassignments (`state = resetCropPixelsToSource(state)` in `updateCropEnabled`) propagate via `$bindable`.
- The moved markup currently references `fiddleState.X` in App; rename those to `state.X` within the moved block (the prop is named `state`).
- The imgproxy tool-section summaries are already `$derived(...)` in the runes baseline — move these `$derived` declarations and their helper functions across (renaming `fiddleState` → `state`): `orientationSummary`, `trimSummary`, `resizeSummary`, `aspectCanvasSummary`, `paddingSummary`, `backgroundSummary`, `effectsSummary`, `metadataSummary`, `cropSummary`, `cropAspectRatioSummary`, `resizeExtras`, and the helpers `flipSegment`, `backgroundOpacitySummary`, `metadataSegments`, `effectSegments`, `objClassTriggerLabel`; and the handlers `updateCropEnabled`, `updateStripMetadata`, `syncObjClasses`, `updateFocalPoint`, `startFocalPointDrag`, `moveFocalPoint`, `dragFocalPoint`, `roundedFocalPoint`. **Do NOT move** `requestSummary`/`requestSignatureLabel` (Request section stays in App).
- `cropWidthLimit`/`cropHeightLimit` derive from the `source` prop (above) — and must be **removed from App** (they're only used by the moved Crop markup; leaving them trips lint `no-unused`).
- The focal picker `<img>` uses `src={`/${source}`}`.

- [ ] **Step 2: Wire App.svelte to render the child (single-provider, temporary)**

In `App.svelte`, replace just the imgproxy tool `<section>` blocks (Resize through Metadata & color) with:

```svelte
<ImgproxyControls bind:state={fiddleState} source={fiddleState.source} />
```

- **Keep in App:** the shared Request Collapsible (`requestOpen`) holding the source `<select>` **and the signature controls**; `requestSummary` + `requestSignatureLabel`; the preview workspace, command bar, theme, mobile drawer, copy/open/reset, `resetSettings`; `updateProcessingPath`/`loadPreview`/signing (`signingError`, `pathRequestId`, `metadataRequestId`); `updateSource`/`resetCropPixelsToSource`; `previewParameters`/`outputLabel`/`sizeLabel`.
- **Remove from App** (now in the child): the imgproxy tool-section `$derived` summaries + helpers + handlers listed above; `cropWidthLimit`/`cropHeightLimit`; the `orientationOpen`/`scaleOptionsOpen`/`effectsOpen` `$state` vars; the `$effect(() => ensureActiveToolboxesOpen(fiddleState))` (App ~line 125-127); the `ensureActiveToolboxesOpen` function def (~line 211); and any now-unused imports from `processing-path`/`fiddle-url-state` (e.g. `controlLimits`, `cropOptionSegment`, `cropPixelLimit`, `focalPointFromBounds`, `gravitySegment`, `resizeOptionSegment`, `trimOptionSegment`, `fiddleObjClasses`, `expandedToolboxesForState`). **Keep** `resetCropPixelsToSource`, `resolvedOutputLabel`, `buildProcessingPath`, `signedPathForState`, `processingPathFromSignedPath`, `signProcessingPath`, `debounce`, `sampleImages`, `processedSizeLabel` (App still uses them). `requestOpen` stays.
- **Also in this step (or App won't compile):** `restoreStateFromLocation` (App ~line 206-209) currently calls `ensureActiveToolboxesOpen(fiddleState)` — **delete that call** (toolbox-open is now the child's own `$effect`). After this, no App code references `ensureActiveToolboxesOpen`.

- [ ] **Step 3: Typecheck, lint, format, build, and test**

Run:
```
mise exec -- pnpm -C fiddle/assets run check
mise exec -- pnpm -C fiddle/assets run lint
mise exec -- pnpm -C fiddle/assets run format:check
mise exec -- pnpm -C fiddle/assets test
mise exec -- pnpm -C fiddle/assets run build
```
Expected: all PASS; the existing imgproxy tests are unchanged and green.

- [ ] **Step 4: Manual smoke (recommended)**

Run the demo (`mise run server` or the project's run skill), confirm imgproxy controls still drive the preview and the URL exactly as before — pay attention to the focal-point picker and object-class controls (the in-place-mutation paths).

- [ ] **Step 5: Commit**

```bash
git add fiddle/assets/ImgproxyControls.svelte fiddle/assets/App.svelte
git commit -m "refactor(fiddle): extract ImgproxyControls.svelte (#254)"
```

---

## Task 5: Frontend — `IiifControls.svelte` (grouped panel)

**Files:**
- Create: `fiddle/assets/IiifControls.svelte`

- [ ] **Step 1: Create the component (runes)**

Create `fiddle/assets/IiifControls.svelte`. The single grouped panel binds to an `IiifState` slice via `$bindable()` and reads `source` for px-region limits. In runes, `bind:value` into a deep `$state` proxy member (`state.region.x`) propagates — no callbacks or whole-object copies needed:

```svelte
<script lang="ts">
  import { Switch } from "bits-ui";
  import RangeNumber from "./RangeNumber.svelte";
  import { cropPixelLimit, type SourceImage } from "./processing-path";
  import { iiifControlLimits, type IiifState, type IiifRegion, type IiifSize } from "./iiif-path";

  let { state = $bindable(), source }: { state: IiifState; source: SourceImage } = $props();

  const widthLimit = $derived(cropPixelLimit(source, "width"));
  const heightLimit = $derived(cropPixelLimit(source, "height"));

  function setRegionKind(kind: IiifRegion["kind"]): void {
    state.region =
      kind === "full"
        ? { kind: "full" }
        : kind === "square"
          ? { kind: "square" }
          : kind === "px"
            ? { kind: "px", x: 0, y: 0, w: widthLimit.max, h: heightLimit.max }
            : { kind: "pct", x: 0, y: 0, w: 50, h: 50 };
  }

  function setSizeKind(kind: IiifSize["kind"]): void {
    state.size =
      kind === "max"
        ? { kind: "max" }
        : kind === "w"
          ? { kind: "w", w: 400 }
          : kind === "h"
            ? { kind: "h", h: 300 }
            : kind === "wh"
              ? { kind: "wh", w: 400, h: 300 }
              : kind === "confined"
                ? { kind: "confined", w: 400, h: 300 }
                : { kind: "pct", n: 50 };
  }
</script>

<section class="tool-section">
  <div class="accordion-heading"><div><h2>IIIF parameters</h2></div></div>

  <label class="field">
    <span>Region</span>
    <select value={state.region.kind} onchange={(e) => setRegionKind(e.currentTarget.value as IiifRegion["kind"])}>
      <option value="full">full</option>
      <option value="square">square</option>
      <option value="px">pixel (x,y,w,h)</option>
      <option value="pct">percent (x,y,w,h)</option>
    </select>
  </label>

  {#if state.region.kind === "px"}
    <RangeNumber label="x" bind:value={state.region.x} min={0} max={widthLimit.max} step={1} />
    <RangeNumber label="y" bind:value={state.region.y} min={0} max={heightLimit.max} step={1} />
    <RangeNumber label="w" bind:value={state.region.w} min={1} max={widthLimit.max} step={1} />
    <RangeNumber label="h" bind:value={state.region.h} min={1} max={heightLimit.max} step={1} />
  {:else if state.region.kind === "pct"}
    <RangeNumber label="x %" bind:value={state.region.x} min={0} max={100} step={0.1} inputStep="any" />
    <RangeNumber label="y %" bind:value={state.region.y} min={0} max={100} step={0.1} inputStep="any" />
    <RangeNumber label="w %" bind:value={state.region.w} min={0.1} max={100} step={0.1} inputStep="any" />
    <RangeNumber label="h %" bind:value={state.region.h} min={0.1} max={100} step={0.1} inputStep="any" />
  {/if}

  <label class="field">
    <span>Size</span>
    <select value={state.size.kind} onchange={(e) => setSizeKind(e.currentTarget.value as IiifSize["kind"])}>
      <option value="max">max</option>
      <option value="w">width only (w,)</option>
      <option value="h">height only (,h)</option>
      <option value="wh">width × height (w,h)</option>
      <option value="confined">confined (!w,h)</option>
      <option value="pct">percent (pct:n)</option>
    </select>
  </label>

  {#if state.size.kind === "w"}
    <RangeNumber label="Width" bind:value={state.size.w} min={iiifControlLimits.size.min} max={iiifControlLimits.size.max} step={1} suffix="px" />
  {:else if state.size.kind === "h"}
    <RangeNumber label="Height" bind:value={state.size.h} min={iiifControlLimits.size.min} max={iiifControlLimits.size.max} step={1} suffix="px" />
  {:else if state.size.kind === "wh" || state.size.kind === "confined"}
    <RangeNumber label="Width" bind:value={state.size.w} min={iiifControlLimits.size.min} max={iiifControlLimits.size.max} step={1} suffix="px" />
    <RangeNumber label="Height" bind:value={state.size.h} min={iiifControlLimits.size.min} max={iiifControlLimits.size.max} step={1} suffix="px" />
  {:else if state.size.kind === "pct"}
    <RangeNumber label="Percent" bind:value={state.size.n} min={iiifControlLimits.pct.min} max={iiifControlLimits.pct.max} step={1} suffix="%" />
  {/if}

  <label class="switch-field">
    <Switch.Root class="switch-root" bind:checked={state.upscale}>
      <Switch.Thumb class="switch-thumb" />
    </Switch.Root>
    <span>Allow upscaling (^)</span>
  </label>

  <label class="field">
    <span>Rotation</span>
    <select bind:value={state.rotation}>
      <option value={0}>0°</option>
      <option value={90}>90°</option>
      <option value={180}>180°</option>
      <option value={270}>270°</option>
    </select>
  </label>

  <label class="field">
    <span>Quality</span>
    <select bind:value={state.quality}>
      <option value="default">default</option>
      <option value="color">color</option>
      <option value="gray">gray</option>
      <option value="bitonal">bitonal</option>
    </select>
  </label>

  <label class="field">
    <span>Format</span>
    <select bind:value={state.format}>
      <option value="jpg">jpg</option>
      <option value="png">png</option>
      <option value="webp">webp</option>
      <option value="avif">avif</option>
    </select>
  </label>
</section>
```

Notes:
- Reuses the existing `.tool-section` / `.field` / `.switch-field` global styles. `RangeNumber` props (`value` via `$bindable`, `min`/`max`/`step`/`inputStep`/`suffix`/`label`) are confirmed in `fiddle/assets/RangeNumber.svelte`.
- If `svelte-check` rejects `bind:value={state.region.x}` on the narrowed union member, fall back to `RangeNumber`'s `onValueChange` (it exists) writing the field: `onValueChange={(v) => { if (state.region.kind === "px") state.region.x = v; }}`. Try `bind:` first — runes deep reactivity makes it work.

- [ ] **Step 2: Typecheck**

Run: `mise exec -- pnpm -C fiddle/assets run check`
Expected: no errors (the component is not mounted yet, but it must typecheck).

- [ ] **Step 3: Commit**

```bash
git add fiddle/assets/IiifControls.svelte
git commit -m "feat(fiddle): IiifControls grouped panel (#254)"
```

---

## Task 6: Frontend — App container, provider dropdown, dispatcher wiring

**Files:**
- Modify: `fiddle/assets/App.svelte`

- [ ] **Step 1: Switch App to `AppState` and add the provider dropdown**

In `App.svelte`:
- Add imports:

```ts
import {
  appPathForState,
  defaultAppState,
  parseAppPath,
  providers,
  type AppState,
} from "./fiddle-url-state";
import { iiifFetchPath } from "./iiif-path";
import IiifControls from "./IiifControls.svelte";
```

- Replace the `fiddleState` declaration and its `initialFiddleState()` seed with an `AppState`, capturing the parsed initial state **once** (mirrors the baseline's `const initialState = initialFiddleState()`):

```ts
function initialAppState(): AppState {
  if (typeof window === "undefined") return defaultAppState();
  return parseAppPath(window.location.pathname);
}

const initial = initialAppState();
let appState: AppState = $state(initial);
let path = $state(
  initial.provider === "iiif" ? iiifFetchPath(initial.iiif) : buildProcessingPath(initial.imgproxy),
);
```

- Add the provider dropdown as the first control, above the Request section:

```svelte
<label class="field">
  <span>Provider</span>
  <select bind:value={appState.provider}>
    {#each providers as provider}
      <option value={provider.id}>{provider.label}</option>
    {/each}
  </select>
</label>
```

- Render the active panel where `<ImgproxyControls …>` was placed in Task 4:

```svelte
{#if appState.provider === "imgproxy"}
  <ImgproxyControls bind:state={appState.imgproxy} source={appState.imgproxy.source} />
{:else}
  <IiifControls bind:state={appState.iiif} source={appState.iiif.source} />
{/if}
```

- **Rewrite EVERY remaining `fiddleState` reference in App to `appState.<slice>`** — after renaming the `let`, any leftover `fiddleState` is a compile error. The readers still in App after Task 4 (the tool sections moved out) are, at minimum:
  - `requestSummary` (App ~line 138) — **branch per provider** (IIIF has no signature):
    ```ts
    const requestSummary = $derived(
      appState.provider === "imgproxy"
        ? `${appState.imgproxy.source.replace(/^images\//, "")} / ${requestSignatureLabel(appState.imgproxy, signingError)}`
        : appState.iiif.source.replace(/^images\//, ""),
    );
    ```
  - `resetSettings` (App ~line 597) — reset the **active** slice:
    ```ts
    function resetSettings(): void {
      if (appState.provider === "imgproxy") {
        appState.imgproxy = resetFiddleSettings(appState.imgproxy);
      } else {
        appState.iiif = { ...defaultIiifState, source: appState.iiif.source };
      }
    }
    ```
    (import `resetFiddleSettings` from `./fiddle-url-state` and `defaultIiifState` from `./iiif-path`.)
  - the source `<select>` (App ~line 710): `value={fiddleState.source}` → `value={currentSource}` (Step 2).
  - the **signature controls** (the `<select value={fiddleState.signatureMode}>` + key/salt inputs in the Request Collapsible): bind to `appState.imgproxy.*` and **gate to imgproxy** so they don't show for IIIF:
    ```svelte
    {#if appState.provider === "imgproxy"}
      <!-- signature <select> bind:value={appState.imgproxy.signatureMode}, key/salt
           bind:value={appState.imgproxy.signatureKey}/{...signatureSalt} -->
    {/if}
    ```
  - `requestSignatureLabel` stays in App, now called with `appState.imgproxy`.
- After this step, grep App.svelte for `fiddleState` — there must be zero matches.

- [ ] **Step 2: Shared source select + cross-provider reset**

The shared Request `source` select updates the active provider's `source` and resets source-dependent pixel fields for BOTH providers. Replace `updateSource`:

```ts
const currentSource = $derived(
  appState.provider === "iiif" ? appState.iiif.source : appState.imgproxy.source,
);

function updateSource(event: Event): void {
  const select = event.currentTarget;
  if (!(select instanceof HTMLSelectElement)) return;
  const source = select.value as SourceImage;

  // Reset both providers' source-dependent pixel fields so a stale px region/crop
  // from a larger image can't survive a source change.
  appState.imgproxy = resetCropPixelsToSource({ ...appState.imgproxy, source });
  appState.iiif = { ...appState.iiif, source, region: { kind: "full" } };
}
```

Point the source `<select>` at `value={currentSource}` and `onchange={updateSource}`.

- [ ] **Step 3: Branch the path effect, preview params, and output label per provider**

The runes baseline has `$effect(() => updateProcessingPath(fiddleState))`. Make it provider-aware, and branch the derived preview/label:

```ts
$effect(() => {
  if (appState.provider === "imgproxy") {
    updateProcessingPath(appState.imgproxy); // async signed flow sets `path`, guarded by pathRequestId
  } else {
    pathRequestId += 1; // invalidate any in-flight imgproxy signing so it can't clobber `path`
    path = iiifFetchPath(appState.iiif);
  }
});

const previewParameters = $derived(
  appState.provider === "imgproxy"
    ? path.replace(/^\/[^/]+\/[^/]+\//, "")
    : path.replace(/^\/iiif-image\//, ""),
);
const outputLabel = $derived(
  appState.provider === "imgproxy"
    ? resolvedOutputLabel(appState.imgproxy, processedMetadata)
    : appState.iiif.format,
);
```

- `updateProcessingPath` still takes a `FiddleState` and reads signature fields off `appState.imgproxy`; its internal `const requestId = ++pathRequestId` guard means bumping `pathRequestId` in the IIIF branch invalidates a pending imgproxy signing promise. **Keep `pathRequestId` a plain non-reactive `let`** (as in the baseline, App ~line 74) — the `pathRequestId += 1` read-then-write inside the `$effect` is only safe because `pathRequestId` is *not* tracked; promoting it to `$state` would make the effect self-trigger into an infinite loop. `updatePreviewPath(path)` effect and `updateFiddleLocation(...)` effect stay; point the location effect at the dispatcher:

```ts
$effect(() => {
  updateFiddleLocation(appPathForState(appState));
});
```

- `updateFiddleLocation` already calls `window.history.replaceState` (App.svelte:93), so a provider switch (and the bare-`/` → `/imgproxy/…` canonicalization) updates the URL via `replaceState` by construction — no pushed history entry.

- [ ] **Step 4: Preserve the inactive in-memory slice across popstate**

Update `restoreStateFromLocation` so Back/Forward re-derives only the active slice and keeps the other panel's in-memory edits:

```ts
function restoreStateFromLocation(): void {
  const parsed = parseAppPath(window.location.pathname);
  appState =
    parsed.provider === "iiif"
      ? { provider: "iiif", imgproxy: appState.imgproxy, iiif: parsed.iiif }
      : { provider: "imgproxy", imgproxy: parsed.imgproxy, iiif: appState.iiif };
}
```

- [ ] **Step 5: Typecheck, lint, format, test, build**

Run:
```
mise exec -- pnpm -C fiddle/assets run check
mise exec -- pnpm -C fiddle/assets run lint
mise exec -- pnpm -C fiddle/assets run format:check
mise exec -- pnpm -C fiddle/assets test
mise exec -- pnpm -C fiddle/assets run build
```
Expected: all PASS.

- [ ] **Step 6: Manual smoke**

Run the demo. Verify: provider dropdown swaps panels; imgproxy URL is now `/imgproxy/…` with working preview/signing; selecting IIIF yields `/iiif/dog/full/max/0/default.jpg` and a working preview; region/size/rotation/quality/format controls drive the URL and preview; switching providers doesn't leak params; Back/Forward keeps the other panel's edits.

- [ ] **Step 7: Commit**

```bash
git add fiddle/assets/App.svelte
git commit -m "feat(fiddle): two-provider container, dropdown, and dispatch wiring (#254)"
```

---

## Task 7: Interaction test for the segment builders + full gate

**Files:**
- Modify: `fiddle/assets/processing-path.test.ts`

- [ ] **Step 1: Add a regression test for the segment builders**

These cover the **pure builder functions** the focal-point and object-class flows feed (no DOM). The `bind:`/in-place-mutation write-back path is verified by the manual smoke in Task 6 Step 6 (no Svelte component-testing library is configured in `fiddle/assets`). Append to `fiddle/assets/processing-path.test.ts`:

```ts
import { gravitySegment, objGravitySegmentFromState, defaultFiddleState } from "./processing-path";

describe("object-gravity + focal-point segment building", () => {
  it("builds a focal-point gravity segment", () => {
    const state = { ...defaultFiddleState, gravityEnabled: true, gravityMode: "focalPoint" as const, gravityFocalX: 0.25, gravityFocalY: 0.75 };
    expect(gravitySegment(state)).toBe("g:fp:0.25:0.75");
  });

  it("builds a weighted object segment from selected classes", () => {
    const state = { ...defaultFiddleState, gravityMode: "object" as const, objSubMode: "weighted" as const, objSelectedClasses: ["dog", "person"], objWeights: { dog: 2, person: 1 } };
    expect(objGravitySegmentFromState(state)).toBe("g:objw:dog:2:person:1");
  });
});
```

(If `processing-path.test.ts` already imports some of these symbols, merge into the existing import rather than duplicating.)

- [ ] **Step 2: Run the focused test**

Run: `mise exec -- pnpm -C fiddle/assets exec vitest run processing-path`
Expected: PASS.

- [ ] **Step 3: Run the full demo gate**

Run: `mise run precommit:fiddle`
Expected: PASS — Elixir gate (format/compile/credo/test for the library) + fiddle verify suite (fiddle Elixir checks + JS test/check/lint/format/build).

- [ ] **Step 4: Commit**

```bash
git add fiddle/assets/processing-path.test.ts
git commit -m "test(fiddle): cover object-gravity + focal-point segment builders (#254)"
```

---

## Self-review notes (for the implementer)

- **Runes mode everywhere.** The codebase migrated to Svelte 5 runes in #291. New components use `$props`/`$bindable`/`$state`/`$derived`/`$effect` — never `export let`/`$:`. In-place mutation of a `$bindable()` `$state`-proxy prop propagates to the parent, so `bind:value={state.region.x}` and `state.gravityFocalX = …` both work; no whole-object-assignment workarounds are needed (those were a legacy-mode artifact, now removed).
- **No-leakage** is structural: `appPathForState` for provider X never reads `appState[Y]`. Task 3's test pins it.
- **Signing invariant:** the `/imgproxy` prefix exists only in `appPathForState`/`parseAppPath`. Never pass it to `signedPathForState`, `buildProcessingPath`, the preview `fetch`, or the Copy URL (which uses `path`, the `/img/<sig>/…` fetch path).
- **CORS** is interim manual composition (#284 removes it). Keep the wrapper until then.
- Confirm `RangeNumber`/`ToolToggleHeader`/`CropDimensionControl` prop names by reading the components if a type error appears — do not invent props.

## Before pushing (AGENTS.md)

- Rename the branch to a descriptive name before the first push — `git branch -m feat/fiddle-two-providers-iiif` (rename only the branch; leave the worktree dir).
- PR body must include a bare line `Fixes #254` (plain keyword, own line) so the issue auto-closes; verify with `gh pr view <n> --json closingIssuesReferences`. Do not use a closing keyword for #284 (separate follow-up not resolved here).
