defmodule Mix.Tasks.ImagePipe.Server do
  @moduledoc """
  Starts the ImagePipe development server.

      $ mix image_pipe.server
      $ mix image_pipe.server --port 4001
      $ mix image_pipe.server --cache
      $ mix image_pipe.server --no-vite

  The server uses the development-only ImagePipe simple server and is available
  only in dev and test.
  """

  use Mix.Task
  use Boundary, top_level?: true, deps: [ImagePipe.Cache, ImagePipe.SimpleServer]

  @shortdoc "Starts the ImagePipe development server"

  @default_port 4000
  @default_vite_port 5173
  @default_cache_root "_build/dev/image_pipe/cache"
  @port_range 1..65_535
  @vite_startup_timeout 5_000
  @vite_ready_marker "ready in"
  @vite_output_buffer_bytes 256

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
    |> OptionParser.parse(
      strict: [cache: :boolean, port: :integer, vite: :boolean],
      aliases: [p: :port]
    )
    |> parse_options()
  end

  defp parse_options({opts, [], []}) do
    with {:ok, port} <- opts |> Keyword.get(:port, @default_port) |> validate_port() do
      {:ok,
       %{
         cache?: Keyword.get(opts, :cache, false),
         port: port,
         vite?: Keyword.get(opts, :vite, true)
       }}
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

  defp start_server(%{cache?: cache?, port: port, vite?: vite?}) do
    server_url = "http://localhost:#{port}"
    vite_origin = "http://localhost:#{@default_vite_port}"

    Application.put_env(:image_pipe, ImagePipe.SimpleServer,
      cache: cache_config(cache?),
      vite_origin: vite_origin
    )

    Mix.Task.run("app.start")

    maybe_start_vite(vite?)
    {:ok, _pid} = start_bandit(port)

    Mix.shell().info("ImagePipe simple server running at #{server_url}")
    maybe_print_vite_info(vite_origin, vite?)
    maybe_print_cache_info(cache?)
    Process.sleep(:infinity)
  end

  defp cache_config(false), do: nil

  defp cache_config(true) do
    {ImagePipe.Cache.FileSystem,
     root: Path.expand(@default_cache_root),
     path_prefix: "processed",
     max_body_bytes: 10_000_000,
     key_headers: [],
     key_cookies: []}
  end

  defp start_bandit(port) do
    with {:module, Bandit} <- Code.ensure_loaded(Bandit),
         {:module, ImagePipe.SimpleServer} <- Code.ensure_loaded(ImagePipe.SimpleServer) do
      apply(Bandit, :start_link, [[plug: ImagePipe.SimpleServer, port: port]])
    else
      _missing -> Mix.raise("ImagePipe simple server is only available in dev and test")
    end
  end

  defp maybe_start_vite(false), do: :ok

  defp maybe_start_vite(true) do
    node = node_path()
    vite_bin_path = vite_bin_path()
    parent = self()

    {:ok, _pid} =
      Task.start(fn ->
        run_vite(node, vite_bin_path, parent)
      end)

    await_vite_startup()
  end

  defp node_path do
    case System.find_executable("node") do
      nil -> Mix.raise("node is required to run the demo Vite dev server")
      node -> node
    end
  end

  defp vite_bin_path do
    path = Path.expand("node_modules/vite/bin/vite.js", File.cwd!())

    case File.regular?(path) do
      true ->
        path

      false ->
        Mix.raise("Vite is not installed; run pnpm install before starting the demo server")
    end
  end

  defp run_vite(node, vite_bin_path, parent) do
    port =
      Port.open({:spawn_executable, node}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args,
         [
           vite_bin_path,
           "--host",
           "localhost",
           "--port",
           Integer.to_string(@default_vite_port),
           "--strictPort"
         ]},
        {:cd, File.cwd!()}
      ])

    stream_vite_output(port, parent, "")
  end

  defp stream_vite_output(port, parent, carry) do
    receive do
      {^port, {:data, data}} ->
        IO.write(data)
        {ready?, next_carry} = vite_ready_buffer(carry, data)
        maybe_notify_vite_ready(parent, ready?)
        stream_vite_output(port, parent, next_carry)

      {^port, {:exit_status, status}} when status in [0, 130, 143] ->
        :ok

      {^port, {:exit_status, status}} ->
        send(parent, {:vite_failed, status})
        :ok
    end
  end

  @doc false
  def vite_ready_buffer(carry, data) do
    buffer = carry <> data

    {String.contains?(buffer, @vite_ready_marker), trim_vite_output_buffer(buffer)}
  end

  defp trim_vite_output_buffer(buffer) when byte_size(buffer) > @vite_output_buffer_bytes do
    binary_part(buffer, byte_size(buffer) - @vite_output_buffer_bytes, @vite_output_buffer_bytes)
  end

  defp trim_vite_output_buffer(buffer), do: buffer

  defp maybe_notify_vite_ready(parent, ready?) do
    case ready? do
      true -> send(parent, :vite_ready)
      false -> :ok
    end
  end

  defp await_vite_startup do
    receive do
      :vite_ready ->
        :ok

      {:vite_failed, status} ->
        Mix.raise("Vite dev server exited with status #{status}")
    after
      @vite_startup_timeout ->
        Mix.raise("Timed out waiting for Vite dev server to start")
    end
  end

  defp maybe_print_cache_info(false), do: :ok

  defp maybe_print_cache_info(true) do
    Mix.shell().info("Filesystem cache enabled at #{Path.expand(@default_cache_root)}")
  end

  defp maybe_print_vite_info(_vite_origin, false), do: :ok

  defp maybe_print_vite_info(vite_origin, true) do
    Mix.shell().info("Demo assets served by Vite at #{vite_origin}")
  end
end
