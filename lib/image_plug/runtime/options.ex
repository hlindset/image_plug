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
        opts

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError, "invalid ImagePlug options: #{Exception.message(error)}"
    end
  end
end
