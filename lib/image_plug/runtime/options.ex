defmodule ImagePlug.Runtime.Options do
  @moduledoc false

  alias ImagePlug.Cache

  @parser_visible_option_keys [:parser, :root_url, :clock]
  @options_schema NimbleOptions.new!(
                    parser: [type: :atom, required: true],
                    root_url: [type: :string, required: true],
                    clock: [type: {:custom, __MODULE__, :validate_clock, []}]
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
