defmodule ImagePipe.Request.Runner do
  @moduledoc false

  alias ImagePipe.Cache
  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.Key
  alias ImagePipe.Error
  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Response
  alias ImagePipe.Request.SourceSession
  alias ImagePipe.Request.SourceSession.Prepared, as: SessionPrepared
  alias ImagePipe.Request.SourceSession.Request, as: SessionRequest
  alias ImagePipe.Request.SourceSessionSupervisor
  alias ImagePipe.Response.PreparedStream
  alias ImagePipe.Source
  alias ImagePipe.Telemetry

  @type delivery() ::
          {:cache_entry, Entry.t(), Response.t()}
          | {:prepared_stream, PreparedStream.t(), Response.t()}

  @type error() ::
          {:cache, term()}
          | {:processing, term(), [{String.t(), String.t()}]}

  @spec run(
          Plug.Conn.t(),
          Plan.t(),
          Source.Resolved.t(),
          keyword()
        ) ::
          {:ok, delivery()} | {:error, error()}
  def run(conn, %Plan{} = plan, %Source.Resolved{} = resolved_source, opts) do
    run_with_cache_config(conn, plan, resolved_source, opts)
  end

  defp run_with_cache_config(conn, plan, %Source.Resolved{cache: :skip} = resolved_source, opts),
    do: process_prepared_stream(conn, plan, resolved_source, nil, opts)

  defp run_with_cache_config(conn, plan, %Source.Resolved{cache: :normal} = resolved_source, opts) do
    telemetry_opts = Telemetry.telemetry_opts(opts)

    result =
      Telemetry.span(telemetry_opts, [:cache, :lookup], cache_lookup_metadata(opts), fn ->
        result =
          case Keyword.get(opts, :cache) do
            nil -> :disabled
            _cache -> Cache.lookup(conn, plan, resolved_source.identity, opts)
          end

        {result, cache_lookup_stop_metadata(result)}
      end)

    case result do
      :disabled ->
        process_prepared_stream(conn, plan, resolved_source, nil, opts)

      {:hit, %Key{}, %Entry{} = entry} ->
        {:ok, {:cache_entry, entry, plan.response}}

      {:miss, %Key{} = key} ->
        process_cacheable_miss(conn, plan, resolved_source, key, opts)

      {:miss, %Key{} = key, {:cache_read, _error}} ->
        process_cacheable_miss(conn, plan, resolved_source, key, opts)

      {:error, {:cache_read, error}} ->
        {:error, {:cache, error}}
    end
  end

  defp process_cacheable_miss(conn, plan, resolved_source, %Key{} = key, opts) do
    process_prepared_stream(conn, plan, resolved_source, key, opts)
  end

  defp process_prepared_stream(conn, plan, resolved_source, cache_key, opts) do
    policy = Policy.from_output_plan(conn, plan.output, opts)

    request = %SessionRequest{
      plan: plan,
      resolved_source: resolved_source,
      output_policy: policy,
      opts: opts,
      cache_key: cache_key
    }

    supervisor = Keyword.get(opts, :source_session_supervisor, SourceSessionSupervisor)

    case SourceSessionSupervisor.start_session(supervisor, request) do
      {:ok, session} ->
        prepare_supervised_session(session, supervisor, plan.response, policy)

      {:error, reason} ->
        {:error, {:processing, normalize_session_prepare_error(reason), policy.headers}}
    end
  end

  defp prepare_supervised_session(session, supervisor, %Response{} = response, %Policy{} = policy) do
    case SourceSession.prepare(session) do
      {:ok, %SessionPrepared{} = prepared} ->
        case prepared_stream(session, supervisor, prepared, response) do
          {:ok, %PreparedStream{} = prepared_stream} ->
            {:ok, {:prepared_stream, prepared_stream, response}}

          {:error, reason} ->
            _stop_result = SourceSessionSupervisor.stop_session(supervisor, session)
            {:error, {:processing, normalize_session_prepare_error(reason), policy.headers}}
        end

      {:error, reason} ->
        _stop_result = SourceSessionSupervisor.stop_session(supervisor, session)
        {:error, {:processing, normalize_session_prepare_error(reason), policy.headers}}
    end
  end

  defp prepared_stream(session, supervisor, %SessionPrepared{} = prepared, %Response{} = response) do
    with :ok <- check_first_chunk(prepared.first_chunk),
         {:ok, content_disposition} <-
           Response.content_disposition(response, prepared.content_type) do
      {:ok,
       %PreparedStream{
         first_chunk: prepared.first_chunk,
         content_type: prepared.content_type,
         headers: prepared.headers ++ [{"content-disposition", content_disposition}],
         next: fn -> SourceSession.next(session) end,
         cancel: fn -> cancel_supervised_session(supervisor, session) end,
         resolved_output: prepared.resolved_output
       }}
    else
      {:error, reason} ->
        _cancel_result = SourceSession.cancel(session)
        {:error, reason}
    end
  end

  defp cancel_supervised_session(supervisor, session) do
    result = SourceSession.cancel(session)
    _stop_result = SourceSessionSupervisor.stop_session(supervisor, session)

    result
  end

  defp check_first_chunk(chunk) when is_binary(chunk) and byte_size(chunk) > 0, do: :ok

  defp check_first_chunk(_chunk) do
    {:error, {:encode, :empty_stream}}
  end

  defp normalize_session_prepare_error({:session, reason}) do
    {:encode, RuntimeError.exception("source session failed: #{inspect(reason)}"), []}
  end

  defp normalize_session_prepare_error(reason), do: reason

  defp cache_lookup_metadata(opts) do
    cache =
      case Keyword.get(opts, :cache) do
        nil -> :disabled
        _cache -> nil
      end

    %{cache: cache}
  end

  defp cache_lookup_stop_metadata(:disabled), do: %{result: :ok, cache: :disabled}
  defp cache_lookup_stop_metadata({:hit, %Key{}, %Entry{}}), do: %{result: :ok, cache: :hit}
  defp cache_lookup_stop_metadata({:miss, %Key{}}), do: %{result: :ok, cache: :miss}

  defp cache_lookup_stop_metadata({:miss, %Key{}, {:cache_read, error}}),
    do: %{result: :cache_error, cache: :read_error, error: Error.tag(error)}

  defp cache_lookup_stop_metadata({:error, {:cache_read, error}}),
    do: %{result: :cache_error, cache: :read_error, error: Error.tag(error)}
end
