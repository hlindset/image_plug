defmodule ImagePlug.Request.Options do
  @moduledoc false

  alias ImagePlug.Cache
  alias ImagePlug.Telemetry

  @parser_visible_option_keys [:parser, :root_url, :clock, :telemetry_prefix]
  @options_schema NimbleOptions.new!(
                    parser: [type: :atom, required: true],
                    root_url: [type: :string, required: true],
                    clock: [type: {:custom, __MODULE__, :validate_clock, []}],
                    telemetry_prefix: [
                      type: {:custom, __MODULE__, :validate_telemetry_prefix, []},
                      default: Telemetry.default_prefix()
                    ]
                  )

  def validate!(opts) do
    opts
    |> Cache.validate_config!()
    |> validate_known_opts!()
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
    known_opts = Keyword.take(opts, @parser_visible_option_keys)

    case NimbleOptions.validate(known_opts, @options_schema) do
      {:ok, validated_opts} ->
        Keyword.merge(opts, validated_opts)

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError, "invalid ImagePlug options: #{Exception.message(error)}"
    end
  end
end
