defmodule ImagePlug.Parser.Imgproxy.Signature do
  @moduledoc false

  @imgproxy_schema NimbleOptions.new!(signature: [type: :keyword_list, required: false])

  @signature_schema NimbleOptions.new!(
                      keys: [type: {:list, :string}, default: []],
                      salts: [type: {:list, :string}, default: []],
                      signature_size: [type: :integer, default: 32],
                      trusted_signatures: [
                        type: {:custom, __MODULE__, :validate_trusted_signatures, []},
                        default: []
                      ]
                    )

  @enforce_keys [:mode, :key_salt_pairs, :signature_size, :trusted_signatures]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          mode: :disabled | :enabled,
          key_salt_pairs: [{binary(), binary()}],
          signature_size: 1..32,
          trusted_signatures: MapSet.t(String.t())
        }

  @spec disabled() :: t()
  def disabled do
    %__MODULE__{
      mode: :disabled,
      key_salt_pairs: [],
      signature_size: 32,
      trusted_signatures: MapSet.new()
    }
  end

  @spec validate_options!(keyword()) :: keyword()
  def validate_options!(imgproxy_opts) when is_list(imgproxy_opts) do
    with {:ok, validated} <- NimbleOptions.validate(imgproxy_opts, @imgproxy_schema) do
      Keyword.put(validated, :signature, normalize_signature!(Keyword.get(validated, :signature)))
    else
      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError, "invalid imgproxy config: #{Exception.message(error)}"
    end
  end

  def validate_options!(_imgproxy_opts),
    do: raise(ArgumentError, "invalid imgproxy options: expected a keyword list")

  @doc false
  def validate_trusted_signatures(values) when is_list(values) do
    case Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      true -> {:ok, values}
      false -> {:error, "trusted_signatures must be a list of non-empty strings"}
    end
  end

  def validate_trusted_signatures(_values),
    do: {:error, "trusted_signatures must be a list of non-empty strings"}

  # NimbleOptions rejects explicit `signature: nil`; this branch represents an absent key.
  defp normalize_signature!(nil), do: disabled()

  defp normalize_signature!(config) when is_list(config) do
    with {:ok, validated} <- NimbleOptions.validate(config, @signature_schema),
         {:ok, signature_size} <-
           validate_signature_size(Keyword.fetch!(validated, :signature_size)),
         {:ok, pairs} <-
           key_salt_pairs(
             Keyword.fetch!(validated, :keys),
             Keyword.fetch!(validated, :salts),
             Keyword.fetch!(validated, :trusted_signatures)
           ) do
      %__MODULE__{
        mode: :enabled,
        key_salt_pairs: pairs,
        signature_size: signature_size,
        trusted_signatures: MapSet.new(Keyword.fetch!(validated, :trusted_signatures))
      }
    else
      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError, "invalid imgproxy signature config: #{Exception.message(error)}"

      {:error, reason} ->
        raise ArgumentError, "invalid imgproxy signature config: #{reason}"
    end
  end

  defp normalize_signature!(_config),
    do:
      raise(ArgumentError, "invalid imgproxy signature config: signature must be a keyword list")

  defp validate_signature_size(value) when value in 1..32, do: {:ok, value}

  defp validate_signature_size(_value),
    do: {:error, "signature_size must be an integer from 1 to 32"}

  defp key_salt_pairs(keys, salts, _trusted_signatures) when length(keys) != length(salts),
    do: {:error, "keys and salts must have the same length"}

  defp key_salt_pairs([], [], []),
    do: {:error, "at least one key/salt pair or trusted signature is required"}

  defp key_salt_pairs([], [], _trusted_signatures), do: {:ok, []}

  defp key_salt_pairs(keys, salts, _trusted_signatures) do
    keys
    |> Enum.zip(salts)
    |> Enum.reduce_while({:ok, []}, fn {key, salt}, {:ok, pairs} ->
      with {:ok, key} <- decode_hex(key),
           {:ok, salt} <- decode_hex(salt) do
        {:cont, {:ok, [{key, salt} | pairs]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_hex(value) do
    case Base.decode16(value, case: :mixed) do
      {:ok, ""} -> {:error, "keys and salts must be non-empty hex-encoded strings"}
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, "keys and salts must be non-empty hex-encoded strings"}
    end
  end
end
