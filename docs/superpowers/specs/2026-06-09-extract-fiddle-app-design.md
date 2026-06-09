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
6. **ML deps:** `image_vision` + `ortex` are **hard, required, un-gated**
   dependencies of the **fiddle** (all envs), so a running/deployed demo always
   does real face detection — the Rust toolchain is now the fiddle's build
   requirement, not the library's. The **library stays product-neutral**: it
   keeps treating these as optional/runtime-guarded and pulls them only into its
   own `:test` lane under `IMAGE_VISION=1` (for its detector test). Don't make
   them hard library deps.
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
  replaces `demo/index.html` and `demo/dev.html` (deleted). The `demo-app` →
  `fiddle-app` rename touches **two** carried-forward files (the deleted HTML
  aside): `main.ts`'s `getElementById("demo-app")` and the `#demo-app` CSS
  selector in `styles.css:126`.

### Routing (three root namespaces)

```elixir
# ImagePipeFiddleWeb.Router (or endpoint)
forward "/img", ImagePipe.Plug, image_pipe_opts()   # imgproxy processing
# Plug.Static at "/" with "images" in :only           # raw source thumbnails
# catch-all GET -> PageController :index               # SPA shell (deep links)
```

- `/img/_/rs:…/plain/local:///images/dog.jpg` → `ImagePipe.Plug`. The prefix is
  transparent, but by an **active strip**, not by reading `path_info`: the
  parser reconstructs the unmounted path from `conn.request_path` minus
  `conn.script_name` (`lib/image_pipe/parser/imgproxy/path.ex:179-195`,
  `parser_request_path/1`). **Implication for the mount:** it must be a
  `forward "/img"` (Plug/Phoenix router), which populates `script_name` with
  `["img"]` and leaves the prefix in `request_path`. A mechanism that rewrites
  `request_path` to drop the prefix without setting `script_name` would not
  strip correctly. The signature is computed over the already-stripped path
  (`raw_path_parts/1`, `path.ex:200-208`), so the `/img` prefix is excluded from
  signing/verification — matching imgproxy. This is already unit-tested with a
  `script_name: ["img"]` case in `test/parser/imgproxy/path_test.exs:16-23`. The
  SPA's `buildProcessingPath` prepends `/img`.
- `/images/dog.jpg` → `Plug.Static` from `priv/static/images`. `/img` and
  `/images` are different first segments, so no collision.
- Any other path (`/`, `/rs:fill:640:360/plain/local:///images/dog.jpg`, …) →
  `PageController` renders the shell; the SPA rehydrates from
  `window.location.pathname`.
- The SimpleServer favicon-404 and missing-static-image-404 special cases are
  **dropped** — they only existed because ImagePipe sat at root; now unreachable.

### SPA changes

- `demo-url-state.ts`: `demoPathPrefix` `/demo` → `""`. `demoPathForState` and
  `parseDemoPath` operate on root paths; the address bar mirrors the transform
  (`/rs:fill:640:360/plain/local:///images/dog.jpg`). With an empty prefix the
  `path === demoPathPrefix` branch and the `+ "/"` slicing math become vestigial
  — **simplify them out** rather than leaving dead prefix arithmetic (per the
  repo's clean-removal rule), not just set the constant to `""`. Functionally the
  empty-prefix parse already yields correct results (root `/` and `/images/…`
  fall through `plainIndex === -1` to default state).
- `processing-path.ts`: `buildProcessingPath` / `processingPathFromSignedPath`
  prepend the **`/img`** processing prefix, so `<img src>` is
  `/img/_/rs:…/plain/local:///images/dog.jpg`.
- `vite.config.ts`: moves under `fiddle/`. Concretely: `root: "demo"` → the
  fiddle assets dir (`assets`), `base: "/demo/"` → PhoenixVite's static prefix
  (e.g. `/assets/`) matching the endpoint, `outDir: "../priv/static/demo"` →
  `priv/static/assets`, enable `manifest: true`, and **drop** the hand-rolled
  `rollupOptions.output` (`entryFileNames`/`assetFileNames`) and `minify: false`
  — PhoenixVite's tag helpers consume the manifest's hashed filenames, so fixed
  names fight it. The `sample-images` virtual plugin + oxc transform are kept;
  with the config at `fiddle/`, the plugin's default
  `resolve(currentDirectory, "priv/static/images")` and its watcher path resolve
  to `fiddle/priv/static/images` automatically (verify the `root` change keeps
  the watcher path correct).

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
- The warmup worker is **already a public, documented entry**
  (`ImagePipe.Transform.Detector.Warmup`, exported from the Transform boundary at
  `lib/image_pipe/transform.ex:20`, with a `@moduledoc` covering host
  supervision-tree wiring and the `detector:`/`classes:` opts). The fiddle starts
  it directly; no new library helper is needed. Because `image_vision`/`ortex`
  are hard fiddle deps (decision 6), the worker's "detector unavailable" no-op
  branch won't trigger here — detection is always real.

The `--port`, `--cache`, `--no-vite` flags are retired in favor of the standard
`mix phx.server` workflow + config toggles.

### Library cleanup

- Delete `dev/simple_server.ex`, `test/simple_server_test.exs`,
  `lib/mix/tasks/image_pipe.server.ex`, **and
  `test/mix/tasks/image_pipe_server_test.exs`** (exercises the task's
  `parse_args/1` + `vite_ready_buffer/2`; leaving it breaks compile/`mix test`).
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
  `cd fiddle && mix setup && mix phx.server`. This is ~7 spots (README lines
  ~160-192: `--port`/`--cache`/`--no-vite`, `mix demo.setup`, the Vite-on-5173
  note), not a single line.
- `AGENTS.md`/CLAUDE.md: three distinct spots, not one — `AGENTS.md:7`
  (`precommit:demo` runs `mix demo.verify` → fiddle verify), `AGENTS.md:25` ("keep
  the demo UI in sync … update the `demo/` Svelte app" → `fiddle/`), and
  `AGENTS.md:66` (the `ImagePipe.SimpleServer` "dev/test only, outside prod
  compilation" rule → delete, since the module is gone).
- `mise.toml`: the concrete line to change is `mise.toml:24` (`mix demo.verify`),
  superseded by the `precommit:demo` redefinition below.
- **No imgproxy conformance-doc change.** This is a pure relocation: no surface
  (option/config), stage/order (pipeline), or behavioral/pixel axis moves, so
  `docs/imgproxy_support_matrix.md` is untouched.

### Tests

- Library: delete `test/simple_server_test.exs`. Everything else is unchanged.
- Fiddle: a small wire-level suite asserting the fiddle's own contracts — `/`
  serves the shell, `/img/…` processes (assert decoded output dimensions),
  `/images/…` serves static, and representative signature/safety behavior. Since
  the production config uses `trusted_signatures: ["_", "unsafe"]`, the happy path
  never exercises HMAC; include **one test that mounts under `/img` and verifies a
  real HMAC-signed path** (signed over the prefix-stripped path) — the single
  place a mount prefix could silently break compatibility. Keep the suite
  representative, not a re-test of the library's wire conformance.
- Vitest specs (`processing-path.test.ts`, `sample-images.test.ts`,
  `theme.test.ts`) move with the assets, but `processing-path.test.ts` is a
  **rewrite, not a verbatim move**: ~40 assertions hardcode the old `/demo`
  prefix, and `buildProcessingPath` assertions now expect `/img/_/…`. Update the
  fixtures as part of the move.

## Out of scope

- No change to imgproxy parsing/encoding/transform behavior.
- No prod deployment artifacts (Dockerfile/Fly config) unless requested later.
- No umbrella conversion.

## Implementation note (process)

Per the project's review-cycle rule, the implementation plan derived from this
spec gets a parallel subagent review with disjoint focus areas before coding.
This is a tooling/relocation change that doesn't touch any compatibility
implementation, so a dedicated imgproxy-compatibility reviewer is **optional**
under the softened rule (`AGENTS.md`) — the design-stage review already
confirmed parse/sign/output are unchanged under the `/img` mount. Pick lenses
that fit (Elixir/Phoenix wiring, frontend/build, request-safety). The reviewed
plan is committed before implementation begins.
