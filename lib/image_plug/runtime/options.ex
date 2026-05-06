defmodule ImagePlug.Runtime.Options do
  @moduledoc false

  alias ImagePlug.Cache

  @parser_visible_option_keys [:parser, :root_url, :now]
  @options_schema NimbleOptions.new!(
                    parser: [type: :atom, required: true],
                    root_url: [type: :string, required: true],
                    now: [type: {:custom, __MODULE__, :validate_now, []}]
                  )

  def validate!(opts) do
    opts
    |> Cache.validate_config!()
    |> validate_known_opts!()
  end

  @doc false
  def validate_now(now) when is_integer(now), do: {:ok, now}
  def validate_now(%DateTime{} = now), do: {:ok, now}
  def validate_now(now) when is_function(now, 0), do: {:ok, now}

  def validate_now(_now),
    do: {:error, "expected integer Unix timestamp, DateTime, or zero-arity function"}

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
