defmodule ImagePlug.Cache.FileSystem do
  @moduledoc """
  Filesystem-backed cache adapter for processed image responses.
  """

  @behaviour ImagePlug.Cache

  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key

  @metadata_version 1
  @cache_key_hash_pattern ~r/\A[0-9A-Fa-f]{64}\z/
  @body_sha256_pattern ~r/\A[0-9a-f]{64}\z/
  @option_keys [:root, :path_prefix]
  @options_schema NimbleOptions.new!(
                    root: [
                      required: true,
                      type: {:custom, __MODULE__, :validate_root, []}
                    ],
                    path_prefix: [
                      default: "",
                      type: {:custom, __MODULE__, :validate_path_prefix, []}
                    ]
                  )

  @impl true
  def get(%Key{} = key, opts) when is_list(opts) do
    case paths(key, opts) do
      {:ok, paths} -> read_entry(paths)
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def open_sink(%Key{} = key, %Entry.Metadata{} = metadata, opts) when is_list(opts) do
    with {:ok, paths} <- paths(key, opts),
         :ok <- File.mkdir_p(paths.dir),
         temp_body_path = temp_path(paths),
         {:ok, body_io} <- File.open(temp_body_path, [:write, :binary, :exclusive]) do
      {:ok,
       %{
         paths: paths,
         temp_body_path: temp_body_path,
         temp_meta_path: nil,
         body_io: body_io,
         size: 0,
         hash_context: :crypto.hash_init(:sha256),
         metadata: metadata
       }}
    end
  end

  @impl true
  def write_chunk(state, chunk, _opts) when is_binary(chunk) do
    :ok = IO.binwrite(state.body_io, chunk)

    {:ok,
     %{
       state
       | size: state.size + byte_size(chunk),
         hash_context: :crypto.hash_update(state.hash_context, chunk)
     }}
  catch
    :exit, reason -> {:error, reason, state}
  end

  @impl true
  def commit_sink(state, _opts) when is_map(state) do
    with :ok <- close_body_io(state),
         body_sha256 = finalize_body_sha256(state.hash_context),
         body_filename = body_filename(state.paths.hash, body_sha256),
         encoded_metadata = sink_metadata(state, body_sha256, body_filename),
         {:ok, temp_meta_path} <- write_sink_metadata(state, encoded_metadata),
         :ok <- commit_sink_files(%{state | temp_meta_path: temp_meta_path}, body_filename) do
      :ok
    else
      {:error, reason} ->
        cleanup_sink_state(state)
        {:error, reason}
    end
  end

  @impl true
  def abort_sink(state, _opts) when is_map(state) do
    cleanup_sink_state(state)
  end

  @impl true
  def validate_options(opts) when is_list(opts) do
    with {:ok, validated_opts} <- validate_filesystem_options(opts),
         root = Keyword.fetch!(validated_opts, :root),
         path_prefix = Keyword.fetch!(validated_opts, :path_prefix),
         {:ok, {first_partition, second_partition}} <- partitions(String.duplicate("0", 64)) do
      dir = Path.join([root, path_prefix, first_partition, second_partition])

      with :ok <- validate_under_root(root, dir) do
        {:ok, validated_opts}
      end
    end
  end

  defp validate_filesystem_options(opts) do
    with :ok <- validate_unknown_options(opts),
         {:ok, validated_opts} <- validate_known_options(opts) do
      {:ok, validated_opts}
    end
  end

  defp validate_known_options(opts) do
    case NimbleOptions.validate(Keyword.take(opts, @option_keys), @options_schema) do
      {:ok, validated_opts} -> {:ok, validated_opts}
      {:error, error} -> {:error, options_validation_error(error)}
    end
  end

  defp validate_unknown_options(opts) do
    known_option_keys = @option_keys ++ ImagePlug.Cache.shared_option_keys()

    case Keyword.keys(opts) -- known_option_keys do
      [] -> :ok
      unknown_keys -> {:error, {:unknown_options, Enum.uniq(unknown_keys)}}
    end
  end

  @doc false
  def validate_root(root) when is_binary(root) do
    if Path.type(root) == :absolute do
      {:ok, Path.expand(root)}
    else
      {:error, "expected absolute path, got: #{inspect(root)}"}
    end
  end

  def validate_root(root), do: {:error, "expected absolute path string, got: #{inspect(root)}"}

  @doc false
  def validate_path_prefix(""), do: {:ok, ""}

  def validate_path_prefix(prefix) when is_binary(prefix) do
    invalid_segment? =
      prefix
      |> String.split("/", trim: false)
      |> Enum.any?(fn segment ->
        segment in ["", ".", ".."] or String.starts_with?(segment, "~")
      end)

    if Path.type(prefix) == :relative and not String.contains?(prefix, "\\") and
         not invalid_segment? do
      {:ok, prefix}
    else
      {:error, "expected relative path without traversal, got: #{inspect(prefix)}"}
    end
  end

  def validate_path_prefix(prefix),
    do: {:error, "expected relative path string, got: #{inspect(prefix)}"}

  defp options_validation_error(%NimbleOptions.ValidationError{key: :root, value: nil}),
    do: {:missing_required_option, :root}

  defp options_validation_error(%NimbleOptions.ValidationError{key: :root, value: root}),
    do: {:invalid_root, root}

  defp options_validation_error(%NimbleOptions.ValidationError{key: :path_prefix, value: prefix}),
    do: {:invalid_path_prefix, prefix}

  defp read_entry(paths) do
    with {:ok, meta_binary} <- read_cache_file(paths.meta_path, :metadata),
         {:ok, metadata} <- decode_metadata(meta_binary),
         {:ok, body_path} <- body_path_from_metadata(paths, metadata),
         {:ok, body} <- read_cache_file(body_path, :body),
         :ok <- validate_body(body, metadata),
         {:ok, created_at} <- parse_created_at(metadata.created_at) do
      {:hit,
       %Entry{
         body: body,
         content_type: metadata.content_type,
         headers: metadata.headers,
         created_at: created_at
       }}
    end
  end

  defp read_cache_file(path, kind) do
    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      {:error, :enoent} -> :miss
      {:error, reason} -> {:error, read_error(kind, reason)}
    end
  end

  defp read_error(:metadata, reason), do: {:metadata_read, reason}
  defp read_error(:body, reason), do: {:body_read, reason}

  defp validate_body(body, %{body_byte_size: body_byte_size, body_sha256: body_sha256}) do
    cond do
      byte_size(body) != body_byte_size -> handle_invalid_metadata(:body_byte_size_mismatch)
      body_sha256(body) != body_sha256 -> handle_invalid_metadata(:body_digest_mismatch)
      true -> :ok
    end
  end

  defp sink_metadata(state, body_sha256, body_filename) do
    metadata = %{
      metadata_version: @metadata_version,
      content_type: state.metadata.content_type,
      headers: state.metadata.headers,
      created_at: DateTime.to_iso8601(state.metadata.created_at),
      body_byte_size: state.size,
      body_sha256: body_sha256,
      body_filename: body_filename
    }

    :erlang.term_to_binary(metadata, [:deterministic])
  end

  defp body_sha256(body) do
    Base.encode16(:crypto.hash(:sha256, body), case: :lower)
  end

  defp decode_metadata(binary) do
    metadata = :erlang.binary_to_term(binary, [:safe])

    case validate_metadata(metadata) do
      {:ok, metadata} -> {:ok, metadata}
      {:error, reason} -> handle_invalid_metadata(reason)
    end
  rescue
    ArgumentError -> handle_invalid_metadata(:decode_failed)
  end

  defp validate_metadata(%{
         metadata_version: @metadata_version,
         content_type: content_type,
         headers: headers,
         created_at: created_at,
         body_byte_size: body_byte_size,
         body_sha256: body_sha256,
         body_filename: body_filename
       })
       when is_binary(content_type) and is_list(headers) and is_binary(created_at) and
              is_integer(body_byte_size) and body_byte_size >= 0 and is_binary(body_sha256) and
              is_binary(body_filename) do
    {:ok,
     %{
       content_type: content_type,
       headers: headers,
       created_at: created_at,
       body_byte_size: body_byte_size,
       body_sha256: body_sha256,
       body_filename: body_filename
     }}
  end

  defp validate_metadata(%{metadata_version: _version}), do: {:error, :version_mismatch}
  defp validate_metadata(_metadata), do: {:error, :invalid_shape}

  defp handle_invalid_metadata(reason), do: {:error, {:invalid_metadata, reason}}

  defp parse_created_at(created_at) do
    case DateTime.from_iso8601(created_at) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> handle_invalid_metadata({:invalid_created_at, reason})
    end
  end

  defp body_path_from_metadata(
         paths,
         %{body_filename: body_filename, body_sha256: body_sha256}
       ) do
    expected_body_filename = body_filename(paths.hash, body_sha256)

    if valid_body_sha256?(body_sha256) and body_filename == expected_body_filename do
      {:ok, Path.join(paths.dir, body_filename)}
    else
      handle_invalid_metadata(:invalid_body_filename)
    end
  end

  defp valid_body_sha256?(body_sha256),
    do: is_binary(body_sha256) and Regex.match?(@body_sha256_pattern, body_sha256)

  defp write_sink_metadata(state, encoded_metadata) do
    temp_path = state.temp_meta_path || temp_path(state.paths)

    case File.write(temp_path, encoded_metadata, [:binary, :exclusive]) do
      :ok -> {:ok, temp_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit_sink_files(state, body_filename) do
    body_path = Path.join(state.paths.dir, body_filename)

    with {:ok, body_status} <-
           commit_body_file(state.temp_body_path, state.temp_meta_path, body_path, body_filename),
         :ok <-
           commit_metadata_file(
             state.paths,
             state.temp_body_path,
             state.temp_meta_path,
             body_path,
             body_status
           ) do
      :ok
    end
  end

  defp commit_metadata_file(paths, body_tmp_path, meta_tmp_path, body_path, body_status) do
    case File.rename(meta_tmp_path, paths.meta_path) do
      :ok ->
        :ok

      {:error, reason} ->
        rollback_committed_body(body_path, body_status)
        cleanup_temp_files([body_tmp_path, meta_tmp_path])
        {:error, reason}
    end
  end

  defp commit_body_file(body_tmp_path, meta_tmp_path, body_path, body_filename) do
    if matching_body_file?(body_path, body_filename) do
      cleanup_temp_files([body_tmp_path])
      {:ok, :existing}
    else
      case File.rename(body_tmp_path, body_path) do
        :ok ->
          {:ok, :moved}

        {:error, :eexist} ->
          use_existing_body_file(body_tmp_path, meta_tmp_path, body_path, body_filename)

        {:error, reason} ->
          cleanup_body_commit_failure(body_tmp_path, meta_tmp_path, reason)
      end
    end
  end

  defp use_existing_body_file(body_tmp_path, meta_tmp_path, body_path, body_filename) do
    if matching_body_file?(body_path, body_filename) do
      cleanup_temp_files([body_tmp_path])
      {:ok, :existing}
    else
      cleanup_body_commit_failure(body_tmp_path, meta_tmp_path, :body_file_exists)
    end
  end

  defp cleanup_body_commit_failure(body_tmp_path, meta_tmp_path, reason) do
    cleanup_temp_files([body_tmp_path, meta_tmp_path])
    {:error, reason}
  end

  defp rollback_committed_body(body_path, :moved), do: File.rm(body_path)
  defp rollback_committed_body(_body_path, :existing), do: :ok

  defp matching_body_file?(body_path, body_filename) do
    with {:ok, expected_sha256} <- body_sha256_from_filename(body_filename),
         {:ok, actual_sha256} <- file_sha256(body_path) do
      actual_sha256 == expected_sha256
    else
      _reason -> false
    end
  end

  defp file_sha256(path) do
    with {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        sha256 =
          io
          |> IO.binstream(64 * 1024)
          |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
          |> finalize_body_sha256()

        {:ok, sha256}
      after
        File.close(io)
      end
    end
  end

  defp close_body_io(%{body_io: body_io}) do
    case File.close(body_io) do
      :ok -> :ok
      {:error, :terminated} -> :ok
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _reason -> :ok
  end

  defp finalize_body_sha256(hash_context) do
    hash_context
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp cleanup_sink_state(state) do
    _result = close_body_io(state)
    cleanup_temp_files([state.temp_body_path, state.temp_meta_path])
  end

  defp cleanup_temp_files(temp_paths) do
    temp_paths
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while(:ok, fn path, :ok ->
      case File.rm(path) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:temp_cleanup, path, reason}}}
      end
    end)
  end

  @doc false
  def paths(%Key{hash: hash}, opts) do
    with {:ok, opts} <- validate_filesystem_options(opts),
         root = Keyword.fetch!(opts, :root),
         path_prefix = Keyword.fetch!(opts, :path_prefix),
         {:ok, {first_partition, second_partition}} <- partitions(hash) do
      dir = Path.join([root, path_prefix, first_partition, second_partition])
      meta_path = Path.join(dir, hash <> ".meta")

      with :ok <- validate_under_root(root, dir) do
        {:ok, %{root: root, dir: dir, meta_path: meta_path, hash: hash}}
      end
    end
  end

  defp partitions(hash) when is_binary(hash) do
    if Regex.match?(@cache_key_hash_pattern, hash) do
      do_partitions(hash)
    else
      {:error, {:invalid_hash, hash}}
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
    relative = Path.relative_to(path, root, force: true)

    case Path.safe_relative(relative, root) do
      {:ok, _relative} -> :ok
      :error -> {:error, {:path_outside_root, path}}
    end
  end

  defp body_filename(hash, body_sha256), do: "#{hash}.#{body_sha256}.body"

  defp body_sha256_from_filename(body_filename) do
    case String.split(body_filename, ".", parts: 3) do
      [hash, body_sha256, "body"]
      when is_binary(hash) and is_binary(body_sha256) ->
        if Regex.match?(@cache_key_hash_pattern, hash) and valid_body_sha256?(body_sha256) do
          {:ok, body_sha256}
        else
          {:error, :invalid_body_filename}
        end

      _parts ->
        {:error, :invalid_body_filename}
    end
  end

  defp temp_path(paths) do
    random = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    Path.join(paths.dir, ".#{paths.hash}.#{System.os_time()}.#{random}.tmp")
  end
end
