# ImagePlug

ImagePlug is a Plug-based image optimization server. It parses path-oriented
image requests, fetches an origin image, executes a product-neutral
`ImagePlug.Plan`, negotiates output format, and sends the encoded image
response.

The current public compatibility target is an Imgproxy-style path API through
`ImagePlug.Parser.Imgproxy`. Internally, Imgproxy syntax is translated into
ImagePlug's own plan, output, transform, cache, and response data structures.

## Project status

ImagePlug is a greenfield, unreleased library. The codebase includes working
Imgproxy-style request parsing, request safety checks, transform execution,
output negotiation, filesystem response caching, telemetry spans, and a local
demo server.

The package metadata exists for release evaluation, but no Hex package exists
yet. Treat the `0.1.0` API as subject to change until the first release.

## Installation

For local evaluation, depend on a checkout:

```elixir
def deps do
  [
    {:image_plug, path: "../image_plug"}
  ]
end
```

After the Hex package exists, depend on the package version:

```elixir
def deps do
  [
    {:image_plug, "~> 0.1.0"}
  ]
end
```

## Minimal mount

Mount ImagePlug from a Plug router or Phoenix endpoint with a configured origin
root and parser:

```elixir
forward "/images",
  to: ImagePlug,
  init_opts: [
    root_url: "https://origin.example",
    parser: ImagePlug.Parser.Imgproxy
  ]
```

For a local Plug server that serves files from `priv/static/images`, mount
`Plug.Static` before ImagePlug so origin requests resolve against the same
server:

```elixir
defmodule MyApp.ImageRouter do
  use Plug.Router

  plug Plug.Static,
    at: "/",
    from: {:my_app, "priv/static"},
    only: ~w(images)

  plug :match
  plug :dispatch

  match "/images/*path" do
    send_resp(conn, 404, "404 Not Found")
  end

  forward "/",
    to: ImagePlug,
    init_opts: [
      root_url: "http://localhost:4000",
      parser: ImagePlug.Parser.Imgproxy
    ]
end
```

With that router running at `http://localhost:4000`, this unsigned development
URL requests a 300-pixel-wide image from `/images/beach.jpg`:

```text
http://localhost:4000/_/w:300/plain/images/beach.jpg
```

`_` and `unsafe` work only without Imgproxy signing. Configured signing requires
a valid HMAC signature or an exact configured trusted signature.

## Current support boundaries

ImagePlug currently supports the Imgproxy-style path parser, selected resize,
crop, orientation, canvas, padding, background, output, cachebuster, expiry,
filename, attachment, and preset options documented in the support matrix.
Unsupported parser and planner requests fail before cache lookup or origin
fetch.

ImagePlug currently lacks other provider dialects, arbitrary absolute source URL
parsing, encoded source URLs, object detection, watermarking, metadata
stripping, video processing, and raw source passthrough. Missing Imgproxy
options fail or remain absent as documented. ImagePlug doesn't ignore them.

URL option order doesn't define transform execution order. The Imgproxy parser
normalizes aliases and conflict resolution, then the planner emits operations in
ImagePlug's fixed plan order.

## Documentation

- [Imgproxy Path API](docs/imgproxy_path_api.md) documents URL shape, option
  parsing, conflict resolution, signing, presets, output selection, and
  fixed operation ordering.
- [Imgproxy Support Matrix](docs/imgproxy_support_matrix.md) lists supported,
  partial, rejected, missing, and out-of-scope Imgproxy features.
- [Cache](docs/cache.md) documents filesystem response caching, cache keys,
  stored headers, failure modes, and cache safety boundaries.
- [Operational Notes](docs/operational_notes.md) documents request safety,
  origin fetching, decode planning, multi-pipeline behavior, and automatic
  output negotiation.
- [Telemetry](docs/telemetry.md) documents emitted span events, measurements,
  metadata, and handler examples.
- [Transform Operations](docs/transform_operations.md) documents the boundary
  between parser request syntax, semantic plan operations, and executable
  transform operations.

## Local demo server

The repository includes a development server for local testing:

```sh
mise exec -- mix image_plug.server
mise exec -- mix image_plug.server --port 4001
mise exec -- mix image_plug.server --cache
```

The development server runs without cache by default. Pass `--cache` to enable
the filesystem cache under `_build/dev/image_plug/cache`, or `--no-cache` to
spell out cache-off mode.

The development server also serves a local demo fiddle at `/demo`. The fiddle is
a small Svelte/Vite UI for changing common path options and previewing the
generated SimpleServer request. Install the demo dependencies once before using
the default server command:

```sh
mise exec -- pnpm install
```

Starting `mix image_plug.server` also starts the Vite development server on
`http://localhost:5173`, while the demo itself remains available through the
development server:

```sh
mise exec -- mix image_plug.server
open http://localhost:4000/demo
```

![Demo fiddle desktop screenshot](docs/assets/demo-fiddle-desktop.png)

Pass `--no-vite` to run only the image server without the demo asset server:

```sh
mise exec -- mix image_plug.server --no-vite
```
