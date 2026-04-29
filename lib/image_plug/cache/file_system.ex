defmodule ImagePlug.Cache.FileSystem do
  @moduledoc """
  Filesystem-backed cache adapter for processed image responses.
  """

  @behaviour ImagePlug.Cache

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key

  @metadata_version 1
  @hash_pattern ~r/\A[0-9A-Fa-f]{64}\z/

  @impl true
  def get(%Key{} = key, opts) when is_list(opts) do
    with {:ok, paths} <- paths(key, opts) do
      read_entry(paths, opts)
    end
  end

  @impl true
  def put(%Key{} = key, %Entry{} = entry, opts) when is_list(opts) do
    with {:ok, paths} <- paths(key, opts),
         :ok <- File.mkdir_p(paths.dir),
         {:ok, metadata} <- metadata(entry) do
      write_and_commit(paths, entry.body, :erlang.term_to_binary(metadata, [:deterministic]))
    end
  end

  defp read_entry(paths, opts) do
    with {:ok, meta_binary} <- read_cache_file(paths.meta_path, :metadata, opts),
         {:ok, metadata} <- decode_metadata(meta_binary, opts),
         {:ok, body} <- read_cache_file(paths.body_path, :body, opts),
         :ok <- validate_body(body, metadata, opts),
         {:ok, created_at} <- parse_created_at(metadata.created_at, opts),
         {:ok, entry} <- entry(body, metadata, created_at, opts) do
      {:hit, entry}
    else
      :miss ->
        :miss

      {:error, {:invalid_metadata, _reason}} = error ->
        error

      {:error, _reason} = error ->
        error
    end
  end

  defp read_cache_file(path, kind, opts) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, :enoent} -> :miss
      {:error, reason} -> handle_read_error(read_error(kind, reason), opts)
    end
  end

  defp read_error(:metadata, reason), do: {:metadata_read, reason}
  defp read_error(:body, reason), do: {:body_read, reason}

  defp handle_read_error(reason, opts) do
    if Keyword.get(opts, :fail_on_cache_error, false) do
      {:error, reason}
    else
      :miss
    end
  end

  defp validate_body(body, %{body_byte_size: body_byte_size}, opts)
       when byte_size(body) != body_byte_size do
    handle_invalid_metadata(:body_byte_size_mismatch, opts)
  end

  defp validate_body(body, %{body_sha256: body_sha256}, opts) do
    if body_sha256(body) == body_sha256 do
      :ok
    else
      handle_invalid_metadata(:body_digest_mismatch, opts)
    end
  end

  defp metadata(%Entry{} = entry) do
    with {:ok, headers} <- Entry.normalize_headers(entry.headers) do
      {:ok,
       %{
         metadata_version: @metadata_version,
         content_type: entry.content_type,
         headers: headers,
         created_at: DateTime.to_iso8601(entry.created_at),
         body_byte_size: byte_size(entry.body),
         body_sha256: body_sha256(entry.body)
       }}
    end
  end

  defp body_sha256(body) do
    :crypto.hash(:sha256, body)
    |> Base.encode16(case: :lower)
  end

  defp decode_metadata(binary, opts) do
    binary
    |> :erlang.binary_to_term([:safe])
    |> validate_metadata()
  rescue
    _error -> handle_invalid_metadata(:decode_failed, opts)
  else
    {:ok, metadata} -> {:ok, metadata}
    {:error, reason} -> handle_invalid_metadata(reason, opts)
  end

  defp validate_metadata(%{
         metadata_version: @metadata_version,
         content_type: content_type,
         headers: headers,
         created_at: created_at,
         body_byte_size: body_byte_size,
         body_sha256: body_sha256
       })
       when is_binary(content_type) and is_list(headers) and is_binary(created_at) and
              is_integer(body_byte_size) and body_byte_size >= 0 and is_binary(body_sha256) do
    {:ok,
     %{
       content_type: content_type,
       headers: headers,
       created_at: created_at,
       body_byte_size: body_byte_size,
       body_sha256: body_sha256
     }}
  end

  defp validate_metadata(%{metadata_version: _version}), do: {:error, :version_mismatch}
  defp validate_metadata(_metadata), do: {:error, :invalid_shape}

  defp handle_invalid_metadata(reason, opts) do
    if Keyword.get(opts, :fail_on_cache_error, false) do
      {:error, {:invalid_metadata, reason}}
    else
      :miss
    end
  end

  defp parse_created_at(created_at, opts) do
    case DateTime.from_iso8601(created_at) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> handle_invalid_metadata({:invalid_created_at, reason}, opts)
    end
  end

  defp entry(body, metadata, created_at, opts) do
    case Entry.new(
           body: body,
           content_type: metadata.content_type,
           headers: metadata.headers,
           created_at: created_at
         ) do
      {:ok, entry} -> {:ok, entry}
      {:error, reason} -> handle_invalid_metadata({:invalid_entry, reason}, opts)
    end
  end

  defp write_and_commit(paths, body, encoded_metadata) do
    with {:ok, body_tmp_path} <- write_temp(paths, body) do
      case write_temp(paths, encoded_metadata) do
        {:ok, meta_tmp_path} ->
          commit(paths, body_tmp_path, meta_tmp_path)

        {:error, reason} ->
          cleanup_temp_files([body_tmp_path])
          {:error, reason}
      end
    end
  end

  defp write_temp(paths, binary) do
    temp_path = temp_path(paths)

    case File.write(temp_path, binary, [:binary, :exclusive]) do
      :ok -> {:ok, temp_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit(paths, body_tmp_path, meta_tmp_path) do
    case File.rename(body_tmp_path, paths.body_path) do
      :ok ->
        case File.rename(meta_tmp_path, paths.meta_path) do
          :ok ->
            :ok

          {:error, reason} ->
            cleanup_temp_files([body_tmp_path, meta_tmp_path])
            {:error, reason}
        end

      {:error, reason} ->
        cleanup_temp_files([body_tmp_path, meta_tmp_path])
        {:error, reason}
    end
  end

  defp cleanup_temp_files(temp_paths) do
    Enum.each(temp_paths, &File.rm/1)
  end

  @doc false
  def paths(%Key{hash: hash}, opts) do
    with {:ok, root} <- root(opts),
         {:ok, path_prefix} <- path_prefix(opts),
         {:ok, {first_partition, second_partition}} <- partitions(hash) do
      dir = Path.join([root, path_prefix, first_partition, second_partition])
      body_path = Path.join(dir, hash <> ".body")
      meta_path = Path.join(dir, hash <> ".meta")

      with :ok <- validate_under_root(root, dir),
           :ok <- validate_under_root(root, body_path),
           :ok <- validate_under_root(root, meta_path) do
        {:ok, %{root: root, dir: dir, body_path: body_path, meta_path: meta_path, hash: hash}}
      end
    end
  end

  defp root(opts) do
    case Keyword.fetch(opts, :root) do
      {:ok, root} when is_binary(root) ->
        if Path.type(root) == :absolute do
          {:ok, Path.expand(root)}
        else
          {:error, {:invalid_root, root}}
        end

      {:ok, root} ->
        {:error, {:invalid_root, root}}

      :error ->
        {:error, {:missing_required_option, :root}}
    end
  end

  defp path_prefix(opts) do
    prefix = Keyword.get(opts, :path_prefix, "")

    cond do
      not is_binary(prefix) ->
        {:error, {:invalid_path_prefix, prefix}}

      prefix == "" ->
        {:ok, ""}

      Path.type(prefix) == :absolute ->
        {:error, {:invalid_path_prefix, prefix}}

      invalid_path_prefix?(prefix) ->
        {:error, {:invalid_path_prefix, prefix}}

      true ->
        {:ok, prefix}
    end
  end

  defp invalid_path_prefix?(prefix) do
    prefix
    |> String.split("/", trim: false)
    |> Enum.any?(fn segment ->
      segment in ["", ".", ".."] or String.starts_with?(segment, "~")
    end)
  end

  defp partitions(hash) when is_binary(hash) do
    unless Regex.match?(@hash_pattern, hash) do
      {:error, {:invalid_hash, hash}}
    else
      do_partitions(hash)
    end
  end

  defp partitions(hash), do: {:error, {:invalid_hash, hash}}

  defp do_partitions(hash) do
    <<first::binary-size(2), second::binary-size(2), _rest::binary>> = hash
    {:ok, {first, second}}
  end

  defp validate_under_root(root, path) do
    root = Path.expand(root)
    path = Path.expand(path)

    if root?(root, path) do
      :ok
    else
      {:error, {:path_outside_root, path}}
    end
  end

  defp root?("/", path), do: String.starts_with?(path, "/")
  defp root?(root, path), do: path == root or String.starts_with?(path, root <> "/")

  defp temp_path(paths) do
    Path.join(paths.dir, ".#{paths.hash}.#{System.unique_integer([:positive])}.tmp")
  end
end
