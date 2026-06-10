defmodule ImagePipe.Telemetry.Trace.OpenTelemetryExporter do
  @moduledoc """
  Opt-in `ImagePipe.Telemetry.Trace.Exporter` that replays finished `%Trace.Span{}`
  structs into a host-running OpenTelemetry SDK using the **public** OTel API.

  Correlation is **trace-level**: logs (`LogExporter`) and OTel spans share the
  `trace_id`, not the `span_id` (OTel mints its own). We force our `trace_id` onto
  each span via a synthetic W3C `traceparent` remote parent; the span's own id is
  OTel's. No SDK internals.

  Optional dependency `:opentelemetry_api` (compile); the host brings the SDK
  (`:opentelemetry`) and starts it. When the API is absent, `ready?/0` is `false`
  and `attach_tracer/1` raises. When the API is present but the SDK isn't started,
  the API degrades to a noop tracer and this produces nothing — no crash.
  """
  @behaviour ImagePipe.Telemetry.Trace.Exporter

  alias ImagePipe.Telemetry.Trace.Span

  # Span operations use the Elixir OTel API (`OpenTelemetry.Span` / `OpenTelemetry`);
  # starting a span and the traceparent setup in `parent_ctx/1` fall back to the
  # Erlang API (rationale at the call sites). All of these reference the optional
  # `:opentelemetry_api` and are runtime-guarded by `@otel_api_loaded`; when it is
  # absent they never run, so the undefined-module warnings are suppressed here.
  @compile {:no_warn_undefined,
            [
              OpenTelemetry,
              OpenTelemetry.Span,
              :opentelemetry,
              :otel_tracer,
              :otel_ctx,
              :otel_propagator_text_map,
              :otel_propagator_trace_context
            ]}

  @otel_api_loaded Code.ensure_loaded?(:otel_tracer)

  @doc "Whether the OpenTelemetry API is compiled in."
  @spec available?() :: boolean()
  def available?, do: @otel_api_loaded

  @impl true
  @spec ready?() :: boolean()
  def ready?, do: @otel_api_loaded

  @impl true
  @spec export(Span.t()) :: :ok
  def export(%Span{} = span) do
    if @otel_api_loaded do
      do_export(span)
    else
      :ok
    end
  end

  defp do_export(%Span{} = span) do
    offset = :erlang.time_offset()
    native_start = (span.start_time || 0) - offset
    native_end = native_start + (span.duration_native || 0)

    tracer = :opentelemetry.get_application_tracer(__MODULE__)
    ctx = parent_ctx(span)

    # Erlang API: the Elixir `OpenTelemetry.Tracer.start_span` is a macro, which
    # would need `require OpenTelemetry.Tracer` — impossible to do conditionally
    # for an optional dep. Call its expansion (`:otel_tracer.start_span/4`) directly.
    span_ctx =
      :otel_tracer.start_span(ctx, tracer, span.name, %{
        start_time: native_start,
        kind: kind(span.kind),
        attributes: attributes(span),
        links: []
      })

    maybe_set_status(span_ctx, span)

    case events(span, native_end) do
      [] -> :ok
      evs -> OpenTelemetry.Span.add_events(span_ctx, evs)
    end

    OpenTelemetry.Span.end_span(span_ctx, native_end)
    :ok
  end

  # Force OUR trace_id via a synthetic remote parent. Root (nil parent) uses its
  # own span_id as the (dangling) synthetic parent. -01 sampled flag is mandatory.
  defp parent_ctx(%Span{trace_id: trace, parent_span_id: parent, span_id: own}) do
    parent_hex = parent || own
    traceparent = "00-#{trace}-#{parent_hex}-01"

    # Erlang API: the W3C propagator and context modules have no Elixir wrapper.
    :otel_propagator_text_map.extract_to(
      :otel_ctx.new(),
      :otel_propagator_trace_context,
      [{"traceparent", traceparent}]
    )
  end

  defp kind(k) when k in [:internal, :server, :client], do: k
  defp kind(_), do: :internal

  # Only an error span gets a status set; success/unset spans keep OTel's default
  # UNSET — the idiomatic OTel representation of "completed, no error" (which is
  # what #175's :ok semantically means; capture.ex sets :ok for result :ok OR nil).
  # Setting OTel OK would over-claim an explicit success override.
  defp maybe_set_status(span_ctx, %Span{status: :error} = span) do
    OpenTelemetry.Span.set_status(
      span_ctx,
      OpenTelemetry.status(:error, span.status_message || "")
    )
  end

  defp maybe_set_status(_span_ctx, _span), do: :ok

  defp attributes(%Span{} = span) do
    span.attributes
    |> coerce_map()
    |> put_present("image_pipe.pid", span.pid, &inspect/1)
    |> put_present("image_pipe.node", span.node, &Atom.to_string/1)
  end

  # Oneshot event :time is raw monotonic — pass through UNCONVERTED. Exception
  # event (no :time) uses native_end (same frame as the span). event/3 is
  # timestamp-FIRST.
  defp events(%Span{events: events}, native_end) do
    Enum.map(events, fn ev ->
      ts = Map.get(ev, :time) || native_end
      OpenTelemetry.event(ts, ev[:name], event_attrs(ev))
    end)
  end

  # #175's exception event: %{name: "exception", attributes: %{kind:, reason:}}.
  defp event_attrs(%{name: "exception", attributes: a}) do
    %{"exception.type" => to_str(a[:kind]), "exception.message" => to_str(a[:reason])}
  end

  defp event_attrs(ev), do: coerce_map(Map.get(ev, :attributes, %{}))

  defp put_present(map, _key, nil, _fun), do: map
  defp put_present(map, key, value, fun), do: Map.put(map, key, fun.(value))

  # OTel attribute values must be primitives; the public set path silently DROPS
  # others, so coerce to keep them. Sensitivity handled upstream by Capture.safe_attrs/1.
  defp coerce_map(map) do
    map
    |> Enum.flat_map(fn {k, v} ->
      case coerce(v) do
        :__drop__ -> []
        cv -> [{k, cv}]
      end
    end)
    |> Map.new()
  end

  defp coerce(nil), do: :__drop__
  defp coerce(v) when is_boolean(v), do: v
  defp coerce(v) when is_number(v) or is_binary(v), do: v
  defp coerce(v) when is_atom(v), do: Atom.to_string(v)

  defp coerce(v) when is_list(v) do
    if Enum.all?(v, &scalar_primitive?/1) do
      Enum.map(v, &list_elem/1)
    else
      inspect(v)
    end
  end

  defp coerce(v), do: inspect(v)

  defp scalar_primitive?(v), do: is_binary(v) or is_atom(v) or is_number(v)

  defp list_elem(v) when is_binary(v), do: v
  defp list_elem(v) when is_atom(v), do: Atom.to_string(v)
  defp list_elem(v) when is_number(v), do: to_string(v)

  defp to_str(nil), do: ""
  defp to_str(v) when is_binary(v), do: v
  defp to_str(v) when is_atom(v), do: Atom.to_string(v)
  defp to_str(v), do: inspect(v)
end
