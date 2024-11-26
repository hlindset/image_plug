# PlugImage

`PlugImage` is an image optimization server, written as a `Plug`.

Uses the [image](https://hex.pm/packages/image) library under the hood.

Probably not quite ready for prime time yet.

Name not final!

## Transforms

Transforms are passed through the query parameter `transform`. Multiple transforms
can be supplied by separating them with a semicolon, and the transforms will be
executed from left to right.

E.g. `?transform=scale=500;crop=50px50p` will first scale the image to a width of
500 pixels, and then crop it from the center to 50% of the width and height.

More transforms are coming.

### Crop

Crops the image from the center of the current focus, or growing from the top left
corner set using the optionally supplied `<left>x<top>` coordinate. Can use pixel
values (e.g. `330`) or percent values (e.g. `25.5p`)

#### Parameters

Crop with the center of the crop at the current focus. By default
the center of the image unless supplied through the focus transform.

```
crop=<width>x<height>
```

Crop and set the top left corner of the crop area.

```
crop=<width>x<height>[@<left>x<top>]
```

### Scale

Scales the image using pixel values (e.g. `250`) or percent values (e.g. `45.2p`).

Set width and height.

```
scale=<width>x<height>
```

Set height. Automatic width based on aspect ratio.

```
scale=*x<height>
```

Set width. Automatic height based on aspect ratio.

```
scale=<width>x*
```

Set width. Automatic height based on aspect ratio.

```
scale=<width>
```

### Focus

By default `:center`, but can be set to a pixel coordinate using this transform. Is reset
back to `:center` after any operation that alters the image size (i.e. crop & scale).

```
focus=<left>x<top>
```

## Usage example

```elixir
defmodule PlugImage.SimpleServer do
  use Plug.Router

  plug Plug.Static,
    at: "/",
    from: {:the_app_name, "priv/static"},
    only: ~w(images)

  plug :match
  plug :dispatch

  forward "/process",
    to: PlugImage,
    init_opts: [root_url: "http://localhost:4000"]

  match _ do
    send_resp(conn, 404, "404 Not Found")
  end
end
```
