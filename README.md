# ImagePlug

`ImagePlug` is an image optimization server, written as a `Plug`.

Uses the [image](https://hex.pm/packages/image) library under the hood.

Probably not quite ready for prime time yet.

Name not final!

## Native Path API

ImagePlug's native API uses path-oriented URLs:

```text
/<signature>[/<option>...]/plain/<origin_path>
```

For local development, the signature segment can be `_` or `unsafe`:

```text
/_/plain/images/cat-300.jpg
/_/w:300/plain/images/cat-300.jpg
/_/fit:cover/w:300/h:300/focus:center/format:auto/plain/images/cat-300.jpg
/_/fit:contain/w:800/format:webp/plain/images/cat-300.jpg
```

Options are declarative. Their order in the URL does not define processing order:

```text
/_/fit:cover/w:300/h:300/plain/images/cat-300.jpg
/_/h:300/w:300/fit:cover/plain/images/cat-300.jpg
```

Both URLs describe the same requested output. ImagePlug owns the fixed processing pipeline so it can optimize origin loading, resize, crop, and output encoding over time.

### Options

```text
w:<positive integer>
h:<positive integer>
fit:cover | fit:contain | fit:fill | fit:inside
focus:center | focus:top | focus:bottom | focus:left | focus:right | focus:<x>:<y>
format:auto | format:webp | format:avif | format:jpeg | format:png
```

`w` and `h` are pixel dimensions. `fit:cover`, `fit:fill`, and `fit:inside` require both `w` and `h`. `fit:contain` requires at least one of `w` or `h`.

`focus:<x>:<y>` accepts pixel values such as `focus:120:80` and percent values from `0p` to `100p`, such as `focus:50p:25p`.

`focus` only affects requests that plan a geometry transform. A focus option without `w`, `h`, or `fit` is accepted but has no effect.

The first `plain` segment terminates option parsing. Later path segments are treated as the origin path, even if they look like options.

`format:auto` uses the request `Accept` header and sets `Vary: Accept` on image responses. Explicit formats bypass content negotiation.

## Usage example

```elixir
defmodule ImagePlug.SimpleServer do
  use Plug.Router

  plug Plug.Static,
    at: "/",
    from: {:the_app_name, "priv/static"},
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
      param_parser: ImagePlug.ParamParser.Native
    ]
end
```

## Operational Notes

`ImagePlug` parses native path options before fetching the origin image. Invalid processing requests return `400` without origin traffic.

Origin fetches use non-bang Req calls with bounded redirects, receive timeout, image content-type validation, and a maximum response body size. Configure these with `:origin_max_redirects`, `:origin_receive_timeout`, `:max_body_bytes`, and `:max_input_pixels`.

Automatic output format selection uses the request `Accept` header and sets `Vary: Accept` on image responses. Explicit formats bypass content negotiation.
