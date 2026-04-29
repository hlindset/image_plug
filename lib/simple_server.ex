defmodule ImagePlug.SimpleServer do
  use Plug.Router
  use Plug.Debugger

  plug Plug.Static,
    at: "/",
    from: {:image_plug, "priv/static"},
    only: ~w(images)

  plug :match
  plug :dispatch

  # Missing origin image paths should 404 here instead of being forwarded back
  # through ImagePlug and parsed as processing URLs.
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
