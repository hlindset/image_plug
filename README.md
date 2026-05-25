# ImagePipe

ImagePipe is a Plug-based image optimization server. It parses path-oriented
image requests, resolves a configured image source, executes a product-neutral
`ImagePipe.Plan`, negotiates output format, and sends the encoded image
response.

The current public compatibility target is an Imgproxy-style path API through
`ImagePipe.Parser.Imgproxy`. Internally, ImagePipe translates Imgproxy syntax
into its own plan, output, transform, cache, and response data structures.

## Project status

ImagePipe is a greenfield, unreleased library. The codebase includes working
Imgproxy-style request parsing, request safety checks, transform execution,
source adapters, output negotiation, filesystem response caching, telemetry
spans, and a local demo server.

The package metadata exists for release evaluation, but no Hex package exists
yet. Treat the `0.1.0` API as subject to change until the first release.

## Installation

For local evaluation, depend on a checkout:

```elixir
def deps do
  [
    {:image_pipe, path: "../image_pipe"}
  ]
end
```

After the Hex package exists, depend on the package version:

```elixir
def deps do
  [
    {:image_pipe, "~> 0.1.0"}
  ]
end
```

## Minimal mount

Mount ImagePipe from a Plug router or Phoenix endpoint with a configured source
adapter and parser:

```elixir
forward "/images",
  to: ImagePipe,
  init_opts: [
    parser: ImagePipe.Parser.Imgproxy,
    sources: [
      path: {ImagePipe.Source.File, root: "/srv/images", root_id: "primary"}
    ]
  ]
```

For a local Plug server that reads files from `priv/static/images`, point the
path source adapter at `priv/static`:

```elixir
defmodule MyApp.ImageRouter do
  use Plug.Router

  plug :match
  plug :dispatch

  forward "/",
    to: ImagePipe,
    init_opts: [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [
        path: {ImagePipe.Source.File, root: "priv/static", root_id: "static"}
      ]
    ]
end
```

With that router running at `http://localhost:4000`, this unsigned development
URL requests a 300-pixel-wide image from `/images/beach.jpg`:

```text
http://localhost:4000/_/w:300/plain/images/beach.jpg
```

To accept both HTTP and HTTPS source URLs, configure the shared `:url` source
adapter:

```elixir
sources: [
  url: {ImagePipe.Source.HTTP, allowed_hosts: ["assets.example.com"]}
]
```

Use `:http` or `:https` instead to enable only one scheme, or when the schemes
need different adapter options.

`_` and `unsafe` work only without Imgproxy signing. Configured signing requires
a valid HMAC signature or an exact configured trusted signature.

## Current support boundaries

ImagePipe currently supports the Imgproxy-style path parser, selected resize,
crop, orientation, canvas, padding, background, output, cachebuster, expiry,
filename, attachment, and preset options documented in the support matrix.
Unsupported parser and planner requests fail before cache lookup or source
fetch.

The first slice supports local path sources, HTTP and HTTPS URL sources, and
S3-compatible object sources. ImagePipe currently lacks other provider dialects,
object detection, watermarking, metadata stripping, video processing, and raw
source passthrough. Missing Imgproxy options fail or remain absent as
documented. ImagePipe doesn't ignore them.

URL option order doesn't define transform execution order. The Imgproxy parser
normalizes aliases and conflict resolution, then the planner emits operations in
ImagePipe's fixed plan order.

## Documentation

- [Imgproxy path API](docs/imgproxy_path_api.md) documents URL shape, option
  parsing, conflict resolution, signing, presets, output selection, and
  fixed operation ordering.
- [Imgproxy support matrix](docs/imgproxy_support_matrix.md) lists supported,
  partial, rejected, missing, and out-of-scope Imgproxy features.
- [Cache](docs/cache.md) documents filesystem response caching, cache keys,
  stored headers, failure modes, and cache safety boundaries.
- [Operational notes](docs/operational_notes.md) documents request safety,
  source fetching, decode planning, multi-pipeline behavior, and automatic
  output negotiation.
- [Telemetry](docs/telemetry.md) documents emitted span events, measurements,
  metadata, and handler examples.
- [Transform operations](docs/transform_operations.md) documents the boundary
  between parser request syntax, semantic plan operations, and executable
  transform operations.

## Local demo server

The repository includes a development server for local testing:

```sh
mise exec -- mix image_pipe.server
mise exec -- mix image_pipe.server --port 4001
mise exec -- mix image_pipe.server --cache
```

The development server runs without cache by default. Pass `--cache` to enable
the filesystem cache under `_build/dev/image_pipe/cache`, or `--no-cache` to
spell out cache-off mode.

The development server also serves a local demo fiddle at `/demo`. The fiddle is
a small Svelte/Vite UI for changing common path options and previewing the
generated SimpleServer request. Install the demo dependencies once before using
the server or `demo.verify` aliases:

```sh
mise exec -- mix demo.setup
```

Starting `mix image_pipe.server` also starts the Vite development server on
`http://localhost:5173`, while the demo itself remains available through the
development server:

```sh
mise exec -- mix image_pipe.server
open http://localhost:4000/demo
```

![Demo fiddle desktop screenshot](docs/assets/demo-fiddle-desktop.png)

Pass `--no-vite` to run only the image server without the demo asset server:

```sh
mise exec -- mix image_pipe.server --no-vite
```
