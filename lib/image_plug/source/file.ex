defmodule ImagePlug.Source.File do
  @moduledoc false

  @behaviour ImagePlug.Source

  alias ImagePlug.Plan.Source.Path, as: SourcePath
  alias ImagePlug.Source
  alias ImagePlug.Source.Resolved
  alias ImagePlug.Source.Response

  @options_schema NimbleOptions.new!(
                    root: [type: :string, required: true],
                    root_id: [type: :string, required: true],
                    cache: [type: {:in, [:normal, :skip]}, default: :normal]
                  )

  @impl Source
  def validate_options(opts) do
    case NimbleOptions.validate(opts, @options_schema) do
      {:ok, validated} ->
        {:ok, Keyword.update!(validated, :root, &Path.expand/1)}

      {:error, error} ->
        {:error, {:invalid_source_config, Exception.message(error)}}
    end
  end

  @impl Source
  def resolve(%SourcePath{segments: segments}, opts, _runtime_opts) do
    with :ok <- validate_segments(segments),
         {:ok, path} <- safe_path(opts, segments) do
      {:ok,
       %Resolved{
         adapter: :path,
         source_kind: :path,
         identity: [
           kind: :path,
           adapter: :path,
           root: Keyword.fetch!(opts, :root_id),
           path: segments
         ],
         cache: Keyword.fetch!(opts, :cache),
         fetch: [path: path, root: Keyword.fetch!(opts, :root), segments: segments]
       }}
    end
  end

  @impl Source
  def fetch(%Resolved{fetch: fetch}, _opts, _runtime_opts) do
    with {:ok, path} <- safe_path(fetch[:root], fetch[:segments]),
         :ok <- regular_file(path) do
      {:ok, %Response{stream: File.stream!(path, 2048, [])}}
    end
  end

  defp validate_segments(segments) when is_list(segments) do
    if Enum.all?(segments, &valid_segment?/1) do
      :ok
    else
      {:error, {:source, :denied_path}}
    end
  end

  defp validate_segments(_segments), do: {:error, {:source, :denied_path}}

  defp valid_segment?(segment) when is_binary(segment) do
    segment != "" and segment != "." and segment != ".." and
      not String.contains?(segment, ["/", "\\"])
  end

  defp valid_segment?(_segment), do: false

  defp safe_path(opts, segments) when is_list(opts) do
    safe_path(Keyword.fetch!(opts, :root), segments)
  end

  defp safe_path(root, segments) do
    relative = Path.join(segments)

    case Path.safe_relative(relative, root) do
      {:ok, safe_relative} -> {:ok, Path.join(root, safe_relative)}
      :error -> {:error, {:source, :denied_path}}
    end
  end

  defp regular_file(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _stat} -> {:error, {:source, :unreadable}}
      {:error, :enoent} -> {:error, {:source, :not_found}}
      {:error, :eacces} -> {:error, {:source, :unreadable}}
      {:error, _reason} -> {:error, {:source, :unreadable}}
    end
  end
end
