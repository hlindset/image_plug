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

  @demo_template_path Path.expand("../demo/dev.html", __DIR__)
  @external_resource @demo_template_path
  @demo_template File.read!(@demo_template_path)

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

  get "/demo" do
    send_demo_html(conn)
  end

  get "/demo/*_path" do
    send_demo_html(conn)
  end

  match _ do
    ImagePlug.call(conn, image_plug_opts())
  end

  defp image_plug_opts do
    [
      root_url: root_url(),
      parser: ImagePlug.Parser.Imgproxy,
      imgproxy: [
        signature: [
          keys: ["736563726574"],
          salts: ["68656c6c6f"],
          trusted_signatures: ["_", "unsafe"]
        ]
      ]
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

  defp demo_html do
    String.replace(@demo_template, "{{VITE_ORIGIN}}", vite_origin())
  end

  defp send_demo_html(conn) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, demo_html())
  end

  defp vite_origin do
    :image_plug
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:vite_origin, "http://localhost:5173")
  end

  defp maybe_put_cache(opts, nil), do: opts
  defp maybe_put_cache(opts, cache), do: Keyword.put(opts, :cache, cache)
end
