defmodule ImagePipeDemoWeb.FiddleLayout do
  use Hologram.Component
  alias Hologram.UI.Runtime

  def template do
    ~HOLO"""
    <!DOCTYPE html>
    <html lang="en" data-theme="dark">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>ImagePipe Fiddle</title>
        <link rel="stylesheet" href="/css/fiddle.css" />
        <Runtime />
      </head>
      <body>
        <slot />
      </body>
    </html>
    """
  end
end
