defmodule ImagePipeDemoWeb.MainLayout do
  @moduledoc """
  Root Hologram layout for the demo.

  Wraps every page. The `<head>` must contain the `Hologram.UI.Runtime`
  component (it injects Hologram's runtime + page JS bundles), and the body
  must contain a `<slot />` where the page content is rendered.

  Stylesheets are linked here as a plain `<link>` to the static CSS file.
  This is intentionally hand-written `~HOLO` markup -- do NOT copy Phoenix's
  `root.html.heex` head (it uses HEEx-only constructs like the `~p` sigil and
  `phx-track-static`, which the `~HOLO` parser does not accept).
  """

  use Hologram.Component

  alias Hologram.UI.Runtime

  def template do
    ~HOLO"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>ImagePipe demo</title>
        <link rel="stylesheet" href="/css/app.css" />
        <Runtime />
      </head>
      <body>
        <slot />
      </body>
    </html>
    """
  end
end
