defmodule ImagePlug.SimpleServer do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [
      ImagePlug,
      ImagePlug.Parser
    ]

  use Plug.Router
  use Plug.Debugger

  plug Plug.Static,
    at: "/",
    from: {:image_plug, "priv/static"},
    only: ~w(demo images)

  plug :match
  plug :dispatch

  # Missing origin image paths should 404 here instead of being forwarded back
  # through ImagePlug and parsed as processing URLs.
  match "/images/*path" do
    send_resp(conn, 404, "404 Not Found")
  end

  get "/demo" do
    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, demo_path("index.html"))
  end

  match _ do
    ImagePlug.call(conn, image_plug_opts())
  end

  defp demo_path(filename) do
    Path.join([:code.priv_dir(:image_plug), "static", "demo", filename])
  end

  defp image_plug_opts do
    [
      root_url: root_url(),
      parser: ImagePlug.Parser.Imgproxy
    ]
    |> maybe_put_cache(cache_config())
    |> ImagePlug.init()
  end

  defp root_url do
    :image_plug
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:root_url, "http://localhost:4000")
  end

  defp cache_config do
    :image_plug
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:cache)
  end

  defp maybe_put_cache(opts, nil), do: opts
  defp maybe_put_cache(opts, cache), do: Keyword.put(opts, :cache, cache)
end
