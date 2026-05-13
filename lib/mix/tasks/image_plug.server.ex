defmodule Mix.Tasks.ImagePlug.Server do
  @moduledoc """
  Starts the ImagePlug development server.

      $ mix image_plug.server
      $ mix image_plug.server --port 4001
      $ mix image_plug.server --cache

  The server uses `ImagePlug.SimpleServer` and is available only in dev and test.
  """

  use Mix.Task
  use Boundary, top_level?: true, deps: [ImagePlug.Cache, ImagePlug.SimpleServer]

  @shortdoc "Starts the ImagePlug development server"

  @default_port 4000
  @default_cache_root "_build/dev/image_plug/cache"
  @port_range 1..65_535

  @impl Mix.Task
  def run(args) do
    case parse_args(args) do
      {:ok, opts} ->
        start_server(opts)

      {:error, message} ->
        Mix.raise(message)
    end
  end

  @doc false
  def parse_args(args) do
    args
    |> OptionParser.parse(strict: [cache: :boolean, port: :integer], aliases: [p: :port])
    |> parse_options()
  end

  defp parse_options({opts, [], []}) do
    with {:ok, port} <- opts |> Keyword.get(:port, @default_port) |> validate_port() do
      {:ok, %{cache?: Keyword.get(opts, :cache, false), port: port}}
    end
  end

  defp parse_options({_opts, [arg | _rest], []}), do: {:error, "unexpected argument: #{arg}"}

  defp parse_options({_opts, _args, [{option, nil} | _rest]}),
    do: {:error, "unknown option: #{option}"}

  defp parse_options({_opts, _args, [{option, value} | _rest]}),
    do: {:error, "invalid value for #{option}: #{value}"}

  defp validate_port(port) when port in @port_range, do: {:ok, port}

  defp validate_port(_port),
    do: {:error, "expected --port to be between #{@port_range.first} and #{@port_range.last}"}

  defp start_server(%{cache?: cache?, port: port}) do
    root_url = "http://localhost:#{port}"

    Application.put_env(:image_plug, ImagePlug.SimpleServer,
      cache: cache_config(cache?),
      root_url: root_url
    )

    Mix.Task.run("app.start")

    {:ok, _pid} = start_bandit(port)

    Mix.shell().info("ImagePlug simple server running at #{root_url}")
    maybe_print_cache_info(cache?)
    Process.sleep(:infinity)
  end

  defp cache_config(false), do: nil

  defp cache_config(true) do
    {ImagePlug.Cache.FileSystem,
     root: Path.expand(@default_cache_root),
     path_prefix: "processed",
     max_body_bytes: 10_000_000,
     key_headers: [],
     key_cookies: [],
     fail_on_cache_error: false}
  end

  defp start_bandit(port) do
    with {:module, Bandit} <- Code.ensure_loaded(Bandit),
         {:module, ImagePlug.SimpleServer} <- Code.ensure_loaded(ImagePlug.SimpleServer) do
      apply(Bandit, :start_link, [[plug: ImagePlug.SimpleServer, port: port]])
    else
      _missing -> Mix.raise("ImagePlug simple server is only available in dev and test")
    end
  end

  defp maybe_print_cache_info(false), do: :ok

  defp maybe_print_cache_info(true) do
    Mix.shell().info("Filesystem cache enabled at #{Path.expand(@default_cache_root)}")
  end
end
