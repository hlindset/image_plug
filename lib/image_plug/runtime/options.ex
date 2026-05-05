defmodule ImagePlug.Runtime.Options do
  @moduledoc false

  alias ImagePlug.Cache

  @required_options_schema NimbleOptions.new!(
                             parser: [type: :atom, required: true],
                             root_url: [type: :string, required: true]
                           )

  def validate!(opts) do
    opts
    |> Cache.validate_config!()
    |> validate_required_opts!()
  end

  defp validate_required_opts!(opts) do
    required_opts = Keyword.take(opts, [:parser, :root_url])

    case NimbleOptions.validate(required_opts, @required_options_schema) do
      {:ok, _validated_opts} ->
        validate_parser!(opts)

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError, "invalid ImagePlug options: #{Exception.message(error)}"
    end
  end

  defp validate_parser!(opts) do
    parser = Keyword.fetch!(opts, :parser)

    with {:module, ^parser} <- Code.ensure_loaded(parser),
         true <- function_exported?(parser, :parse, 1),
         true <- function_exported?(parser, :handle_error, 2) do
      opts
    else
      {:error, reason} ->
        raise ArgumentError,
              "invalid ImagePlug parser #{inspect(parser)}: module could not be loaded (#{inspect(reason)})"

      false ->
        raise ArgumentError,
              "invalid ImagePlug parser #{inspect(parser)}: expected parse/1 and handle_error/2"
    end
  end
end
