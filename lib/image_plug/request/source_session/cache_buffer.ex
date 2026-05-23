defmodule ImagePlug.Request.SourceSession.CacheBuffer do
  @moduledoc false

  alias ImagePlug.Cache
  alias ImagePlug.Cache.Entry
  alias ImagePlug.Cache.Key
  alias ImagePlug.Output.Format
  alias ImagePlug.Output.Resolved
  alias ImagePlug.Telemetry

  @enforce_keys [:key, :content_type, :headers, :output_format]
  defstruct @enforce_keys ++
              [
                chunks: [],
                size: 0,
                max_body_bytes: nil,
                status: :collecting,
                emitted_drop?: false
              ]

  @type status :: :collecting | :dropped

  @type t :: %__MODULE__{
          key: Key.t(),
          content_type: String.t(),
          headers: [Entry.header()],
          output_format: atom(),
          chunks: [binary()],
          size: non_neg_integer(),
          max_body_bytes: non_neg_integer() | nil,
          status: status(),
          emitted_drop?: boolean()
        }

  @spec new(Key.t() | nil, Resolved.t(), keyword()) :: {:ok, t() | nil} | {:error, term()}
  def new(nil, %Resolved{}, _opts), do: {:ok, nil}

  def new(%Key{} = key, %Resolved{} = resolved_output, opts) do
    case Entry.cacheable_headers(resolved_output.response_headers) do
      {:ok, headers} ->
        {:ok,
         %__MODULE__{
           key: key,
           content_type: Format.mime_type!(resolved_output.format),
           headers: headers,
           output_format: resolved_output.format,
           max_body_bytes: Cache.max_body_bytes(opts)
         }}

      {:error, reason} ->
        {:error, {:invalid_cache_headers, reason}}
    end
  end

  @spec append(t() | nil, binary(), keyword()) :: t() | nil
  def append(nil, _chunk, _opts), do: nil
  def append(%__MODULE__{status: :dropped} = buffer, _chunk, _opts), do: buffer

  def append(%__MODULE__{} = buffer, chunk, opts) when is_binary(chunk) do
    size = buffer.size + byte_size(chunk)

    if too_large?(size, buffer.max_body_bytes) do
      buffer
      |> drop()
      |> emit_drop_once(opts)
    else
      %{buffer | chunks: [chunk | buffer.chunks], size: size}
    end
  end

  @spec commit(t() | nil, keyword()) :: :ok
  def commit(nil, _opts), do: :ok
  def commit(%__MODULE__{status: :dropped}, _opts), do: :ok

  def commit(%__MODULE__{status: :collecting} = buffer, opts) do
    entry = %Entry{
      body: buffer.chunks |> Enum.reverse() |> IO.iodata_to_binary(),
      content_type: buffer.content_type,
      headers: buffer.headers,
      created_at: DateTime.utc_now()
    }

    Telemetry.span(Telemetry.telemetry_opts(opts), [:cache, :write], %{}, fn ->
      result = Cache.put(buffer.key, entry, opts)
      {:ok, write_stop_metadata(result, buffer)}
    end)

    :ok
  end

  @spec abandon(t() | nil, atom(), keyword()) :: :ok
  def abandon(nil, _reason, _opts), do: :ok
  def abandon(%__MODULE__{status: :dropped}, _reason, _opts), do: :ok

  def abandon(%__MODULE__{} = buffer, reason, opts) do
    Telemetry.span(Telemetry.telemetry_opts(opts), [:cache, :tee], %{}, fn ->
      {:ok,
       %{
         result: :ok,
         cache: :abandoned,
         reason: reason,
         output_format: buffer.output_format
       }}
    end)

    :ok
  end

  defp too_large?(_size, nil), do: false
  defp too_large?(size, max_body_bytes), do: size > max_body_bytes

  defp drop(%__MODULE__{} = buffer),
    do: %{buffer | status: :dropped, chunks: [], size: 0}

  defp emit_drop_once(%__MODULE__{emitted_drop?: true} = buffer, _opts), do: buffer

  defp emit_drop_once(%__MODULE__{} = buffer, opts) do
    Telemetry.span(Telemetry.telemetry_opts(opts), [:cache, :tee], %{}, fn ->
      {:ok,
       %{
         result: :ok,
         cache: :write_skipped,
         reason: :too_large,
         output_format: buffer.output_format
       }}
    end)

    %{buffer | emitted_drop?: true}
  end

  defp write_stop_metadata(:ok, %__MODULE__{} = buffer),
    do: %{result: :ok, cache: :write, output_format: buffer.output_format}

  defp write_stop_metadata(:skipped, %__MODULE__{} = buffer),
    do: %{result: :ok, cache: :write_skipped, output_format: buffer.output_format}

  defp write_stop_metadata({:ok, {:cache_write, error}}, %__MODULE__{} = buffer),
    do: %{
      result: :cache_error,
      cache: :write_error,
      error: Telemetry.error(error),
      output_format: buffer.output_format
    }

  defp write_stop_metadata({:error, {:cache_write, error}}, %__MODULE__{} = buffer),
    do: %{
      result: :cache_error,
      cache: :write_error,
      error: Telemetry.error(error),
      output_format: buffer.output_format
    }
end
