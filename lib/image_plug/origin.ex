defmodule ImagePlug.Origin do
  @moduledoc """
  Origin URL construction and guarded HTTP streaming.

  Origin responses are fetched with a repo-owned `Req.get(..., into: :self)` request
  instead of `Image.from_req_stream/2`. That keeps ImagePlug in control of status and
  content-type validation, byte limits, redirect and timeout configuration, and the
  distinction between origin failures and image decode failures.

  Successful fetches return a guarded enumerable in `Response.stream`. Consumers should
  either consume that stream or call `close/1`. Stream-time origin failures are sent back
  to the caller out-of-band because Vix consumes enumerables from a separate process.
  """

  alias ImagePlug.Origin.StreamStatus

  defmodule Response do
    @moduledoc false

    @enforce_keys [:content_type, :headers, :ref, :stream, :stream_status, :url, :worker]
    defstruct [:content_type, :headers, :ref, :stream, :stream_status, :url, :worker]

    @type t() :: %__MODULE__{
            content_type: String.t() | nil,
            headers: [{String.t(), String.t()}],
            ref: reference(),
            stream: Enumerable.t(),
            stream_status: pid(),
            url: String.t(),
            worker: pid()
          }
  end

  @default_max_body_bytes 10_000_000
  @default_receive_timeout 5_000
  @default_max_redirects 3

  def build_url(root_url, path_segments) when is_binary(root_url) and is_list(path_segments) do
    root_uri = URI.parse(root_url)

    with :ok <- validate_root_url(root_uri, root_url),
         :ok <- validate_path_segments(path_segments) do
      {:ok, build_safe_url(root_uri, path_segments)}
    end
  end

  defp validate_root_url(root_uri, root_url) do
    if valid_root_url?(root_uri), do: :ok, else: {:error, {:invalid_root_url, root_url}}
  end

  defp validate_path_segments(path_segments) do
    if Enum.any?(path_segments, &(&1 in [".", ".."])),
      do: {:error, {:invalid_path_segment, path_segments}},
      else: :ok
  end

  defp build_safe_url(root_uri, path_segments) do
    root_path_segments = split_path(root_uri.path)

    encoded_path_segments =
      Enum.map(path_segments, fn segment ->
        URI.encode(segment, &URI.char_unreserved?/1)
      end)

    path = "/" <> Enum.join(root_path_segments ++ encoded_path_segments, "/")

    root_uri
    |> Map.put(:path, path)
    |> Map.put(:query, nil)
    |> Map.put(:fragment, nil)
    |> URI.to_string()
  end

  def fetch(url, req_options \\ []) when is_binary(url) and is_list(req_options) do
    max_body_bytes = Keyword.get(req_options, :max_body_bytes, @default_max_body_bytes)
    max_redirects = Keyword.get(req_options, :max_redirects, @default_max_redirects)
    receive_timeout = Keyword.get(req_options, :receive_timeout, @default_receive_timeout)

    request_options =
      req_options
      |> Keyword.delete(:max_body_bytes)
      |> Keyword.merge(
        url: url,
        into: :self,
        retry: false,
        redirect: true,
        max_redirects: max_redirects,
        receive_timeout: receive_timeout
      )

    start_stream(url, request_options, max_body_bytes, receive_timeout)
  end

  @doc """
  Returns the status of a guarded origin stream without consuming it more than once.
  """
  @spec stream_status(Response.t()) :: :pending | :done | {:error, term()}
  def stream_status(%Response{stream_status: stream_status})
      when is_pid(stream_status) do
    StreamStatus.get(stream_status)
  end

  @doc """
  Forces a pre-delivery stream status decision for sequential pipelines.
  """
  @spec require_stream_status(Response.t()) :: :done | {:error, term()}
  def require_stream_status(%Response{stream_status: stream_status} = response) do
    case stream_status(response) do
      :pending ->
        status =
          StreamStatus.put(stream_status, {:error, :stream_not_finished_after_materialization})

        close(response)
        status

      status ->
        status
    end
  end

  def close(%Response{ref: ref, worker: worker}) do
    send(worker, {:cancel, ref})
    :ok
  end

  defp valid_root_url?(%URI{scheme: scheme, host: host})
       when scheme in ["http", "https"] and is_binary(host) and host != "",
       do: true

  defp valid_root_url?(_root_uri), do: false

  defp split_path(nil), do: []
  defp split_path(""), do: []
  defp split_path(path), do: path |> String.trim("/") |> String.split("/", trim: true)

  defp start_stream(url, request_options, max_body_bytes, receive_timeout) do
    caller = self()
    ref = make_ref()
    {:ok, stream_status} = StreamStatus.start_link()

    {worker, monitor_ref} =
      spawn_monitor(fn ->
        stream_worker(
          caller,
          ref,
          url,
          request_options,
          max_body_bytes,
          receive_timeout,
          stream_status
        )
      end)

    receive do
      {^ref, {:ok, %Response{} = response}} ->
        Process.demonitor(monitor_ref, [:flush])

        {:ok,
         %Response{
           response
           | ref: ref,
             worker: worker,
             stream_status: stream_status,
             stream: response_stream(worker, ref)
         }}

      {^ref, {:error, reason}} ->
        StreamStatus.stop(stream_status)
        Process.demonitor(monitor_ref, [:flush])
        {:error, reason}

      {:DOWN, ^monitor_ref, :process, ^worker, reason} ->
        StreamStatus.stop(stream_status)
        {:error, {:transport, reason}}
    after
      receive_timeout ->
        Process.exit(worker, :kill)
        StreamStatus.stop(stream_status)
        Process.demonitor(monitor_ref, [:flush])
        {:error, {:timeout, receive_timeout}}
    end
  end

  defp validate_status(%Req.Response{status: status}) when status in 200..299, do: :ok
  defp validate_status(%Req.Response{status: status}), do: {:error, {:bad_status, status}}

  defp validate_content_type(%Req.Response{} = response) do
    content_type = response |> Req.Response.get_header("content-type") |> List.first()
    media_type = content_type |> normalize_content_type()

    if is_binary(media_type) and String.starts_with?(media_type, "image/") do
      {:ok, content_type}
    else
      {:error, {:bad_content_type, content_type}}
    end
  end

  defp normalize_content_type(content_type) when is_binary(content_type) do
    content_type
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_content_type(_content_type), do: nil

  defp response_headers(%Req.Response{headers: headers}) do
    Enum.flat_map(headers, fn {key, values} -> Enum.map(values, &{key, &1}) end)
  end

  defp stream_worker(
         caller,
         ref,
         url,
         request_options,
         max_body_bytes,
         receive_timeout,
         stream_status
       ) do
    caller_monitor_ref = Process.monitor(caller)

    case Req.get(request_options) do
      {:ok, %Req.Response{} = response} ->
        with :ok <- validate_status(response),
             {:ok, content_type} <- validate_content_type(response) do
          send(caller, {
            ref,
            {:ok,
             %Response{
               content_type: content_type,
               headers: response_headers(response),
               ref: nil,
               stream: nil,
               stream_status: nil,
               url: url,
               worker: nil
             }}
          })

          stream_loop(%{
            caller: caller,
            caller_monitor_ref: caller_monitor_ref,
            max_body_bytes: max_body_bytes,
            pending: [],
            receive_timeout: receive_timeout,
            ref: ref,
            response: response,
            size: 0,
            stream_status: stream_status
          })
        else
          {:error, reason} ->
            cancel_response(response)
            send(caller, {ref, {:error, reason}})
        end

      {:error, exception} ->
        send(caller, {ref, {:error, {:transport, exception}}})
    end
  end

  defp stream_loop(%{caller_monitor_ref: caller_monitor_ref, caller: caller, ref: ref} = state) do
    receive do
      {:next, from, ^ref} ->
        serve_next(from, state)

      {:cancel, ^ref} ->
        cancel_response(state.response)

      {:DOWN, ^caller_monitor_ref, :process, ^caller, _reason} ->
        cancel_response(state.response)
    after
      state.receive_timeout ->
        fail_idle_stream(state, {:timeout, state.receive_timeout})
    end
  end

  defp serve_next(from, %{pending: [pending | rest]} = state) do
    deliver_pending(pending, from, %{state | pending: rest})
  end

  defp serve_next(from, %{receive_timeout: receive_timeout} = state) do
    receive do
      {:cancel, ref} when ref == state.ref ->
        cancel_response(state.response)

      {:DOWN, monitor_ref, :process, caller, _reason}
      when monitor_ref == state.caller_monitor_ref and caller == state.caller ->
        cancel_response(state.response)

      message ->
        case Req.parse_message(state.response, message) do
          {:ok, parsed_chunks} ->
            pending = Enum.flat_map(parsed_chunks, &pending_chunk/1)
            serve_next(from, %{state | pending: pending})

          {:error, exception} ->
            fail_stream(from, state, {:transport, exception})

          :unknown ->
            serve_next(from, state)
        end
    after
      receive_timeout ->
        fail_stream(from, state, {:timeout, receive_timeout})
    end
  end

  defp pending_chunk({:data, data}), do: [{:data, data}]
  defp pending_chunk(:done), do: [:done]
  defp pending_chunk({:trailers, _trailers}), do: []

  defp deliver_pending({:data, data}, from, state) do
    size = state.size + byte_size(data)

    if is_integer(state.max_body_bytes) and size > state.max_body_bytes do
      fail_stream(from, state, {:body_too_large, state.max_body_bytes})
    else
      send(from, {state.ref, {:data, data}})
      stream_loop(%{state | size: size})
    end
  end

  defp deliver_pending(:done, from, state) do
    StreamStatus.put(state.stream_status, :done)
    send(from, {state.ref, :done})
  end

  defp fail_stream(from, state, reason) do
    reason = normalize_stream_error(reason, state.receive_timeout)

    StreamStatus.put(state.stream_status, {:error, reason})
    cancel_response(state.response)
    send(from, {state.ref, {:error, reason}})
  end

  defp fail_idle_stream(state, reason) do
    reason = normalize_stream_error(reason, state.receive_timeout)

    StreamStatus.put(state.stream_status, {:error, reason})
    cancel_response(state.response)
  end

  defp normalize_stream_error(
         {:transport, %Mint.TransportError{reason: :timeout}},
         receive_timeout
       ) do
    {:timeout, receive_timeout}
  end

  defp normalize_stream_error(reason, _receive_timeout), do: reason

  defp response_stream(worker, ref) do
    Stream.resource(
      fn -> %{monitor_ref: Process.monitor(worker), ref: ref, worker: worker} end,
      fn state ->
        send(state.worker, {:next, self(), state.ref})

        receive do
          {ref, {:data, data}} when ref == state.ref ->
            {[data], state}

          {ref, :done} when ref == state.ref ->
            {:halt, state}

          {ref, {:error, _reason}} when ref == state.ref ->
            {:halt, state}

          {:DOWN, monitor_ref, :process, worker, _reason}
          when monitor_ref == state.monitor_ref and worker == state.worker ->
            {:halt, state}
        end
      end,
      fn state ->
        send(state.worker, {:cancel, state.ref})
        Process.demonitor(state.monitor_ref, [:flush])
      end
    )
  end

  defp cancel_response(%Req.Response{} = response) do
    Req.cancel_async_response(response)
  rescue
    _ -> :ok
  end
end
