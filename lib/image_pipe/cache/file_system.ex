defmodule ImagePipe.Cache.FileSystem do
  @moduledoc """
  Filesystem-backed cache adapter for processed image responses.
  """

  @behaviour ImagePipe.Cache

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.Key

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
    IO.binwrite(state.body_io, chunk)

    {:ok,
     %{
       state
       | size: state.size + byte_size(chunk),
         hash_context: :crypto.hash_update(state.hash_context, chunk)
     }}
  rescue
    exception in [ErlangError] -> {:error, exception.original, state}
  catch
    :exit, reason -> {:error, reason, state}
  end

  @impl true
  def commit_sink(state, _opts) when is_map(state) do
    case prepare_sink_commit(state) do
      {:ok, state, body_filename} ->
        commit_prepared_sink(state, body_filename)

      {:error, reason, state} ->
        cleanup_sink_state(state)
        {:error, reason}
    end
  end

  defp prepare_sink_commit(state) do
    with :ok <- close_body_io(state),
         body_sha256 = finalize_body_sha256(state.hash_context),
         body_filename = body_filename(state.paths.hash, body_sha256),
         encoded_metadata = sink_metadata(state, body_sha256, body_filename),
         {:ok, temp_meta_path} <- write_sink_metadata(state.paths, encoded_metadata) do
      {:ok, %{state | temp_meta_path: temp_meta_path}, body_filename}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp commit_prepared_sink(state, body_filename) do
    case commit_sink_files(state, body_filename) do
      :ok ->
        :ok

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
         :ok <- validate_representative_cache_dir(validated_opts) do
      {:ok, validated_opts}
    end
  end

  defp validate_representative_cache_dir(validated_opts) do
    root = Keyword.fetch!(validated_opts, :root)
    path_prefix = Keyword.fetch!(validated_opts, :path_prefix)
    # Probe the directory shape every cache key will use after hash partitioning.
    dir = Path.join([root, path_prefix, "00", "00"])

    validate_under_root(root, dir)
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
    known_option_keys = @option_keys ++ ImagePipe.Cache.shared_option_keys()

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
        segment in ["", ".", ".."]
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
         # Cache hits trust metadata plus byte size without recomputing the body
         # digest. That keeps reads compatible with the future streaming hit path.
         :ok <- validate_body_size(body, metadata),
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

  defp validate_body_size(body, %{body_byte_size: body_byte_size})
       when byte_size(body) == body_byte_size,
       do: :ok

  defp validate_body_size(_body, _metadata), do: handle_invalid_metadata(:body_byte_size_mismatch)

  defp sink_metadata(state, body_sha256, body_filename) do
    metadata = %{
      metadata_version: @metadata_version,
      content_type: state.metadata.content_type,
      headers: state.metadata.headers,
      created_at: DateTime.to_iso8601(state.metadata.created_at),
      body_byte_size: state.size,
      body_sha256: body_sha256,
      body_filename: body_filename,
      cost_us: state.metadata.cost_us
    }

    :erlang.term_to_binary(metadata, [:deterministic])
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
         body_filename: body_filename,
         cost_us: cost_us
       })
       when is_binary(content_type) and is_list(headers) and is_binary(created_at) and
              is_integer(body_byte_size) and body_byte_size >= 0 and is_binary(body_sha256) and
              is_binary(body_filename) and is_integer(cost_us) and cost_us >= 0 do
    with :ok <- validate_metadata_content_type(content_type),
         :ok <- validate_metadata_headers(headers) do
      {:ok,
       %{
         content_type: content_type,
         headers: headers,
         created_at: created_at,
         body_byte_size: body_byte_size,
         body_sha256: body_sha256,
         body_filename: body_filename,
         cost_us: cost_us
       }}
    end
  end

  defp validate_metadata(%{metadata_version: _version}), do: {:error, :version_mismatch}
  defp validate_metadata(_metadata), do: {:error, :invalid_shape}

  defp handle_invalid_metadata(reason), do: {:error, {:invalid_metadata, reason}}

  defp validate_metadata_content_type(content_type) do
    case Entry.validate_content_type(content_type) do
      :ok -> :ok
      {:error, reason} -> {:error, {:invalid_content_type, reason}}
    end
  end

  defp validate_metadata_headers(headers) do
    if Enum.all?(headers, &valid_metadata_header?/1) do
      :ok
    else
      {:error, :invalid_headers}
    end
  end

  defp valid_metadata_header?({name, value}), do: is_binary(name) and is_binary(value)
  defp valid_metadata_header?(_header), do: false

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

  defp write_sink_metadata(paths, encoded_metadata) do
    temp_path = temp_path(paths)

    case File.write(temp_path, encoded_metadata, [:binary, :exclusive]) do
      :ok -> {:ok, temp_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp commit_sink_files(state, body_filename) do
    body_path = Path.join(state.paths.dir, body_filename)

    with :ok <- commit_body_file(state.temp_body_path, body_path, body_filename) do
      commit_metadata_file(state.paths.meta_path, state.temp_meta_path)
    end
  end

  defp commit_metadata_file(meta_path, meta_tmp_path) do
    File.rename(meta_tmp_path, meta_path)
  end

  defp commit_body_file(body_tmp_path, body_path, body_filename) do
    if matching_body_file?(body_path, body_filename) do
      # Existing matching body content wins. The new temp body is no longer
      # needed, and cleanup is best-effort cache housekeeping.
      cleanup_temp_files([body_tmp_path])
      :ok
    else
      case File.rename(body_tmp_path, body_path) do
        :ok -> :ok
        {:error, :eexist} -> use_existing_body_file(body_tmp_path, body_path, body_filename)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp use_existing_body_file(body_tmp_path, body_path, body_filename) do
    if matching_body_file?(body_path, body_filename) do
      cleanup_temp_files([body_tmp_path])
      :ok
    else
      {:error, :body_file_exists}
    end
  end

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
    :exit, reason -> {:error, {:close_failed, reason}}
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
    |> Enum.each(&File.rm/1)
  end

  @doc false
  def paths(%Key{hash: hash}, opts), do: paths_from_hash(hash, opts)

  @doc false
  def paths_from_hash(hash, opts) when is_binary(hash) and is_list(opts) do
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

  @doc false
  @spec read_descriptor(Path.t()) ::
          {:ok, %{key_hash: binary(), size_bytes: non_neg_integer(), body_sha256: binary(), cost_us: non_neg_integer()},
           integer()}
          | {:error, term()}
  def read_descriptor(meta_path) do
    with {:ok, meta_binary} <- read_cache_file(meta_path, :metadata),
         {:ok, metadata} <- decode_metadata(meta_binary),
         {:ok, %File.Stat{mtime: mtime}} <- File.stat(meta_path, time: :posix) do
      {:ok,
       %{
         key_hash: Path.basename(meta_path, ".meta"),
         size_bytes: metadata.body_byte_size,
         body_sha256: metadata.body_sha256,
         cost_us: metadata.cost_us
       }, mtime}
    else
      :miss -> {:error, :enoent}
      {:error, _} = error -> error
    end
  end

  @doc false
  def delete_victims([], _opts), do: :ok

  def delete_victims(victims, opts) do
    Enum.each(victims, fn victim ->
      with {:ok, victim_paths} <- paths_from_hash(victim.key_hash, opts) do
        if victim.delete_body? do
          body_path =
            Path.join(victim_paths.dir, "#{victim.key_hash}.#{victim.body_sha256}.body")

          rm_tolerant(body_path)
        end

        if victim.delete_meta? do
          rm_tolerant(victim_paths.meta_path)
        end
      end
    end)
  end

  defp rm_tolerant(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        require Logger
        # Path omitted: victim body/meta filenames embed the cache key
        # hash (a cache-adapter internal). Log the reason only.
        Logger.warning("cache: victim delete failed: reason=#{inspect(reason)}")
        :ok
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

    # The two-argument form resolves symlinks against root. A plain prefix check
    # would allow a partition directory symlink to point outside the cache root.
    case Path.safe_relative(relative, root) do
      {:ok, _relative} -> :ok
      :error -> {:error, {:path_outside_root, path}}
    end
  end

  defp body_filename(hash, body_sha256), do: "#{hash}.#{body_sha256}.body"

  defp body_sha256_from_filename(body_filename) do
    case String.split(body_filename, ".", parts: 3) do
      [_hash, body_sha256, "body"] ->
        if valid_body_sha256?(body_sha256) do
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
    Path.join(paths.dir, ".#{paths.hash}.#{random}.tmp")
  end
end
