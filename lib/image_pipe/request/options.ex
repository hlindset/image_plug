defmodule ImagePipe.Request.Options do
  @moduledoc false

  alias ImagePipe.Cache
  alias ImagePipe.Source
  alias ImagePipe.Telemetry

  @validated_option_keys [:parser, :clock, :telemetry_prefix, :http_cache]
  @stale_origin_option_keys [
    :root_url,
    :origin_req_options,
    :origin_receive_timeout,
    :origin_max_redirects
  ]
  @source_runtime_option_keys [
    :max_body_bytes,
    :receive_timeout,
    :connect_timeout,
    :pool_timeout,
    :request_id,
    :telemetry_prefix
  ]
  @options_schema NimbleOptions.new!(
                    parser: [type: :atom, required: true],
                    clock: [type: {:custom, __MODULE__, :validate_clock, []}],
                    telemetry_prefix: [
                      type: {:custom, __MODULE__, :validate_telemetry_prefix, []},
                      default: Telemetry.default_prefix()
                    ],
                    http_cache: [
                      type: :keyword_list,
                      default: [mode: :disabled],
                      keys: [
                        mode: [type: {:in, [:disabled, :enabled]}, default: :disabled]
                      ]
                    ]
                  )

  def validate!(opts) do
    opts
    |> Cache.validate_config!()
    |> Source.validate_config!()
    |> reject_stale_origin_opts!()
    |> validate_known_opts!()
  end

  def source_runtime_opts(opts) when is_list(opts) do
    Keyword.take(opts, @source_runtime_option_keys)
  end

  @doc false
  def validate_clock(clock) when is_function(clock, 0), do: {:ok, clock}

  def validate_clock(_clock),
    do: {:error, "expected zero-arity function"}

  @doc false
  def validate_telemetry_prefix([prefix | _rest] = telemetry_prefix) when is_atom(prefix) do
    if Enum.all?(telemetry_prefix, &is_atom/1) do
      {:ok, telemetry_prefix}
    else
      {:error, "expected a non-empty list of atoms"}
    end
  end

  def validate_telemetry_prefix(_telemetry_prefix),
    do: {:error, "expected a non-empty list of atoms"}

  defp validate_known_opts!(opts) do
    known_opts = Keyword.take(opts, @validated_option_keys)

    case NimbleOptions.validate(known_opts, @options_schema) do
      {:ok, validated_opts} ->
        Keyword.merge(opts, validated_opts)

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError, "invalid ImagePipe options: #{Exception.message(error)}"
    end
  end

  defp reject_stale_origin_opts!(opts) do
    case Enum.find(@stale_origin_option_keys, &Keyword.has_key?(opts, &1)) do
      nil ->
        opts

      key ->
        raise ArgumentError, "invalid ImagePipe options: stale origin option #{inspect(key)}"
    end
  end
end
