# Extract the demo into a standalone `ImagePipeFiddle` Phoenix app

**Date:** 2026-06-09
**Status:** Approved (design); implementation plan pending

## Problem

The interactive demo ("ImagePipe Fiddle") currently lives inside the library
project and drags its toolchain in with it:

- A Svelte 5 SPA under `demo/src/**`, built by a root-level Vite config
  (`vite.config.ts`, `tsconfig.json`, `package.json`, `pnpm-*`, `.oxfmtrc.json`).
- A hand-rolled dev server, `ImagePipe.SimpleServer` (`dev/simple_server.ex`), a
  `Plug.Router` that serves the SPA at `/demo` and forwards everything else to
  `ImagePipe.Plug` (imgproxy parser + `File` source + face-detect config), plus
  `test/simple_server_test.exs`.
- A dev-server Mix task, `lib/mix/tasks/image_pipe.server.ex`, that boots Bandit
  + SimpleServer, spawns Vite as an OS port, warms the face detector, and
  attaches the default Logger.
- `image_vision` + `ortex` carried in the **library's `:dev`** deps purely so
  that dev server can do real face detection.

This couples the library's build, dependencies, and namespace to a demo. We want
the demo to be its own sub-project so its dependencies never touch the library,
and we want it served at `/` instead of `/demo`.

## Constraints discovered

- **`priv/static/images/*` are library test fixtures, not demo-only assets.**
  ~40 references across the library suite (`plug_test`, `processor_test`,
  `transform/*`, `imgproxy_wire_conformance_test`, …) read `beach.jpg`,
  `woman.jpg`, `dog.jpg`, etc. They must stay with the library. The demo reuses
  them today via the Vite `sample-images` plugin and the `File` source root.
- **`bandit` is used only by the dev-server Mix task** — no library test starts
  Bandit. It moves out with the demo.
- **The default test lane already runs without `image_vision`** (today
  `ml_envs = [:dev]` when `IMAGE_VISION` is unset, so the dep is absent from
  `:test`). The `@tag :image_vision` detector test is opt-in via `IMAGE_VISION=1`.
  So moving the `:dev` inclusion out to the fiddle does not affect the default
  gate.
- **The SPA path-encodes its state at root and derives the `<img>` URL from the
  same path.** `demo-url-state.ts` reads `window.location.pathname` (expecting
  the `/demo` prefix) on load and writes it back with `history.replaceState`.
  `<img src>` for the processed preview is `buildProcessingPath` (root-level
  `/_/…/plain/…`); the raw source thumbnail is `<img src="/images/dog.jpg">`.

## Decisions (resolved with the user)

1. **Layout:** nested standalone Mix project, not an umbrella.
2. **Name:** `ImagePipeFiddle` / OTP app `:image_pipe_fiddle` (matches the
   `ImagePipe` library module and current "ImagePipe Fiddle" branding).
3. **Sample images:** the fiddle keeps its **own copy** under
   `fiddle/priv/static/images`; the library keeps `priv/static/images` for tests.
4. **Routing under `/`:** the imgproxy processing endpoint gets a **dedicated
   `/img` prefix**; the SPA owns `/` and all other paths; static source images
   are served at `/images` (segment-distinct from `/img`).
5. **Directory name:** `fiddle/`.
6. **ML deps:** `image_vision` + `ortex` become normal **fiddle** deps so a
   running/deployed demo does real face detection (accepting a Rust toolchain in
   the fiddle build).
7. **Mount element id:** `fiddle-app` (was `demo-app`).
8. **A `mise run server` task** boots the fiddle dev server.

Stack (user-chosen, not relitigated): **Phoenix 1.8.7** stripped down +
**PhoenixVite 0.4.3**.

## Design

### Repo shape

```
/                      # pure Elixir library (ImagePipe)
  lib/ priv/ test/ config/ mix.exs
  docs/ …
  mise.toml            # drives both projects
  fiddle/              # standalone Phoenix app (ImagePipeFiddle)
    mix.exs            # {:image_pipe, path: ".."}, phoenix, phoenix_vite,
                       #   bandit, image_vision, ortex, oxc/vite via pnpm
    config/            # config.exs dev.exs prod.exs runtime.exs test.exs
    lib/image_pipe_fiddle/         # Application, runtime children
    lib/image_pipe_fiddle_web/     # Endpoint, Router, PageController, layouts
    assets/            # the Svelte SPA (moved from demo/src)
      App.svelte, *.svelte, processing-path.ts, demo-url-state.ts,
      theme.ts, styles.css, main.ts, *.test.ts
    priv/static/images/            # own copy of demo sample images
    vite.config.ts tsconfig.json package.json .oxfmtrc.json
    test/                          # fiddle wire-level + vitest specs
```

The library at the repo root reverts to pure Elixir: no JS tooling, no `demo/`,
no `dev/`.

### The Phoenix app

- Generated from Phoenix 1.8.7 with the default batteries stripped:
  `--no-ecto --no-mailer --no-gettext --no-dashboard --no-tailwind --no-live
  --no-assets`. HTML/controllers are kept (we render a root shell page);
  LiveView and the default esbuild/tailwind asset pipeline are not — PhoenixVite
  owns assets.
- **PhoenixVite 0.4.3** integrates Vite: in dev it runs Vite as a Phoenix
  watcher so `mix phx.server` boots both, with HMR; `mix assets.deploy` runs
  `vite build` into the fiddle's `priv/static` for prod. Root layout uses
  PhoenixVite's tag helpers to emit the correct dev/prod script + style tags.
- **Bandit** is the endpoint adapter.
- `PageController` + root layout render the SPA shell:
  `<div id="fiddle-app"></div>` plus the PhoenixVite-emitted `main.ts` tag. This
  replaces `demo/index.html` and `demo/dev.html` (deleted). `main.ts`'s
  `getElementById("demo-app")` becomes `"fiddle-app"`.

### Routing (three root namespaces)

```elixir
# ImagePipeFiddleWeb.Router (or endpoint)
forward "/img", ImagePipe.Plug, image_pipe_opts()   # imgproxy processing
# Plug.Static at "/" with "images" in :only           # raw source thumbnails
# catch-all GET -> PageController :index               # SPA shell (deep links)
```

- `/img/_/rs:…/plain/local:///images/dog.jpg` → `ImagePipe.Plug`. The `/img`
  prefix lands in `script_name`; the imgproxy parser reads `path_info`, so the
  prefix is transparent. The SPA's `buildProcessingPath` prepends `/img`.
- `/images/dog.jpg` → `Plug.Static` from `priv/static/images`. `/img` and
  `/images` are different first segments, so no collision.
- Any other path (`/`, `/rs:fill:640:360/plain/local:///images/dog.jpg`, …) →
  `PageController` renders the shell; the SPA rehydrates from
  `window.location.pathname`.
- The SimpleServer favicon-404 and missing-static-image-404 special cases are
  **dropped** — they only existed because ImagePipe sat at root; now unreachable.

### SPA changes

- `demo-url-state.ts`: `demoPathPrefix` `/demo` → `""`. `demoPathForState` and
  `parseDemoPath` operate on root paths. The address bar mirrors the transform
  (`/rs:fill:640:360/plain/local:///images/dog.jpg`).
- `processing-path.ts`: `buildProcessingPath` / `processingPathFromSignedPath`
  prepend the **`/img`** processing prefix, so `<img src>` is
  `/img/_/rs:…/plain/local:///images/dog.jpg`.
- `vite.config.ts`: moves under `fiddle/`, `base`/`outDir` adjusted to
  PhoenixVite conventions; the `sample-images` virtual plugin + oxc transform are
  kept, reading `fiddle/priv/static/images`.

### Runtime wiring (moved out of SimpleServer + the Mix task)

Folded into `ImagePipeFiddle.Application`, the endpoint/router, and fiddle config:

- ImagePipe.Plug opts: `parser: ImagePipe.Parser.Imgproxy`;
  `sources: [path: {ImagePipe.Source.File, root: <fiddle priv/static>,
  root_id: "static", stable: :trusted}]`; imgproxy signature keys/salts +
  `trusted_signatures: ["_", "unsafe"]`; `smart_crop_face_detection: true`.
- Supervisor children: the **face-detection warmup** worker
  (`ImagePipe.Transform.Detector.Warmup`, `detector: :default, classes:
  ["face"]`) and an **optional filesystem cache** supervisor, toggled by dev
  config/env (replacing the `--cache` flag). Cache config mirrors the Mix task's
  bounded `ImagePipe.Cache.FileSystem` defaults.
- `ImagePipe.Telemetry.attach_default_logger(events: :all, level: :debug,
  debug: true)` attached on app start (replaces the Mix task's logger attach).
- If the library doesn't expose a clean public entry for the warmup worker, add
  a narrow public helper rather than reaching into a private module (verify
  during implementation).

The `--port`, `--cache`, `--no-vite` flags are retired in favor of the standard
`mix phx.server` workflow + config toggles.

### Library cleanup

- Delete `dev/simple_server.ex`, `test/simple_server_test.exs`,
  `lib/mix/tasks/image_pipe.server.ex`.
- `mix.exs`:
  - `elixirc_paths`: drop `"dev"` (now empty) from `:dev`/`:test`.
  - Remove all `demo.*` aliases.
  - Remove `bandit` (moves to fiddle).
  - Scope `image_vision` + `ortex` to `only: :test`, **included only when
    `IMAGE_VISION` is set** (default lane unchanged; `@tag :image_vision` test
    still works via `IMAGE_VISION=1`).
  - Keep `docs/assets/demo-fiddle-desktop.png` in `package` files (doc asset).
- Remove root `package.json`, `pnpm-workspace.yaml`, `pnpm-lock.yaml`,
  `vite.config.ts`, `tsconfig.json`, `.oxfmtrc.json`.
- `.gitignore`: drop `priv/static/demo` and demo `node_modules`; add fiddle
  equivalents (`fiddle/node_modules`, `fiddle/priv/static/assets`, `fiddle/_build`,
  `fiddle/deps`).
- Verify `test/image_pipe/architecture_boundary_test.exs` has no dangling
  references to `SimpleServer` or the server Mix task.

### Dev workflow (`mise.toml`)

- `setup`: library `mix deps.get` + `cd fiddle && mix deps.get && pnpm install
  --frozen-lockfile`.
- `precommit`: unchanged — the **library** gate (`mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test`).
- `precommit:demo`: library gate + a **fiddle verify** — fiddle
  `mix format --check-formatted` / `mix compile --warnings-as-errors` /
  `mix test`, plus pnpm `demo:test` (vitest) / `demo:check` / `demo:lint` /
  `demo:format:check` / `demo:build`.
- **New `server` task:** `cd fiddle && mix phx.server` (via mise task `dir`).

### Docs

- README: rewrite the development-server section from `mix image_pipe.server` to
  `cd fiddle && mix setup && mix phx.server`.
- `AGENTS.md`/CLAUDE.md: update guideline lines that name `ImagePipe.SimpleServer`
  (it's deleted) and that point the "keep the demo UI in sync" rules at `demo/`
  (now `fiddle/`).
- **No imgproxy conformance-doc change.** This is a pure relocation: no surface
  (option/config), stage/order (pipeline), or behavioral/pixel axis moves, so
  `docs/imgproxy_support_matrix.md` is untouched. The compatibility reviewer in
  the plan-review cycle confirms this.

### Tests

- Library: delete `test/simple_server_test.exs`. Everything else is unchanged.
- Fiddle: a small wire-level suite asserting the fiddle's own contracts — `/`
  serves the shell, `/img/…` processes (assert decoded output dimensions),
  `/images/…` serves static, and representative signature/safety behavior — plus
  the moved vitest specs (`processing-path.test.ts`, `sample-images.test.ts`,
  `theme.test.ts`). Keep the fiddle suite representative, not a re-test of the
  library's wire conformance, which stays in the library.

## Out of scope

- No change to imgproxy parsing/encoding/transform behavior.
- No prod deployment artifacts (Dockerfile/Fly config) unless requested later.
- No umbrella conversion.

## Implementation note (process)

Per the project's review-cycle rule, the implementation plan derived from this
spec gets a parallel subagent review with disjoint focus areas before coding,
including at least one reviewer checking observable imgproxy compatibility
(routing/parse/output unchanged vs. upstream). The reviewed plan is committed
before implementation begins.
