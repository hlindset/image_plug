defmodule ImagePipeDemoWeb.Router do
  use ImagePipeDemoWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ImagePipeDemoWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Real image requests flow through the library plug under test. The imgproxy
  # parser derives its prefix from `script_name`, so forwarding at "/img"
  # strips the mount prefix correctly. Source files resolve from priv/static,
  # and unsigned dev URLs use "_" or "unsafe" as the signature segment, e.g.
  # /img/_/rs:fit:400:300/images/dog.jpg
  forward "/img", ImagePipe.Plug,
    parser: ImagePipe.Parser.Imgproxy,
    sources: [
      path: {ImagePipe.Source.File, root: "priv/static", root_id: "static", stable: :trusted}
    ],
    imgproxy: [
      signature: [
        keys: ["736563726574"],
        salts: ["68656c6c6f"],
        trusted_signatures: ["_", "unsafe"]
      ]
    ]

  # Hologram pages own the rest of the routes; the Phoenix router keeps only
  # the fallback. (Hologram's page routes are matched in the endpoint, ahead
  # of this router.)
end
