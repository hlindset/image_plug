# ImagePipe Fiddle Extraction Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the interactive demo out of the `ImagePipe` library into a standalone nested Phoenix app, `ImagePipeFiddle` (`:image_pipe_fiddle`), served at `/`, with the imgproxy processing endpoint mounted at `/img`.

**Architecture:** A stripped Phoenix 1.8.7 app in `fiddle/` depends on the library via `{:image_pipe, path: ".."}`. The Svelte 5 SPA moves to `fiddle/assets/`, built by Vite with PhoenixVite 0.4.3 hand-wired (no Igniter installer). The router serves the SPA shell at `/`, `Plug.Static` serves sample images at `/images`, and `forward "/img"` sends imgproxy URLs to `ImagePipe.Plug`. The library reverts to pure Elixir: the dev server (`SimpleServer`), its Mix task, and all JS tooling are deleted; ML deps (`image_vision`/`ortex`) move to the fiddle as hard deps.

**Tech Stack:** Elixir/Phoenix 1.8.7, Bandit, PhoenixVite 0.4.3, Vite 8, Svelte 5, pnpm, oxlint/oxfmt, vitest, `image_vision`+`ortex` (ONNX/Rust face detection).

**Reference:** Design spec `docs/superpowers/specs/2026-06-09-extract-fiddle-app-design.md`. Read it for rationale; this plan is the executable steps.

---

## Conventions for the executing agent

- Run all Elixir/mix commands for the **library** from the repo root, and for the **fiddle** from `fiddle/`, both through `mise exec -- ...` (e.g. `mise exec -- mix compile`). The repo's `mise.toml` pins Elixir 1.20/OTP 29 and Node.
- The library currently still builds during early phases. Do **not** delete library demo machinery until Phase 6 — the fiddle must work first.
- Commit after each task. Use the message shown. End every commit body with:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
- Sample images live in the library at `priv/static/images/` (11 files). The fiddle gets its **own copy**; never point the fiddle at the library's `priv`.

---

## File Structure (what gets created / changed)

**New — the fiddle app (`fiddle/`):**
- `fiddle/mix.exs` — project, deps (`image_pipe` path dep, phoenix, bandit, phoenix_vite, image_vision, ortex), aliases.
- `fiddle/config/{config,dev,prod,runtime,test}.exs` — endpoint + imgproxy + cache + vite wiring.
- `fiddle/lib/image_pipe_fiddle/application.ex` — supervisor: Endpoint, face warmup, optional cache; builds + stashes imgproxy opts; attaches default Logger.
- `fiddle/lib/image_pipe_fiddle_web.ex`, `endpoint.ex`, `router.ex`, `controllers/page_controller.ex`, `controllers/page_html.ex`, `components/layouts.ex` + `layouts/root.html.heex` — minimal web layer rendering the SPA shell.
- `fiddle/lib/image_pipe_fiddle_web/imgproxy.ex` — thin Plug forwarding to `ImagePipe.Plug` with runtime opts.
- `fiddle/assets/**` — the moved Svelte SPA (`main.ts`, `App.svelte`, controls, `processing-path.ts`, `demo-url-state.ts`, `theme.ts`, `styles.css`, `*.test.ts`).
- `fiddle/assets/vite.config.ts`, `svelte.config.js`, `tsconfig.json`, `.oxfmtrc.json`, `package.json`.
- `fiddle/priv/static/images/*` — own copy of sample images.
- `fiddle/test/**` — fiddle wire-level Elixir tests.

(No `favicon.ico`/`robots.txt` are created; `static_paths` lists only `assets`+`images`. A browser `/favicon.ico` request harmlessly hits the SPA-shell catch-all — it never reaches the `/img` parser, so there is no parser noise to suppress.)

**Library — modified/deleted (Phase 6):**
- Delete `dev/simple_server.ex`, `lib/mix/tasks/image_pipe.server.ex`, `test/simple_server_test.exs`, `test/mix/tasks/image_pipe_server_test.exs`.
- Modify `mix.exs` (elixirc_paths, deps, aliases), `.gitignore`, `README.md`, `AGENTS.md`.
- Delete root `package.json`, `pnpm-workspace.yaml`, `pnpm-lock.yaml`, `vite.config.ts`, `tsconfig.json`, `.oxfmtrc.json`.
- Modify `mise.toml`.

---

## Phase 1 — Scaffold the fiddle Phoenix app

### Task 1.1: Generate the stripped Phoenix app

**Files:** Create `fiddle/**` (generator output).

- [ ] **Step 1: Ensure the Phoenix generator is available**

Run: `mise exec -- mix archive.install hex phx_new 1.8.7 --force`
Expected: installs `phx_new` archive (or reports already installed).

- [ ] **Step 2: Generate the app into `fiddle/`**

From the repo root:

```bash
mise exec -- mix phx.new fiddle \
  --module ImagePipeFiddle --app image_pipe_fiddle \
  --no-ecto --no-mailer --no-gettext --no-dashboard \
  --no-tailwind --no-live --no-assets --no-install
```

Expected: generates `fiddle/` with `mix.exs`, `lib/image_pipe_fiddle{,_web}/`, `config/`, no `assets/`, no Ecto/LiveView/mailer. Answer "Y" if prompted to proceed. (`--no-assets` means no esbuild/tailwind pipeline — we add Vite ourselves.)

- [ ] **Step 3: Add the path dep on the library**

In `fiddle/mix.exs`, inside `deps/0`, add as the first dep:

```elixir
{:image_pipe, path: ".."},
```

- [ ] **Step 4: Fetch deps and confirm it compiles + boots**

```bash
cd fiddle && mise exec -- mix deps.get && mise exec -- mix compile
```
Expected: compiles (the library compiles as a path dep). Warnings about unused generated assets config are acceptable for now.

- [ ] **Step 5: Smoke-boot the server**

Run: `cd fiddle && mise exec -- mix phx.server` (then Ctrl-C twice after it prints `Running ImagePipeFiddleWeb.Endpoint ... at http://...`).
Expected: boots without error on port 4000. (The default generated page may 500 because `--no-assets` removed the asset tags from the root layout — that is fine; Phase 2 replaces the layout.)

- [ ] **Step 6: Commit**

```bash
cd /Users/hlindset/src/image_plug/.claude/worktrees/elegant-ardinghelli-5004cf
git add fiddle
git commit -m "feat(fiddle): scaffold stripped Phoenix 1.8.7 app with image_pipe path dep"
```

### Task 1.2: Minimal root layout + page controller serving an SPA shell

**Files:**
- Modify: `fiddle/lib/image_pipe_fiddle_web/router.ex`
- Modify/Create: `fiddle/lib/image_pipe_fiddle_web/controllers/page_controller.ex`, `page_html.ex`, `page_html/home.html.heex`
- Modify: `fiddle/lib/image_pipe_fiddle_web/components/layouts/root.html.heex`

- [ ] **Step 1: Replace the home template with the SPA mount point**

Replace the contents of `fiddle/lib/image_pipe_fiddle_web/controllers/page_html/home.html.heex` with exactly:

```heex
<div id="fiddle-app"></div>
```

- [ ] **Step 2: Strip the root layout to a bare HTML shell (no asset tags yet)**

Replace `fiddle/lib/image_pipe_fiddle_web/components/layouts/root.html.heex` with:

```heex
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>ImagePipe Fiddle</title>
  </head>
  <body>
    {@inner_content}
  </body>
</html>
```

- [ ] **Step 3: Point the catch-all route at the page controller, rendering only the shell**

In `fiddle/lib/image_pipe_fiddle_web/router.ex`, ensure the browser scope has a catch-all GET that renders the shell (replace the default `get "/"` line):

```elixir
scope "/", ImagePipeFiddleWeb do
  pipe_through :browser

  get "/*path", PageController, :home
end
```

**Bypass the app layout** so the body is *only* the SPA mount div — not Phoenix's generated app chrome (flash group, nav). Phoenix 1.8 wraps `home.html.heex` in `Layouts.app` (the inner layout) inside `root.html.heex` (the outer layout that owns `<head>`). We keep `root` (it carries the Vite tags in Phase 2) but disable the inner app layout. In `fiddle/lib/image_pipe_fiddle_web/controllers/page_controller.ex`:

```elixir
defmodule ImagePipeFiddleWeb.PageController do
  use ImagePipeFiddleWeb, :controller

  def home(conn, _params) do
    render(conn, :home, layout: false)
  end
end
```

(The generated controller already defines `:home` + `page_html/home.html.heex`; `layout: false` disables only the inner app layout, not `root`.)

- [ ] **Step 4: Verify the shell renders at `/` and a deep link**

Boot (`cd fiddle && mise exec -- mix phx.server`), then in another shell:

```bash
curl -s localhost:4000/ | grep fiddle-app
curl -s 'localhost:4000/rs:fill:640:360/plain/local:///images/dog.jpg' | grep fiddle-app
```
Expected: both print the `<div id="fiddle-app">` line. Ctrl-C the server.

- [ ] **Step 5: Commit**

```bash
git add fiddle/lib/image_pipe_fiddle_web
git commit -m "feat(fiddle): serve SPA shell at / and on deep-link paths"
```

---

## Phase 2 — Hand-wire PhoenixVite + move the Svelte SPA

> PhoenixVite 0.4.3 facts used here (verbatim from its Hex package): the tag component is `PhoenixVite.Components.assets` (fully-qualified, no import); dev mode is detected by a `:vite` watcher key via `PhoenixVite.Components.has_vite_watcher?/1`; the prod manifest is at `priv/static/.vite/manifest.json`; the npm HMR plugin is `phoenixVitePlugin` from the `phoenix_vite` npm package (installed as `file:../deps/phoenix_vite`).

### Task 2.1: Add deps and create the assets workspace

**Files:**
- Modify: `fiddle/mix.exs` (deps)
- Create: `fiddle/assets/package.json`, `fiddle/.oxfmtrc.json`, `fiddle/tsconfig.json`

- [ ] **Step 1: Add phoenix_vite to mix deps**

In `fiddle/mix.exs` `deps/0` add:

```elixir
{:phoenix_vite, "~> 0.4.0"},
```

Run `cd fiddle && mise exec -- mix deps.get`. Expected: fetches `phoenix_vite` (and `phoenix_live_view` transitively — unused, that's fine).

- [ ] **Step 2: Create `fiddle/assets/package.json`**

Port the current root `package.json` demo deps, add `phoenix_vite` + `svelte` vite plugin, point scripts at `.` (assets root is the Vite root):

```json
{
  "private": true,
  "type": "module",
  "scripts": {
    "build": "vite build",
    "dev": "vite",
    "check": "tsgo --project tsconfig.json --noEmit && svelte-check --tsconfig tsconfig.json",
    "format": "oxfmt --write . vite.config.ts",
    "format:check": "oxfmt --check . vite.config.ts",
    "lint": "oxlint . vite.config.ts --ignore-pattern node_modules/**",
    "test": "vitest run"
  },
  "devDependencies": {
    "@sveltejs/vite-plugin-svelte": "7.1.2",
    "@types/node": "25.8.0",
    "@typescript/native-preview": "7.0.0-dev.20260515.1",
    "image-size": "^2.0.2",
    "oxfmt": "^0.50.0",
    "oxlint": "1.64.0",
    "phoenix_vite": "file:../deps/phoenix_vite",
    "svelte": "5.55.7",
    "svelte-check": "^4.4.8",
    "typescript": "6.0.3",
    "vite": "8.0.13",
    "vitest": "4.1.6"
  },
  "dependencies": {
    "bits-ui": "2.18.1",
    "geist": "1.7.0"
  }
}
```

- [ ] **Step 2b: Recreate the geist peer-dep workaround**

The root repo used a `pnpm-workspace.yaml` `packageExtensions` to make `geist`'s `next` peer optional. Reproduce it in `fiddle/package.json` (pnpm reads `pnpm.packageExtensions` from the nearest package.json too). Create `fiddle/pnpm-workspace.yaml`:

```yaml
packages: []
packageExtensions:
  "geist@*":
    peerDependenciesMeta:
      next:
        optional: true
```

(If pnpm warns about an empty `packages`, drop that key.)

- [ ] **Step 3: Copy `tsconfig.json` and `.oxfmtrc.json`**

```bash
cp tsconfig.json fiddle/tsconfig.json
cp .oxfmtrc.json fiddle/.oxfmtrc.json
```

Edit `fiddle/tsconfig.json`: the current root `tsconfig.json` `include` is `["demo/src/**/*.ts", "vite.config.ts"]`. Repoint it to the assets root: `"include": ["**/*.ts", "**/*.svelte", "vite.config.ts"]`. (If `pnpm run check` still fails on path resolution after the Task 2.2 move, this is the first place to look.)

- [ ] **Step 4: Commit**

```bash
git add fiddle/mix.exs fiddle/mix.lock fiddle/assets/package.json fiddle/pnpm-workspace.yaml fiddle/tsconfig.json fiddle/.oxfmtrc.json
git commit -m "feat(fiddle): add phoenix_vite dep and assets workspace config"
```

### Task 2.2: Move the Svelte source and sample images

**Files:**
- Create: `fiddle/assets/*` (moved from `demo/src/*`)
- Create: `fiddle/priv/static/images/*` (copied from `priv/static/images/*`)
- Create: `fiddle/assets/svelte.config.js`

- [ ] **Step 1: Move the Svelte source into the assets root**

```bash
mkdir -p fiddle/assets
git mv demo/src/* fiddle/assets/
```

This brings `main.ts`, `App.svelte`, `*.svelte`, `processing-path.ts`, `demo-url-state.ts`, `theme.ts`, `styles.css`, `vite-env.d.ts`, and the `*.test.ts` files. (We keep `demo/index.html`/`dev.html` for now; they're deleted in Step 6.)

- [ ] **Step 2: Copy the sample images (own copy)**

```bash
mkdir -p fiddle/priv/static/images
cp priv/static/images/* fiddle/priv/static/images/
```

Expected: 11 image files now under `fiddle/priv/static/images/`.

- [ ] **Step 3: Rename the mount id `demo-app` → `fiddle-app`**

In `fiddle/assets/main.ts`, change `getElementById("demo-app")` → `getElementById("fiddle-app")`.
In `fiddle/assets/styles.css`, change the `#demo-app` selector (around line 126) → `#fiddle-app`.

Verify nothing else references it:
```bash
grep -rn "demo-app" fiddle/assets
```
Expected: no matches.

- [ ] **Step 3b: Fix the `geist` font paths in `styles.css`**

`styles.css` references the bundled Geist fonts at `../../node_modules/geist/...` (around lines 3 and 11) — a depth valid from the old `demo/src/`. After the move to `fiddle/assets/`, pnpm installs into `fiddle/assets/node_modules/`, so the correct relative path from `fiddle/assets/styles.css` is `./node_modules/geist/...`. Update each `url(...)`/`@font-face src` accordingly. (Verify the fonts actually resolve in Task 2.3 Step 3's build, and visually on first boot — a broken path silently drops the custom font.)

- [ ] **Step 4: Add `fiddle/assets/svelte.config.js`**

```js
import { vitePreprocess } from "@sveltejs/vite-plugin-svelte";

export default {
  preprocess: vitePreprocess(),
};
```

- [ ] **Step 5: Delete the obsolete demo HTML shells**

```bash
git rm demo/index.html demo/dev.html
```

(The `demo/` directory is now empty except moved files already staged; it is removed entirely in Phase 6 along with the rest of the old tooling. If `demo/` is empty now, `git status` will show it gone.)

- [ ] **Step 6: Commit**

```bash
git add fiddle/assets fiddle/priv/static/images
git commit -m "feat(fiddle): move Svelte SPA and sample images into the app; rename mount id"
```

### Task 2.3: Create the Vite config (Svelte + sample-images + phoenix_vite)

**Files:**
- Create: `fiddle/assets/vite.config.ts`

- [ ] **Step 1: Write `fiddle/assets/vite.config.ts`**

Port the current root `vite.config.ts` `sampleImagesPlugin` + oxc transform **verbatim**, change `root`/`base`/`outDir` to the fiddle layout, point the images dir at `../priv/static/images`, set `manifest: true`, `emptyOutDir: false` (so the build does not wipe `priv/static/images`), and add `phoenixVitePlugin`. The Vite root is the assets dir itself, so the entry is `main.ts`:

```ts
import { svelte } from "@sveltejs/vite-plugin-svelte";
import { phoenixVitePlugin } from "phoenix_vite";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";
import { imageSize } from "image-size";
import { transformWithOxc, type Plugin } from "vite";

const currentDirectory = dirname(fileURLToPath(import.meta.url));
const sampleImagesModuleId = "virtual:sample-images";
const resolvedSampleImagesModuleId = `\0${sampleImagesModuleId}.ts`;
const sampleImageExtensions = new Set([".avif", ".jpeg", ".jpg", ".png", ".webp"]);
const maxDemoOriginBytes = 10_000_000;
const maxDemoInputPixels = 40_000_000;

function sampleImagesPlugin(
  imagesDirectory = resolve(currentDirectory, "../priv/static/images"),
): Plugin {
  return {
    name: "sample-images",
    resolveId(id) {
      if (id === sampleImagesModuleId) return resolvedSampleImagesModuleId;
      return null;
    },
    async load(id) {
      if (id === resolvedSampleImagesModuleId) {
        const transformed = await transformWithOxc(
          buildSampleImagesModule(imagesDirectory),
          "sample-images.ts",
        );
        return transformed.code;
      }
      return null;
    },
    configureServer(server) {
      server.watcher.add(imagesDirectory);
      server.watcher.on("all", (_event, changedPath) => {
        if (relative(imagesDirectory, changedPath).startsWith("..")) return;
        const m = server.moduleGraph.getModuleById(resolvedSampleImagesModuleId);
        if (m !== undefined) {
          server.moduleGraph.invalidateModule(m);
          server.ws.send({ type: "full-reload" });
        }
      });
    },
  };
}

function buildSampleImagesModule(imagesDirectory: string): string {
  const sampleImages = readdirSync(imagesDirectory)
    .filter((fileName) => sampleImageExtensions.has(fileExtension(fileName)))
    .sort((left, right) => left.localeCompare(right))
    .flatMap((fileName) => {
      const filePath = join(imagesDirectory, fileName);
      const fileSize = statSync(filePath).size;
      if (fileSize > maxDemoOriginBytes) return [];
      const dimensions = imageSize(readFileSync(filePath));
      if (dimensions.width === undefined || dimensions.height === undefined) {
        throw new Error(`Could not read image dimensions for ${filePath}`);
      }
      if (dimensions.width * dimensions.height > maxDemoInputPixels) return [];
      return [
        {
          path: `images/${encodeURIComponent(fileName)}`,
          label: fileName,
          width: dimensions.width,
          height: dimensions.height,
        },
      ];
    });
  return `export const sampleImages = ${JSON.stringify(sampleImages, null, 2)} as const;\n`;
}

function fileExtension(fileName: string): string {
  const lastDotIndex = fileName.lastIndexOf(".");
  if (lastDotIndex === -1) return "";
  return fileName.slice(lastDotIndex).toLowerCase();
}

export default defineConfig({
  base: "/",
  plugins: [sampleImagesPlugin(), svelte(), phoenixVitePlugin({ pattern: /\.(ex|heex)$/ })],
  server: {
    host: "localhost",
    port: 5173,
    strictPort: true,
    cors: { origin: "http://localhost:4000" },
  },
  build: {
    manifest: true,
    outDir: "../priv/static",
    emptyOutDir: false,
    rollupOptions: {
      input: ["main.ts"],
    },
  },
  test: {
    include: ["**/*.test.ts"],
  },
});
```

Notes for the implementer: the Vite **root** defaults to the directory the dev server is launched from; the watcher in Task 3.x runs Vite with `cd: assets`, so root = `fiddle/assets` and the entry `main.ts` resolves correctly. The manifest lands at `fiddle/priv/static/.vite/manifest.json`; hashed bundles at `fiddle/priv/static/assets/`. We deliberately drop the old hand-rolled `entryFileNames`/`assetFileNames`/`minify:false` so PhoenixVite's manifest-driven tags work.

- [ ] **Step 2: Install JS deps**

```bash
cd fiddle/assets && pnpm install
```
Expected: installs cleanly (a lockfile `fiddle/assets/pnpm-lock.yaml` is created).

- [ ] **Step 3: Verify the build produces a manifest**

```bash
cd fiddle/assets && pnpm run build
ls ../priv/static/.vite/manifest.json && ls ../priv/static/assets
```
Expected: manifest exists; hashed JS/CSS under `priv/static/assets`. **Assert the manifest key is exactly `main.ts`** (this is what the tags component's `names={["main.ts"]}` looks up — a wrong Vite root would key it `assets/main.ts` and the prod tag would 404):
```bash
node -e "console.log(Object.keys(require('../priv/static/.vite/manifest.json')))"
# must include "main.ts"
```
Confirm `priv/static/images/` still has the 11 files (emptyOutDir:false protected them):
```bash
ls ../priv/static/images | wc -l   # 11
```

- [ ] **Step 4: Commit**

```bash
git add fiddle/assets/vite.config.ts fiddle/assets/svelte.config.js fiddle/assets/pnpm-lock.yaml
git commit -m "feat(fiddle): vite config with svelte, sample-images plugin, phoenix_vite"
```

### Task 2.4: Wire the dev watcher, static_url, and the tags component

**Files:**
- Modify: `fiddle/config/dev.exs` (watcher + static_url + live_reload)
- Modify: `fiddle/lib/image_pipe_fiddle_web/components/layouts/root.html.heex` (tags component)
- Modify: `fiddle/lib/image_pipe_fiddle_web/endpoint.ex` (Plug.Static `only`)
- Modify: `fiddle/config/runtime.exs` (prod manifest)
- Modify: `fiddle/mix.exs` (assets aliases)

- [ ] **Step 1: Add the Vite dev watcher + static_url in `config/dev.exs`**

In the `config :image_pipe_fiddle, ImagePipeFiddleWeb.Endpoint, ...` dev block, add a `:vite` watcher (key must be `:vite` for `has_vite_watcher?`) and the dev `static_url` so generated asset URLs point at the Vite dev server:

```elixir
config :image_pipe_fiddle, ImagePipeFiddleWeb.Endpoint,
  # ...existing http:, debug_errors:, secret_key_base:, etc...
  static_url: [host: "localhost", port: 5173],
  watchers: [
    vite: [
      "pnpm",
      "exec",
      "vite",
      "dev",
      "--host",
      "localhost",
      "--port",
      "5173",
      "--strictPort",
      cd: Path.expand("../assets", __DIR__)
    ]
  ]
```

If the generated dev config has a `live_reload:` block listing `priv/static` patterns, remove the `priv/static` entries (Vite owns those assets) but keep the `.ex`/`.heex` template patterns.

- [ ] **Step 2: Add the PhoenixVite tags component to the root layout `<head>`**

In `fiddle/lib/image_pipe_fiddle_web/components/layouts/root.html.heex`, add inside `<head>` (after the `<title>`):

```heex
<PhoenixVite.Components.assets
  names={["main.ts"]}
  manifest={{:image_pipe_fiddle, "priv/static/.vite/manifest.json"}}
  dev_server={PhoenixVite.Components.has_vite_watcher?(ImagePipeFiddleWeb.Endpoint)}
  to_url={fn p -> static_url(@conn, p) end}
/>
```

The component is fully-qualified — no import needed. `static_url/2` (which resolves a path to an absolute URL via the endpoint's `static_url` config — so in dev it points at `localhost:5173`) is **not** imported in the generated layout by default. Add it explicitly to the html helpers in `fiddle/lib/image_pipe_fiddle_web.ex` so the layout can call it:

```elixir
defp html_helpers do
  quote do
    # ...existing imports/use...
    import Phoenix.Controller, only: [static_url: 2]
  end
end
```

`@conn` is always in scope in the root layout.

- [ ] **Step 3: Serve `/images` and `/assets` via `Plug.Static`**

In `fiddle/lib/image_pipe_fiddle_web/endpoint.ex`, set the `Plug.Static` `only` list to include `images` (and keep `assets`):

```elixir
plug Plug.Static,
  at: "/",
  from: :image_pipe_fiddle,
  gzip: false,
  only: ImagePipeFiddleWeb.static_paths()
```

and in `fiddle/lib/image_pipe_fiddle_web.ex` set (only what we actually ship — `assets` are the Vite bundles, `images` the sample images):

```elixir
def static_paths, do: ~w(assets images)
```

- [ ] **Step 4: Prod manifest in `config/runtime.exs`**

Inside the `if config_env() == :prod do` block of `fiddle/config/runtime.exs`, add to the endpoint config:

```elixir
config :image_pipe_fiddle, ImagePipeFiddleWeb.Endpoint,
  cache_static_manifest_latest: PhoenixVite.cache_static_manifest_latest(:image_pipe_fiddle)
```

If `config/prod.exs` sets `cache_static_manifest:`, remove that line (Vite owns the manifest).

- [ ] **Step 5: Assets aliases in `fiddle/mix.exs`**

Replace any generated `assets.*` aliases with pnpm-driven ones:

```elixir
defp aliases do
  [
    setup: ["deps.get", "assets.setup"],
    "assets.setup": ["cmd --cd assets pnpm install"],
    "assets.build": ["cmd --cd assets pnpm run build"],
    "assets.deploy": ["assets.build"]
  ]
end
```

- [ ] **Step 6: Verify the SPA renders end-to-end in dev**

```bash
cd fiddle && mise exec -- mix phx.server
```
In a browser (or via curl) hit `http://localhost:4000/`:
```bash
curl -s localhost:4000/ | grep -oE 'src="[^"]*(@vite/client|main.ts)"'
```
Expected: the emitted `src` hosts are **`http://localhost:5173/...`** (not same-origin) — i.e. `src="http://localhost:5173/@vite/client"` and `src="http://localhost:5173/main.ts"`. This confirms `static_url`→5173 and the tags component are wired correctly; grepping for mere presence is not enough. Loading `/` in a real browser should render the Fiddle UI with HMR. Ctrl-C when confirmed.

- [ ] **Step 7: Verify the prod tag path**

```bash
cd fiddle && mise exec -- mix assets.build
MIX_ENV=prod mise exec -- mix compile
```
Expected: builds; the manifest-based component will emit hashed `/assets/...` tags under prod (full prod boot is exercised later). 

- [ ] **Step 8: Commit**

```bash
git add fiddle/config fiddle/lib/image_pipe_fiddle_web fiddle/mix.exs
git commit -m "feat(fiddle): wire vite dev watcher, tags component, static paths, prod manifest"
```

---

## Phase 3 — Mount the imgproxy processing endpoint at /img

### Task 3.1: Build and stash the ImagePipe.Plug opts at boot

**Files:**
- Modify: `fiddle/lib/image_pipe_fiddle/application.ex`
- Modify: `fiddle/config/{config,dev}.exs` (imgproxy + cache config)
- Create: `fiddle/lib/image_pipe_fiddle_web/imgproxy.ex`

- [ ] **Step 1: Add base imgproxy config in `config/config.exs`**

```elixir
config :image_pipe_fiddle, :imgproxy,
  signature: [
    keys: ["736563726574"],
    salts: ["68656c6c6f"],
    trusted_signatures: ["_", "unsafe"]
  ],
  smart_crop_face_detection: true
```

- [ ] **Step 2: Cache disabled by default; toggle in dev**

In `config/dev.exs` add (commented example so it is discoverable; off by default):

```elixir
# Set to enable a bounded filesystem cache for the dev demo:
# config :image_pipe_fiddle, :cache,
#   {ImagePipe.Cache.FileSystem,
#    root: Path.expand("../_build/dev/image_pipe_fiddle/cache", __DIR__),
#    path_prefix: "processed",
#    max_body_bytes: 10_000_000,
#    max_size_bytes: 500_000_000,
#    node_id: "dev",
#    key_headers: [],
#    key_cookies: []}
```

- [ ] **Step 3: Build + stash the opts in `Application.start/2`**

In `fiddle/lib/image_pipe_fiddle/application.ex`, before starting the supervisor, compute the ImagePipe.Plug opts (mirroring the old `SimpleServer.image_pipe_opts/0`) and stash them in `:persistent_term`:

```elixir
@impl true
def start(_type, _args) do
  :persistent_term.put({__MODULE__, :imgproxy_opts}, build_imgproxy_opts())

  children = [
    ImagePipeFiddleWeb.Telemetry,
    {Phoenix.PubSub, name: ImagePipeFiddle.PubSub},
    ImagePipeFiddleWeb.Endpoint
  ]

  opts = [strategy: :one_for_one, name: ImagePipeFiddle.Supervisor]
  Supervisor.start_link(children, opts)
end

defp build_imgproxy_opts do
  imgproxy = Application.fetch_env!(:image_pipe_fiddle, :imgproxy)
  static_root = Application.app_dir(:image_pipe_fiddle, "priv/static")

  [
    parser: ImagePipe.Parser.Imgproxy,
    sources: [
      path: {ImagePipe.Source.File, root: static_root, root_id: "static", stable: :trusted}
    ],
    imgproxy: imgproxy,
    # Hard ML deps (Phase 5) mean the detector is always present; require it so a
    # broken model load surfaces as an error instead of a silent attention-crop
    # fallback. (Verify the exact option name/placement against
    # `ImagePipe.Plug`'s `validate_detector_capability` — lib/image_pipe/plug.ex.)
    detector_required: true
  ]
  |> maybe_put_cache(Application.get_env(:image_pipe_fiddle, :cache))
  |> ImagePipe.Plug.init()
end

defp maybe_put_cache(opts, nil), do: opts
defp maybe_put_cache(opts, cache), do: Keyword.put(opts, :cache, cache)
```

- [ ] **Step 4: Create the forwarding plug**

`fiddle/lib/image_pipe_fiddle_web/imgproxy.ex`:

```elixir
defmodule ImagePipeFiddleWeb.Imgproxy do
  @moduledoc "Forwards /img requests to ImagePipe.Plug with opts built at boot."
  @behaviour Plug

  @impl true
  def init(_opts), do: []

  @impl true
  def call(conn, _opts) do
    ImagePipe.Plug.call(conn, :persistent_term.get({ImagePipeFiddle.Application, :imgproxy_opts}))
  end
end
```

- [ ] **Step 5: Forward `/img` in the router**

In `fiddle/lib/image_pipe_fiddle_web/router.ex`, **above** the catch-all `get "/*path"`:

```elixir
forward "/img", ImagePipeFiddleWeb.Imgproxy
```

(Place it outside the `:browser` pipeline scope, or in its own scope, so the SPA pipeline does not run on image requests.)

- [ ] **Step 6: Verify processing works under /img**

```bash
cd fiddle && mise exec -- mix phx.server
# in another shell:
curl -s -o /tmp/out.jpg -w '%{http_code} %{content_type}\n' \
  'localhost:4000/img/_/rs:fill:200:200/plain/local:///images/dog.jpg'
mise exec -- elixir -e 'IO.inspect Image.open!("/tmp/out.jpg") |> then(&{Image.width(&1), Image.height(&1)})'
```
Expected: `200 image/...`; decoded dimensions reflect the resize (≈200×200). Ctrl-C the server.

- [ ] **Step 7: Commit**

```bash
git add fiddle/lib fiddle/config
git commit -m "feat(fiddle): mount imgproxy processing endpoint at /img"
```

---

## Phase 4 — SPA URL-state changes (root + /img)

### Task 4.1: Move deep-link state to root and prefix processing URLs with /img

**Files:**
- Modify: `fiddle/assets/demo-url-state.ts`
- Modify: `fiddle/assets/processing-path.ts`
- Modify: `fiddle/assets/processing-path.test.ts` (and any other `*.test.ts` asserting `/demo`)

- [ ] **Step 1: Write/adjust failing unit tests first (TDD)**

In `fiddle/assets/processing-path.test.ts`, update the `buildProcessingPath`/`processingPathFromSignedPath` expectations to the new `/img/...` shape, and in the URL-state round-trip tests drop the `/demo` prefix. Example assertions (adapt to the existing test names):

```ts
expect(processingPathFromSignedPath("_", "/plain/local:///images/dog.jpg")).toBe(
  "/img/_/plain/local:///images/dog.jpg",
);
expect(buildProcessingPath(defaultDemoState, "_")).toMatch(/^\/img\/_\//);
```

For `demo-url-state` round-trips, assert that `demoPathForState(state)` no longer starts with `/demo` and that `parseDemoPath(demoPathForState(state))` round-trips equal to `state`.

**Scope warning:** this is not a two-line tweak — `processing-path.test.ts` hardcodes `/demo` on roughly **88 lines** (parse inputs and `demoPathForState` expectations across the URL-state and object-gravity blocks), plus the `buildProcessingPath`/`processingPathFromSignedPath` expectations gain the `/img` prefix. Budget for a careful, complete find/replace, not a sample. The other vitest files need **no** path changes: `sample-images.test.ts` asserts the sample-image `path` field (`images/...`, unrelated to the URL prefix) and `theme.test.ts` has no path assertions — confirm, then leave them.

- [ ] **Step 2: Run the tests; confirm they fail**

```bash
cd fiddle/assets && pnpm run test
```
Expected: FAIL (old code still emits `/demo` and no `/img`).

- [ ] **Step 3: Prefix processing paths with `/img` in `processing-path.ts`**

Add a constant and prepend it in `processingPathFromSignedPath`:

```ts
const processingPrefix = "/img";

export function processingPathFromSignedPath(signature: string, signedPath: string): string {
  return `${processingPrefix}/${signature}${signedPath}`;
}
```

- [ ] **Step 3b: Route `App.svelte`'s signed-mode paths through the same helper, and fix the parameter-preview regex**

`App.svelte` builds the processing path **inline** in signed and invalid-signature modes, bypassing `processingPathFromSignedPath` — so without this fix the `/img` prefix is applied in *unsigned* mode only, and signed/invalid requests (preview `<img>` and copied URL) would 404. Read `App.svelte` around lines 270–290 and replace the inline constructions:

- `path = \`/${signature}${signedPath}\`` (≈ line 278) → `path = processingPathFromSignedPath(signature, signedPath)`
- `path = \`/invalid-signature${signedPath}\`` (≈ line 284) → `path = processingPathFromSignedPath("invalid-signature", signedPath)`

Ensure `processingPathFromSignedPath` is imported in `App.svelte` (it already imports from `./processing-path`).

Also fix the parameter-preview that strips the leading path segment(s). `previewParameters = path.replace(/^\/[^/]+\//, "")` (≈ line 117) strips one segment; with the `/img/<sig>/...` shape it must strip **two**:

```ts
const previewParameters = path.replace(/^\/[^/]+\/[^/]+\//, "");
```

(Verify against the actual code — the goal is that the displayed parameters start at the options, e.g. `rs:.../plain/...`, not `_/rs:...`.)

- [ ] **Step 4: Drop the `/demo` prefix in `demo-url-state.ts` and simplify the parser**

Set the prefix empty and remove the now-vestigial prefix branch/offset math (per the repo's clean-removal rule — do not leave `+ "/"` arithmetic on an empty string):

- Change `const demoPathPrefix = "/demo";` → `const demoPathPrefix = "";`
- `demoPathForState` becomes `return signedPathForState(currentState);`
- In `parseDemoPathParts`, replace the prefix guard and offset slicing:
  - delete the `if (path !== demoPathPrefix && !path.startsWith(\`${demoPathPrefix}/\`)) { ... }` guard,
  - change `const plainIndex = path.indexOf(plainSourceMarker, demoPathPrefix.length);` → `const plainIndex = path.indexOf(plainSourceMarker);`
  - if `plainIndex === -1`, return the default-state result (same as before),
  - change `path.slice(demoPathPrefix.length, plainIndex)` → `path.slice(0, plainIndex)`.
- Remove the `demoPathPrefix` constant entirely once unused.

(Read the full file first; the source segment parsing after `optionSegments` is unchanged.)

- [ ] **Step 5: Run unit tests; confirm pass**

```bash
cd fiddle/assets && pnpm run test
```
Expected: PASS. Also run `pnpm run check` and `pnpm run lint` and fix any type/lint fallout.

- [ ] **Step 6: Browser smoke test**

Boot `mix phx.server`, open `http://localhost:4000/`, toggle a resize, and confirm: the address bar shows a root path like `/rs:fill:640:360/plain/local:///images/dog.jpg`, the processed `<img>` requests `/img/_/...` (check the Network tab → 200), the raw thumbnail loads from `/images/dog.jpg`, and a hard reload of the deep link rehydrates the controls.

- [ ] **Step 7: Commit**

```bash
git add fiddle/assets
git commit -m "feat(fiddle): serve SPA state at root, prefix processing URLs with /img"
```

---

## Phase 5 — Runtime children: face warmup, logger, optional cache

### Task 5.1: Start the detector warmup, attach the default Logger, wire optional cache supervisor

**Files:**
- Modify: `fiddle/mix.exs` (add `image_vision`, `ortex`, `bandit` already via phoenix)
- Modify: `fiddle/lib/image_pipe_fiddle/application.ex`

- [ ] **Step 1: Add the ML deps as hard fiddle deps**

In `fiddle/mix.exs` `deps/0`:

```elixir
{:image_vision, "~> 0.4"},
{:ortex, "~> 0.1"},
```

Run `cd fiddle && mise exec -- mix deps.get`. Expected: fetches (ortex compiles a Rust NIF — first build is slow). If the Rust toolchain is missing, install it (`rustup`) — this is now the fiddle's build requirement.

- [ ] **Step 2: Configure the detector for real face detection**

In `fiddle/config/config.exs`, ensure ImageVision/Ortex are configured so `Image.FaceDetection` compiles (per `image_vision` docs — `config :image_vision, ...` as required by that lib). Verify by checking `ImageVision.ortex_configured?()` returns true at runtime in Step 5.

- [ ] **Step 3: Add the warmup + cache children and Logger attach to `application.ex`**

Extend `start/2`:

```elixir
def start(_type, _args) do
  :persistent_term.put({__MODULE__, :imgproxy_opts}, build_imgproxy_opts())
  ImagePipe.Telemetry.attach_default_logger(events: :all, level: :debug, debug: true)

  children =
    [
      ImagePipeFiddleWeb.Telemetry,
      {Phoenix.PubSub, name: ImagePipeFiddle.PubSub},
      ImagePipeFiddleWeb.Endpoint,
      {ImagePipe.Transform.Detector.Warmup, detector: :default, classes: ["face"]}
    ] ++ cache_children(Application.get_env(:image_pipe_fiddle, :cache))

  Supervisor.start_link(children, strategy: :one_for_one, name: ImagePipeFiddle.Supervisor)
end

defp cache_children(nil), do: []

defp cache_children({module, opts}) do
  case module.child_spec(opts) do
    :ignore -> []
    spec -> [spec]
  end
end
```

(The `Warmup` worker is `restart: :transient` and a no-op when the detector is unavailable; with `image_vision`/`ortex` as hard deps it always warms real detection.)

- [ ] **Step 4: Verify the dev server logs telemetry and warms detection**

```bash
cd fiddle && mise exec -- mix phx.server
```
Expected: on boot, the default Logger prints telemetry; the warmup worker loads the face model (first run downloads it). Issue a face-crop request and confirm it works:
```bash
curl -s -o /tmp/face.jpg -w '%{http_code}\n' \
  'localhost:4000/img/_/rs:fill:200:200/g:obj:face/plain/local:///images/woman.jpg'
```
Expected: `200`, and the log shows real detection telemetry. Because `detector_required: true` is set, a broken/missing model would now make this request **fail** rather than silently degrade to attention crop — so a `200` here genuinely confirms face detection ran. Also confirm the log shows a detection event (not a fallback warning). Ctrl-C.

- [ ] **Step 5: Verify the optional cache toggle**

Uncomment the `config :image_pipe_fiddle, :cache, ...` block in `config/dev.exs`, reboot, request the same URL twice, and confirm the second request is served from cache (cache telemetry / no source re-fetch in logs). Re-comment it afterward (off by default).

- [ ] **Step 6: Commit**

```bash
git add fiddle/mix.exs fiddle/mix.lock fiddle/config fiddle/lib
git commit -m "feat(fiddle): face-detector warmup, default Logger, optional cache"
```

---

## Phase 6 — Library cleanup

> Only now that the fiddle fully works do we remove the old demo machinery from the library.

### Task 6.1: Delete SimpleServer, the dev-server Mix task, and their tests

**Files:**
- Delete: `dev/simple_server.ex`, `lib/mix/tasks/image_pipe.server.ex`, `test/simple_server_test.exs`, `test/mix/tasks/image_pipe_server_test.exs`
- Modify: `mix.exs` (elixirc_paths)

- [ ] **Step 1: Delete the files**

```bash
cd /Users/hlindset/src/image_plug/.claude/worktrees/elegant-ardinghelli-5004cf
git rm dev/simple_server.ex lib/mix/tasks/image_pipe.server.ex test/simple_server_test.exs test/mix/tasks/image_pipe_server_test.exs
```

- [ ] **Step 2: Drop `dev` from `elixirc_paths`**

In `mix.exs`:
```elixir
defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(:dev), do: ["lib"]
defp elixirc_paths(_env), do: ["lib"]
```

- [ ] **Step 3: Confirm no dangling references**

```bash
grep -rn "SimpleServer\|Mix.Tasks.ImagePipe.Server\|image_pipe.server" lib test | grep -v "/deps/"
```
Expected: no matches (docs/specs/plans may still mention them historically — those are fine).

- [ ] **Step 4: Compile + boundary check**

```bash
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test test/image_pipe/architecture_boundary_test.exs
```
Expected: compiles clean; boundary test passes (both deleted modules were `top_level?` islands).

- [ ] **Step 5: Commit**

```bash
git commit -m "refactor: remove SimpleServer and dev-server Mix task (moved to fiddle)"
```

### Task 6.2: Trim library deps and aliases

**Files:** Modify `mix.exs`

- [ ] **Step 1: Remove `bandit`, the `demo.*` aliases; rescope ML deps**

In `mix.exs`:
- Remove the `{:bandit, "~> 1.0", only: [:test, :dev]}` dep line.
- Remove all `demo.*` aliases (keep `setup`/`test`).
- Replace the ML deps block so `image_vision`/`ortex` are pulled **only** into `:test` and only under `IMAGE_VISION=1`:

```elixir
ml_test_deps =
  if System.get_env("IMAGE_VISION") in ["1", "true"] do
    [
      {:image_vision, "~> 0.4", only: :test},
      {:ortex, "~> 0.1", only: :test}
    ]
  else
    []
  end

base ++ ml_test_deps
```

Update the explanatory comment above the block to describe the fiddle owning real detection (clean removal — no "moved from dev" narration in the file).

- [ ] **Step 2: Verify the default lane (no ML) still passes**

```bash
mise exec -- mix deps.get
mise exec -- mix compile --warnings-as-errors
mise exec -- mix test
```
Expected: compiles + full suite passes without `image_vision`/`ortex` present (the `@tag :image_vision` test is excluded by default).

- [ ] **Step 3: Verify the opt-in ML lane still resolves**

```bash
IMAGE_VISION=1 mise exec -- mix deps.get
IMAGE_VISION=1 mise exec -- mix test --only image_vision
```
Expected: the detector test runs (subject to the known local inference-env limitation; at minimum the deps resolve and compile). Then restore the default lockfile state: `mise exec -- mix deps.get`.

- [ ] **Step 4: Commit**

```bash
git add mix.exs mix.lock
git commit -m "refactor: drop bandit + demo aliases; scope ML deps to opt-in test lane"
```

### Task 6.3: Remove root JS tooling and fix .gitignore

**Files:** Delete root `package.json`, `pnpm-workspace.yaml`, `pnpm-lock.yaml`, `vite.config.ts`, `tsconfig.json`, `.oxfmtrc.json`; remove empty `demo/`, `dev/`; modify `.gitignore`.

- [ ] **Step 1: Delete the root JS tooling and now-empty dirs**

```bash
git rm package.json pnpm-workspace.yaml pnpm-lock.yaml vite.config.ts tsconfig.json .oxfmtrc.json
# demo/ and dev/ should already be empty from earlier git mv/rm; remove any leftovers:
[ -d demo ] && git rm -r demo 2>/dev/null; [ -d dev ] && rmdir dev 2>/dev/null || true
rm -rf node_modules priv/static/demo
```

- [ ] **Step 2: Update `.gitignore`**

Remove the demo lines (`/priv/static/demo`, root `/node_modules`, demo build artifacts) and add fiddle entries:

```gitignore
# Fiddle (nested app)
/fiddle/_build/
/fiddle/deps/
/fiddle/node_modules/
/fiddle/assets/node_modules/
/fiddle/priv/static/assets/
/fiddle/priv/static/.vite/
/fiddle/erl_crash.dump
```

Keep `fiddle/priv/static/images/` **tracked** (do not ignore it). Verify:
```bash
git check-ignore fiddle/priv/static/images/dog.jpg && echo IGNORED || echo TRACKED
```
Expected: `TRACKED`.

- [ ] **Step 3: Confirm library still builds**

```bash
mise exec -- mix compile --warnings-as-errors
```
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: remove root JS tooling; library reverts to pure Elixir"
```

---

## Phase 7 — Dev workflow + docs

### Task 7.1: mise tasks

**Files:** Modify `mise.toml`

- [ ] **Step 1: Update `mise.toml`**

```toml
[tools]
elixir = "1.20.0-otp-29"
node = "latest"

[tasks.setup]
description = "Install library and fiddle dependencies"
run = [
  "mix deps.get",
  "mix --cd fiddle deps.get",
  "pnpm --dir fiddle/assets install --frozen-lockfile",
]

[tasks.precommit]
description = "Elixir library checks: format, compile (warnings as errors), credo, test"
run = [
  "mix format --check-formatted",
  "mix compile --warnings-as-errors",
  "mix credo --strict",
  "mix test",
]

[tasks."precommit:demo"]
description = "Library checks plus the fiddle verify suite"
depends = ["precommit"]
run = [
  "mix --cd fiddle format --check-formatted",
  "mix --cd fiddle compile --warnings-as-errors",
  "mix --cd fiddle test",
  "pnpm --dir fiddle/assets run test",
  "pnpm --dir fiddle/assets run check",
  "pnpm --dir fiddle/assets run format:check",
  "pnpm --dir fiddle/assets run lint",
  "pnpm --dir fiddle/assets run build",
]

[tasks.server]
description = "Run the ImagePipe Fiddle dev server (Phoenix + Vite)"
dir = "fiddle"
run = "mix phx.server"
```

(`mix --cd DIR` runs mix in another project dir; if that flag is unavailable in this Elixir, use `sh -c 'cd fiddle && mix ...'` instead. Verify with `mise exec -- mix --cd fiddle help` during this step.)

- [ ] **Step 2: Verify the tasks run**

```bash
mise run setup
mise run precommit
mise run precommit:demo
```
Expected: all succeed. (`mise run server` is manual — confirm it boots, then Ctrl-C.)

- [ ] **Step 3: Commit**

```bash
git add mise.toml
git commit -m "chore: mise tasks drive library + fiddle; add server task"
```

### Task 7.2: Docs — README and AGENTS.md

**Files:** Modify `README.md`, `AGENTS.md`

- [ ] **Step 1: Rewrite the README development-server section**

Replace the `mix image_pipe.server` block (README ~lines 160–192, including `--port`/`--cache`/`--no-vite` and the Vite-on-5173 note) with:

```markdown
## Demo

The interactive demo (ImagePipe Fiddle) is a standalone Phoenix app in `fiddle/`.

```bash
mise run setup        # installs library + fiddle deps
mise run server       # boots Phoenix (:4000) + Vite (:5173)
```

Open http://localhost:4000. The imgproxy processing endpoint is mounted at `/img`.
```

Adjust surrounding prose that references the old server — including the SimpleServer description around README line 171 ("generated SimpleServer request…") and any mention of `mix demo.setup`. Grep `README.md` for `image_pipe.server`, `SimpleServer`, and `demo.` to be sure none survive. Keep the `docs/assets/demo-fiddle-desktop.png` screenshot reference.

- [ ] **Step 2: Update the three AGENTS.md spots**

- `AGENTS.md:7` (`precommit:demo` description): change "demo verify suite (`mix demo.verify`)" / "the `demo/` Svelte app" to the fiddle verify suite and "the `fiddle/` app".
- `AGENTS.md:25` ("keep the demo UI in sync … update the `demo/` Svelte app"): change `demo/` → `fiddle/assets/`.
- `AGENTS.md:66` (the `ImagePipe.SimpleServer` "dev/test only, outside prod compilation" bullet): delete it (the module no longer exists). Remove cleanly — no replacement note.

Verify CLAUDE.md still resolves (it is a symlink to AGENTS.md): `readlink CLAUDE.md` → `AGENTS.md`.

- [ ] **Step 3: Commit**

```bash
git add README.md AGENTS.md
git commit -m "docs: point demo workflow at the fiddle app; drop SimpleServer guidance"
```

---

## Phase 8 — Fiddle wire-level tests + final verification

### Task 8.1: Fiddle Elixir wire tests

**Files:**
- Create: `fiddle/test/image_pipe_fiddle_web/wire_test.exs`
- Create: `fiddle/test/support/conn_case.ex` (if not generated) — use the generated `ImagePipeFiddleWeb.ConnCase` if present.

- [ ] **Step 1: Write the wire tests**

Assert the fiddle's own contracts. Include the signed-`/img` case (the production config uses `trusted_signatures: ["_", "unsafe"]`, so the happy path never exercises HMAC — sign a path explicitly to prove the `/img` mount populates `script_name` and the signature verifies over the prefix-stripped path):

```elixir
defmodule ImagePipeFiddleWeb.WireTest do
  use ImagePipeFiddleWeb.ConnCase, async: true

  test "GET / serves the SPA shell", %{conn: conn} do
    conn = get(conn, "/")
    assert html_response(conn, 200) =~ ~s(id="fiddle-app")
  end

  test "deep-link path also serves the shell", %{conn: conn} do
    conn = get(conn, "/rs:fill:640:360/plain/local:///images/dog.jpg")
    assert html_response(conn, 200) =~ ~s(id="fiddle-app")
  end

  test "GET /images/:file serves a raw static image", %{conn: conn} do
    conn = get(conn, "/images/dog.jpg")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "image/"
  end

  test "GET /img processes an unsigned request", %{conn: conn} do
    conn = get(conn, "/img/_/rs:fill:200:200/plain/local:///images/dog.jpg")
    assert conn.status == 200
    {:ok, image} = Image.open(conn.resp_body, access: :random, fail_on: :error)
    assert Image.width(image) == 200
    assert Image.height(image) == 200
  end

  test "GET /img verifies a real HMAC-signed path under the mount", %{conn: conn} do
    # Sign over the prefix-stripped path "/<options>/plain/..." with the
    # configured key/salt; the /img mount must not be part of the signed bytes.
    signed_path = "/rs:fill:200:200/plain/local:///images/dog.jpg"
    signature = sign(signed_path, "736563726574", "68656c6c6f")
    conn = get(conn, "/img/#{signature}#{signed_path}")
    assert conn.status == 200
  end

  # HMAC-SHA256(salt <> signed_path), first 32 bytes, base64url, matching the
  # imgproxy signature scheme. (Implement with :crypto in the test.)
  defp sign(signed_path, key_hex, salt_hex) do
    key = Base.decode16!(key_hex, case: :lower)
    salt = Base.decode16!(salt_hex, case: :lower)
    :crypto.mac(:hmac, :sha256, key, salt <> signed_path)
    |> binary_part(0, 32)
    |> Base.url_encode64(padding: false)
  end
end
```

(The signing helper above matches the library's `signature_for/4` exactly — HMAC-SHA256 over `salt <> signed_path`, hex-decoded key/salt, truncated to 32 bytes, base64url unpadded — and signs over the prefix-stripped path, which is what the `/img` mount produces. `Image.open/2` with `access: :random, fail_on: :error` is the repo's established wire-test decode idiom for in-memory bodies.)

- [ ] **Step 2: Run the fiddle tests**

```bash
cd fiddle && mise exec -- mix test
```
Expected: all pass. The signed-path test is the key compatibility guard.

- [ ] **Step 3: Commit**

```bash
git add fiddle/test
git commit -m "test(fiddle): wire-level contracts incl. signed /img verification"
```

### Task 8.2: Full verification sweep

- [ ] **Step 1: Library gate**

```bash
cd /Users/hlindset/src/image_plug/.claude/worktrees/elegant-ardinghelli-5004cf
mise run precommit
```
Expected: format + compile(warnings-as-errors) + credo + test all green.

- [ ] **Step 2: Fiddle gate**

```bash
mise run precommit:demo
```
Expected: fiddle format/compile/test + vitest/check/format/lint/build all green.

- [ ] **Step 3: Manual end-to-end**

```bash
mise run server
```
In a browser at http://localhost:4000: tweak controls, confirm processed image updates via `/img/...`, raw thumbnail via `/images/...`, deep-link reload rehydrates, face-crop (`g:obj:face`) works. Ctrl-C.

- [ ] **Step 4: Confirm clean tree**

```bash
git status
```
Expected: clean (everything committed).

---

## Self-review notes (for the executing agent)

- **Spec coverage:** every spec section maps to a phase — Phoenix app (P1–2), routing/`/img`/static (P2–3), assets move + own images (P2), SPA URL changes (P4), runtime wiring (P3, P5), library cleanup incl. the extra server-task test file (P6), mise/docs incl. three AGENTS.md spots (P7), tests incl. signed-`/img` (P8).
- **Known integration risks to watch (verify, don't assume):** (a) whether `static_url`/the tags component emit dev script tags pointing at `localhost:5173` — Task 2.4 Step 6 is the gate (now checks the host, not mere presence); (b) the prod manifest key being exactly `main.ts` — Task 2.3 Step 3 asserts it; (c) the `geist` font relative path after the move — Task 2.2 Step 3b + the build/visual check; (d) `mix --cd` availability — Task 7.1 fallback; (e) the `detector_required:` option name/placement — Task 3.1 verify-note. Resolved by the plan review (no longer open): the wire-test decode API (`Image.open/2`, Task 8.1) and the imgproxy signing concatenation (`salt <> signed_path`, verified against `signature.ex`). If any open gate fails, fix before proceeding to the next phase.
- **Do not** make `image_vision`/`ortex` hard library deps; they are hard **fiddle** deps and opt-in `:test` library deps only.
