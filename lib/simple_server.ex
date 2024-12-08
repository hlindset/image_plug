defmodule ImagePlug.SimpleServer do
  use Plug.Router
  use Plug.Debugger

  plug Plug.Static,
    at: "/",
    from: {:image_plug, "priv/static"},
    only: ~w(images)

  plug :match
  plug :dispatch

  forward "/process",
    to: ImagePlug,
    init_opts: [
      root_url: "http://localhost:4000",
      param_parser: ImagePlug.ParamParser.Twicpics
    ]

  match _ do
    send_resp(conn, 404, "404 Not Found")
  end
end
