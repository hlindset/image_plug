# Imgproxy HMAC Signatures Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add imgproxy-compatible HMAC URL signature verification, including trusted signatures, as an imgproxy parser-only feature.

**Architecture:** Signature configuration and verification live under `ImagePlug.Parser.Imgproxy.*`. `ImagePlug.init/1` keeps core/cache option validation in `ImagePlug.Request.Options`, then dispatches imgproxy-owned option validation from the top-level `ImagePlug` module where parser dependencies are already allowed. Verified signatures authorize parsing only; signature strings never enter `ImagePlug.Plan`, cache keys, request execution, origin, response, output, or transform boundaries.

**Tech Stack:** Elixir, Plug, ExUnit, NimbleOptions, `:crypto.mac/4`, URL-safe Base64, `Plug.Crypto.secure_compare/2`, Boundary.

---

## File Structure

- Modify `lib/image_plug.ex`: dispatch imgproxy option validation during Plug initialization.
- Modify `lib/image_plug/parser/imgproxy.ex`: expose imgproxy option validation, build slash-preserving raw signed paths, and verify signatures before option/source parsing.
- Create `lib/image_plug/parser/imgproxy/signature.ex`: own imgproxy signature config normalization and request-time verification.
- Create `test/parser/imgproxy/signature_test.exs`: cover config validation and upstream compatibility vectors.
- Modify `test/parser/imgproxy_test.exs`: cover signed parser URLs, disabled-signing compatibility, raw slash sensitivity, and trusted-signature parser behavior.
- Modify `test/image_plug_test.exs`: cover `ImagePlug.init/1` parser option validation and ensure non-imgproxy test parsers remain unaffected.
- Modify `test/image_plug/request_safety_test.exs`: prove invalid signatures return before origin identity, cache lookup, and origin fetch.
- Modify `test/image_plug/cache/key_test.exs`: prove HMAC and trusted signatures for the same canonical request share cache identity.
- Modify `README.md`: document signing configuration and disabled-signing behavior.
- Modify `docs/imgproxy_path_api.md`: document signature verification semantics.
- Modify `docs/imgproxy_support_matrix.md`: update required signature and HMAC signature rows.

## Task 1: Add Imgproxy Signature Config Normalization

**Files:**
- Create: `lib/image_plug/parser/imgproxy/signature.ex`
- Modify: `lib/image_plug/parser/imgproxy.ex`
- Create: `test/parser/imgproxy/signature_test.exs`

- [ ] **Step 1: Write failing config tests**

Create `test/parser/imgproxy/signature_test.exs`:

```elixir
defmodule ImagePlug.Parser.Imgproxy.SignatureTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Parser.Imgproxy.Signature

  describe "validate_options!/1" do
    test "returns disabled config when imgproxy signature config is absent" do
      assert [signature: %Signature{mode: :disabled, key_salt_pairs: [], signature_size: 32}] =
               Signature.validate_options!([])
    end

    test "normalizes hex key and salt pairs" do
      assert [
               signature: %Signature{
                 mode: :enabled,
                 key_salt_pairs: [{"test-key", "test-salt"}],
                 signature_size: 8,
                 trusted_signatures: trusted_signatures
               }
             ] =
               Signature.validate_options!(
                 signature: [
                   keys: ["746573742d6b6579"],
                   salts: ["746573742d73616c74"],
                   signature_size: 8,
                   trusted_signatures: ["local-dev!"]
                 ]
               )

      assert MapSet.equal?(trusted_signatures, MapSet.new(["local-dev!"]))
    end

    test "rejects unknown signature options" do
      assert_raise ArgumentError, ~r/unknown options.*:trusted_signature/, fn ->
        Signature.validate_options!(
          signature: [
            keys: ["74657374"],
            salts: ["73616c74"],
            trusted_signature: ["typo"]
          ]
        )
      end
    end

    test "rejects unknown top-level imgproxy options" do
      assert_raise ArgumentError, ~r/unknown options.*:trusted_signatures/, fn ->
        Signature.validate_options!(trusted_signatures: ["local-dev!"])
      end

      assert_raise ArgumentError, ~r/unknown options.*:keys/, fn ->
        Signature.validate_options!(keys: ["74657374"], salts: ["73616c74"])
      end
    end

    test "rejects explicit nil signature config" do
      assert_raise ArgumentError, ~r/invalid value for :signature option/, fn ->
        Signature.validate_options!(signature: nil)
      end
    end

    test "rejects empty signing config" do
      assert_raise ArgumentError, ~r/at least one key\/salt pair or trusted signature is required/, fn ->
        Signature.validate_options!(signature: [keys: [], salts: []])
      end
    end

    test "supports trusted-only signing config" do
      assert [
               signature: %Signature{
                 mode: :enabled,
                 key_salt_pairs: [],
                 trusted_signatures: trusted_signatures
               }
             ] = Signature.validate_options!(signature: [trusted_signatures: ["local-dev!"]])

      assert MapSet.equal?(trusted_signatures, MapSet.new(["local-dev!"]))
    end

    test "rejects mismatched key and salt counts" do
      assert_raise ArgumentError, ~r/keys and salts must have the same length/, fn ->
        Signature.validate_options!(signature: [keys: ["74657374"], salts: []])
      end
    end

    test "rejects malformed hex key and salt values" do
      for config <- [
            [keys: ["not-hex"], salts: ["74657374"]],
            [keys: ["74657374"], salts: ["not-hex"]],
            [keys: [""], salts: ["74657374"]],
            [keys: ["74657374"], salts: [""]]
          ] do
        assert_raise ArgumentError, ~r/keys and salts must be non-empty hex-encoded strings/, fn ->
          Signature.validate_options!(signature: config)
        end
      end
    end

    test "rejects signature sizes outside 1..32" do
      for signature_size <- [0, 33] do
        assert_raise ArgumentError, ~r/signature_size must be an integer from 1 to 32/, fn ->
          Signature.validate_options!(
            signature: [
              keys: ["74657374"],
              salts: ["73616c74"],
              signature_size: signature_size
            ]
          )
        end
      end

      assert_raise ArgumentError, ~r/invalid value for :signature_size option/, fn ->
        Signature.validate_options!(
          signature: [
            keys: ["74657374"],
            salts: ["73616c74"],
            signature_size: "8"
          ]
        )
      end
    end

    test "rejects malformed trusted signatures" do
      for trusted_signatures <- ["local-dev", [""], [:not_binary]] do
        assert_raise ArgumentError, ~r/trusted_signatures must be a list of non-empty strings/, fn ->
          Signature.validate_options!(
            signature: [
              keys: ["74657374"],
              salts: ["73616c74"],
              trusted_signatures: trusted_signatures
            ]
          )
        end
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
mise exec -- mix test test/parser/imgproxy/signature_test.exs
```

Expected: compile failure because `ImagePlug.Parser.Imgproxy.Signature` does not exist.

- [ ] **Step 3: Implement signature config module with NimbleOptions**

Create `lib/image_plug/parser/imgproxy/signature.ex`:

```elixir
defmodule ImagePlug.Parser.Imgproxy.Signature do
  @moduledoc false

  @imgproxy_schema NimbleOptions.new!(
                     signature: [type: :keyword_list, required: false]
                   )

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
      Keyword.put(validated, :signature, normalize_signature!(validated[:signature]))
    else
      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError, "invalid imgproxy config: #{Exception.message(error)}"
    end
  end

  def validate_options!(_imgproxy_opts),
    do: raise(ArgumentError, "invalid imgproxy options: expected a keyword list")

  @doc false
  def validate_trusted_signatures(values) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      {:ok, values}
    else
      {:error, "trusted_signatures must be a list of non-empty strings"}
    end
  end

  def validate_trusted_signatures(_values),
    do: {:error, "trusted_signatures must be a list of non-empty strings"}

  # NimbleOptions rejects explicit `signature: nil`; this branch represents an absent key.
  defp normalize_signature!(nil), do: disabled()

  defp normalize_signature!(config) when is_list(config) do
    with {:ok, validated} <- NimbleOptions.validate(config, @signature_schema),
         {:ok, signature_size} <- validate_signature_size(validated[:signature_size]),
         {:ok, pairs} <-
           key_salt_pairs(validated[:keys], validated[:salts], validated[:trusted_signatures]) do
      %__MODULE__{
        mode: :enabled,
        key_salt_pairs: pairs,
        signature_size: signature_size,
        trusted_signatures: MapSet.new(validated[:trusted_signatures])
      }
    else
      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError, "invalid imgproxy signature config: #{Exception.message(error)}"

      {:error, reason} ->
        raise ArgumentError, "invalid imgproxy signature config: #{reason}"
    end
  end

  defp normalize_signature!(_config),
    do: raise(ArgumentError, "invalid imgproxy signature config: signature must be a keyword list")

  defp validate_signature_size(value) when value in 1..32, do: {:ok, value}
  defp validate_signature_size(_value), do: {:error, "signature_size must be an integer from 1 to 32"}

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
```

- [ ] **Step 4: Expose imgproxy option validation**

In `lib/image_plug/parser/imgproxy.ex`, add the alias:

```elixir
alias ImagePlug.Parser.Imgproxy.Signature
```

Add this public function after `def parse(%Plug.Conn{} = conn), do: parse(conn, [])`:

```elixir
@doc false
def validate_options!(imgproxy_opts), do: Signature.validate_options!(imgproxy_opts)
```

- [ ] **Step 5: Run focused tests**

Run:

```bash
mise exec -- mix test test/parser/imgproxy/signature_test.exs --warnings-as-errors
```

Expected: all tests pass.

- [ ] **Step 6: Commit Task 1**

```bash
mise exec -- git add lib/image_plug/parser/imgproxy/signature.ex lib/image_plug/parser/imgproxy.ex test/parser/imgproxy/signature_test.exs
mise exec -- git commit -m "Add imgproxy signature configuration"
```

## Task 2: Validate Imgproxy Options From ImagePlug Init

**Files:**
- Modify: `lib/image_plug.ex`
- Modify: `test/image_plug_test.exs`

- [ ] **Step 1: Add failing init tests**

Add these tests to `test/image_plug_test.exs` near existing init option tests:

```elixir
test "init normalizes imgproxy signature options through the imgproxy parser" do
  opts =
    ImagePlug.init(
      parser: ImagePlug.Parser.Imgproxy,
      root_url: "http://origin.test",
      imgproxy: [
        signature: [
          keys: ["746573742d6b6579"],
          salts: ["746573742d73616c74"],
          signature_size: 8,
          trusted_signatures: ["local-dev!"]
        ]
      ]
    )

  assert %ImagePlug.Parser.Imgproxy.Signature{
           mode: :enabled,
           key_salt_pairs: [{"test-key", "test-salt"}],
           signature_size: 8
         } = get_in(opts, [:imgproxy, :signature])
end

test "init rejects malformed imgproxy signature options before requests" do
  assert_raise ArgumentError,
               ~r/invalid imgproxy signature config/,
               fn ->
                 ImagePlug.init(
                   parser: ImagePlug.Parser.Imgproxy,
                   root_url: "http://origin.test",
                   imgproxy: [
                     signature: [
                       keys: ["not-hex"],
                       salts: ["74657374"]
                     ]
                   ]
                 )
               end
end

test "init rejects unknown top-level imgproxy options before requests" do
  assert_raise ArgumentError,
               ~r/invalid imgproxy config: unknown options.*:trusted_signatures/,
               fn ->
                 ImagePlug.init(
                   parser: ImagePlug.Parser.Imgproxy,
                   root_url: "http://origin.test",
                   imgproxy: [trusted_signatures: ["local-dev!"]]
                 )
               end
end

test "init rejects explicit nil imgproxy signature config before requests" do
  assert_raise ArgumentError,
               ~r/invalid imgproxy config: invalid value for :signature option/,
               fn ->
                 ImagePlug.init(
                   parser: ImagePlug.Parser.Imgproxy,
                   root_url: "http://origin.test",
                   imgproxy: [signature: nil]
                 )
               end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
mise exec -- mix test test/image_plug_test.exs --warnings-as-errors
```

Expected: assertion failure because `ImagePlug.init/1` still returns raw `:imgproxy` options.

- [ ] **Step 3: Dispatch imgproxy validation from `ImagePlug.init/1`**

Change `init/1` in `lib/image_plug.ex` to:

```elixir
@impl Plug
def init(opts) do
  opts
  |> Options.validate!()
  |> validate_parser_options!()
end
```

Add this private function near the other private helpers:

```elixir
defp validate_parser_options!(opts) do
  case Keyword.fetch!(opts, :parser) do
    ImagePlug.Parser.Imgproxy ->
      imgproxy_opts =
        opts
        |> Keyword.get(:imgproxy, [])
        |> ImagePlug.Parser.Imgproxy.validate_options!()

      Keyword.put(opts, :imgproxy, imgproxy_opts)

    _parser ->
      opts
  end
end
```

- [ ] **Step 4: Run focused init tests**

Run:

```bash
mise exec -- mix test test/image_plug_test.exs --warnings-as-errors
```

Expected: all tests pass. The inline test parsers in `test/image_plug_test.exs` do not need new callbacks because parser option validation is an explicit `ImagePlug.Parser.Imgproxy` clause, not a required behaviour callback.

- [ ] **Step 5: Commit Task 2**

```bash
mise exec -- git add lib/image_plug.ex test/image_plug_test.exs
mise exec -- git commit -m "Validate imgproxy options during init"
```

## Task 3: Verify HMAC and Trusted Signatures

**Files:**
- Modify: `lib/image_plug/parser/imgproxy/signature.ex`
- Modify: `test/parser/imgproxy/signature_test.exs`

- [ ] **Step 1: Add failing upstream compatibility tests**

Append to `test/parser/imgproxy/signature_test.exs`:

```elixir
describe "verify/3" do
  test "accepts disabled-signing placeholders when signing is disabled" do
    config = Signature.disabled()

    assert :ok = Signature.verify("_", "/plain/images/cat.jpg", config)
    assert :ok = Signature.verify("unsafe", "/plain/images/cat.jpg", config)
    assert Signature.verify("signed-value", "/plain/images/cat.jpg", config) ==
             {:error, {:unsupported_signature, "signed-value"}}
  end

  test "matches upstream full and truncated primitive HMAC vectors" do
    [signature: full] =
      Signature.validate_options!(
        signature: [
          keys: ["746573742d6b6579"],
          salts: ["746573742d73616c74"]
        ]
      )

    [signature: truncated] =
      Signature.validate_options!(
        signature: [
          keys: ["746573742d6b6579"],
          salts: ["746573742d73616c74"],
          signature_size: 8
        ]
      )

    assert :ok = Signature.verify("dtLwhdnPPiu_epMl1LrzheLpvHas-4mwvY6L3Z8WwlY", "asd", full)
    assert :ok = Signature.verify("dtLwhdnPPis", "asd", truncated)
    assert Signature.verify("dtLwhdnPPis", "asd", full) == {:error, :invalid_signature}
  end

  test "matches upstream key rotation vectors" do
    [signature: config] =
      Signature.validate_options!(
        signature: [
          keys: ["746573742d6b6579", "746573742d6b657932"],
          salts: ["746573742d73616c74", "746573742d73616c7432"]
        ]
      )

    assert :ok = Signature.verify("dtLwhdnPPiu_epMl1LrzheLpvHas-4mwvY6L3Z8WwlY", "asd", config)
    assert :ok = Signature.verify("jbDffNPt1-XBgDccsaE-XJB9lx8JIJqdeYIZKgOqZpg", "asd", config)
  end

  test "accepts exact trusted signatures before Base64 decoding" do
    [signature: config] =
      Signature.validate_options!(
        signature: [
          trusted_signatures: ["truested", "local-dev!"]
        ]
      )

    assert :ok = Signature.verify("truested", "asd", config)
    assert :ok = Signature.verify("local-dev!", "/w:300/plain/images/cat.jpg", config)
    assert Signature.verify("untrusted", "asd", config) ==
             {:error, {:invalid_signature_encoding, "untrusted"}}

    assert Signature.verify("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "asd", config) ==
             {:error, :invalid_signature}
  end

  test "matches upstream processing handler request fixture" do
    [signature: config] =
      Signature.validate_options!(
        signature: [
          keys: ["746573742d6b6579"],
          salts: ["746573742d73616c74"]
        ]
      )

    signed_path = "/rs:fill:4:4/plain/local:///test1.png"

    assert :ok =
             Signature.verify(
               "My9d3xq_PYpVHsPrCyww0Kh1w5KZeZhIlWhsa4az1TI",
               signed_path,
               config
             )

    assert Signature.verify("unsafe", signed_path, config) == {:error, :invalid_signature}
  end

  test "matches public docs signing vector" do
    [signature: config] =
      Signature.validate_options!(
        signature: [
          keys: ["736563726574"],
          salts: ["68656c6c6f"]
        ]
      )

    signed_path =
      "/rs:fill:300:400:0/g:sm/aHR0cDovL2V4YW1w/bGUuY29tL2ltYWdl/cy9jdXJpb3NpdHku/anBn.png"

    assert :ok =
             Signature.verify(
               "oKfUtW34Dvo2BGQehJFR4Nr0_rIjOtdtzJ3QFsUcXH8",
               signed_path,
               config
             )
  end

  test "rejects malformed Base64 and wrong signatures" do
    [signature: config] =
      Signature.validate_options!(
        signature: [
          keys: ["746573742d6b6579"],
          salts: ["746573742d73616c74"]
        ]
      )

    assert Signature.verify("local-dev!", "/w:300/plain/images/cat.jpg", config) ==
             {:error, {:invalid_signature_encoding, "local-dev!"}}

    assert Signature.verify("dtLwhdnPPiu_epMl1LrzheLpvHas-4mwvY6L3Z8WwlY=", "asd", config) ==
             {:error, {:invalid_signature_encoding, "dtLwhdnPPiu_epMl1LrzheLpvHas-4mwvY6L3Z8WwlY="}}

    assert Signature.verify("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "/w:300/plain/images/cat.jpg", config) ==
             {:error, :invalid_signature}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
mise exec -- mix test test/parser/imgproxy/signature_test.exs --warnings-as-errors
```

Expected: compile failure because `Signature.verify/3` is undefined.

- [ ] **Step 3: Implement verification**

Add to `lib/image_plug/parser/imgproxy/signature.ex` before private config helpers:

```elixir
@spec verify(String.t(), binary(), t()) :: :ok | {:error, term()}
def verify(signature, _signed_path, %__MODULE__{mode: :disabled}) when signature in ["_", "unsafe"],
  do: :ok

def verify(signature, _signed_path, %__MODULE__{mode: :disabled}),
  do: {:error, {:unsupported_signature, signature}}

def verify(signature, signed_path, %__MODULE__{mode: :enabled} = config) do
  if MapSet.member?(config.trusted_signatures, signature) do
    :ok
  else
    verify_hmac_signature(signature, signed_path, config)
  end
end

defp verify_hmac_signature(signature, signed_path, %__MODULE__{} = config) do
  with {:ok, decoded_signature} <- decode_signature(signature),
       true <- matching_signature?(decoded_signature, signed_path, config) do
    :ok
  else
    {:error, _reason} = error -> error
    false -> {:error, :invalid_signature}
  end
end

defp decode_signature(signature) do
  if String.contains?(signature, "=") do
    {:error, {:invalid_signature_encoding, signature}}
  else
    case Base.url_decode64(signature, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, {:invalid_signature_encoding, signature}}
    end
  end
end

defp matching_signature?(decoded_signature, signed_path, %__MODULE__{} = config) do
  Enum.any?(config.key_salt_pairs, fn {key, salt} ->
    expected = signature_for(signed_path, key, salt, config.signature_size)

    byte_size(decoded_signature) == byte_size(expected) and
      Plug.Crypto.secure_compare(decoded_signature, expected)
  end)
end

defp signature_for(signed_path, key, salt, signature_size) do
  :hmac
  |> :crypto.mac(:sha256, key, salt <> signed_path)
  |> binary_part(0, signature_size)
end
```

- [ ] **Step 4: Run focused tests**

Run:

```bash
mise exec -- mix test test/parser/imgproxy/signature_test.exs --warnings-as-errors
```

Expected: all tests pass.

- [ ] **Step 5: Commit Task 3**

```bash
mise exec -- git add lib/image_plug/parser/imgproxy/signature.ex test/parser/imgproxy/signature_test.exs
mise exec -- git commit -m "Verify imgproxy request signatures"
```

## Task 4: Enforce Signatures in Imgproxy Parser

**Files:**
- Modify: `lib/image_plug/parser/imgproxy.ex`
- Modify: `test/parser/imgproxy_test.exs`

- [ ] **Step 1: Add failing parser tests**

Add these helpers and tests near the existing signature tests in `test/parser/imgproxy_test.exs`:

```elixir
defp signed_parser_opts(overrides \\ []) do
  imgproxy_opts =
    [signature: [keys: ["746573742d6b6579"], salts: ["746573742d73616c74"]]]
    |> Keyword.merge(overrides)
    |> ImagePlug.Parser.Imgproxy.validate_options!()

  [imgproxy: imgproxy_opts]
end

test "accepts valid signed imgproxy URLs when signing is enabled" do
  assert {:ok, %Plan{source: {:plain, ["images", "cat.jpg"]}}} =
           Imgproxy.parse(
             conn(
               :get,
               "/NSbxuO5fQqTgDkui_3o6ho1UCFFcmzsugB2Uksho49o/w:300/plain/images/cat.jpg"
             ),
             signed_parser_opts()
           )
end

test "signature verification excludes query strings" do
  assert {:ok, %Plan{source: {:plain, ["images", "cat.jpg"]}}} =
           Imgproxy.parse(
             conn(
               :get,
               "/NSbxuO5fQqTgDkui_3o6ho1UCFFcmzsugB2Uksho49o/w:300/plain/images/cat.jpg?ignored=true"
             ),
             signed_parser_opts()
           )
end

test "signature-only paths fail before verification" do
  assert Imgproxy.parse(conn(:get, "/invalid"), signed_parser_opts()) ==
           {:error, :missing_signed_path}

  assert Imgproxy.parse(conn(:get, "//w:300/plain/images/cat.jpg"), signed_parser_opts()) ==
           {:error, :missing_signature}
end

test "fixPath decodes option separators before verification and parsing" do
  assert {:ok, %Plan{source: {:plain, ["images", "cat.jpg"]}}} =
           Imgproxy.parse(
             conn(
               :get,
               "/NSbxuO5fQqTgDkui_3o6ho1UCFFcmzsugB2Uksho49o/w%3A300/plain/images/cat.jpg"
             ),
             signed_parser_opts()
           )
end

test "fixPath repairs normalized plain URL schemes before verification and parsing" do
  assert {:ok, %Plan{source: {:plain, ["http:", "", "example.com", "image.jpg"]}}} =
           Imgproxy.parse(
             conn(:get, "/rvUfkOxjt_gv1jphcFemDz8PPpIntOx93-72pYGwqV0/plain/http:/example.com/image.jpg"),
             signed_parser_opts()
           )

  assert {:ok, %Plan{source: {:plain, ["local:", "", "", "test1.png"]}}} =
           Imgproxy.parse(
             conn(:get, "/My9d3xq_PYpVHsPrCyww0Kh1w5KZeZhIlWhsa4az1TI/rs:fill:4:4/plain/local:/test1.png"),
             signed_parser_opts()
           )
end

test "rejects disabled-signing placeholders when signing is enabled" do
  assert Imgproxy.parse(conn(:get, "/_/plain/images/cat.jpg"), signed_parser_opts()) ==
           {:error, {:invalid_signature_encoding, "_"}}

  assert Imgproxy.parse(conn(:get, "/unsafe/plain/images/cat.jpg"), signed_parser_opts()) ==
           {:error, :invalid_signature}
end

test "accepts exact trusted signatures before HMAC decoding" do
  opts = signed_parser_opts(signature: [
    trusted_signatures: ["local-dev!"]
  ])

  assert {:ok, %Plan{source: {:plain, ["images", "cat.jpg"]}}} =
           Imgproxy.parse(conn(:get, "/local-dev!/w:300/plain/images/cat.jpg"), opts)
end

test "rejects invalid signature encodings before parsing options" do
  assert Imgproxy.parse(conn(:get, "/local-dev!/raw/plain/images/cat.jpg"), signed_parser_opts()) ==
           {:error, {:invalid_signature_encoding, "local-dev!"}}
end

test "raw signed path accepts signatures computed over duplicate slashes" do
  assert {:ok, %Plan{source: {:plain, ["", "images", "cat.jpg"]}}} =
           Imgproxy.parse(
             conn(:get, "/LybQypsQbz5rUNXKD0FkRZHzpY7OnbJ8DQcWndArBCw/w:300/plain//images/cat.jpg"),
             signed_parser_opts()
           )
end

test "raw signed path accepts signatures computed over trailing slashes" do
  assert {:ok, %Plan{source: {:plain, ["images", "cat.jpg", ""]}}} =
           Imgproxy.parse(
             conn(:get, "/gIg1_oHgCof_KbsU6mYJKyL-SN6TJjbHGQAd9uvh8GU/w:300/plain/images/cat.jpg/"),
             signed_parser_opts()
           )
end

test "raw signed path strips only mounted script_name before verification" do
  conn =
    conn(:get, "/proxy/NSbxuO5fQqTgDkui_3o6ho1UCFFcmzsugB2Uksho49o/w:300/plain/images/cat.jpg")
    |> Map.put(:script_name, ["proxy"])
    |> Map.put(:path_info, [
      "NSbxuO5fQqTgDkui_3o6ho1UCFFcmzsugB2Uksho49o",
      "w:300",
      "plain",
      "images",
      "cat.jpg"
    ])

  assert {:ok, %Plan{source: {:plain, ["images", "cat.jpg"]}}} =
           Imgproxy.parse(conn, signed_parser_opts())
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
mise exec -- mix test test/parser/imgproxy_test.exs --warnings-as-errors
```

Expected: signed URL test fails because parser still accepts only `_` and `unsafe`.

- [ ] **Step 3: Apply fixPath, then verify and parse from the same slash-preserving path**

In `lib/image_plug/parser/imgproxy.ex`, update `parse_request/2` so signature
verification and request parsing both use the same parser-visible path after
imgproxy-compatible `fixPath` normalization:

```elixir
def parse_request(%Plug.Conn{} = conn, opts) do
  with {:ok, signature, signed_path, path_info} <- parse_raw_path(conn),
       :ok <- verify_signature(signature, signed_path, opts),
       {:ok, option_segments, raw_source_path} <- split_source(path_info),
       {:ok, request_options} <- parse_request_options(option_segments),
       {:ok, source_path, source_format} <- parse_plain_source(raw_source_path) do
    parsed_request(
      signature,
      source_path,
      source_format,
      request_options
    )
  end
end
```

Replace the existing `validate_signature/1` helpers with:

```elixir
defp verify_signature(signature, signed_path, opts) do
  opts
  |> signature_config()
  |> then(&Signature.verify(signature, signed_path, &1))
end

defp signature_config(opts) do
  opts
  |> Keyword.get(:imgproxy, [])
  |> Keyword.get(:signature, Signature.disabled())
end

defp parse_raw_path(%Plug.Conn{} = conn) do
  case parser_request_path(conn) do
    "/" ->
      {:error, :missing_signature}

    "/" <> raw_path ->
      raw_path
      |> :binary.split("/", [:global])
      |> raw_path_parts()

    _path ->
      {:error, :missing_signature}
  end
end

defp parser_request_path(%Plug.Conn{request_path: request_path, script_name: []}), do: request_path

defp parser_request_path(%Plug.Conn{request_path: request_path, script_name: script_name}) do
  prefix = "/" <> Enum.join(script_name, "/")

  cond do
    request_path == prefix -> "/"
    String.starts_with?(request_path, prefix <> "/") -> String.replace_prefix(request_path, prefix, "")
    true -> request_path
  end
end

defp raw_path_parts(["" | _raw_path_info]), do: {:error, :missing_signature}
defp raw_path_parts([_signature]), do: {:error, :missing_signed_path}

defp raw_path_parts([signature | raw_path_info]) do
  signed_path =
    raw_path_info
    |> Enum.join("/")
    |> then(&("/" <> &1))
    |> fix_path()

  {:ok, signature, signed_path, path_info_from_signed_path(signed_path)}
end

defp path_info_from_signed_path(""), do: []
defp path_info_from_signed_path("/" <> path), do: :binary.split(path, "/", [:global])

defp fix_path(path) do
  case :binary.split(path, "/plain/") do
    [options, plain_url] ->
      fix_options_path(options) <> "/plain/" <> fix_plain_url_path(plain_url)

    [options] ->
      fix_options_path(options)
  end
end

defp fix_options_path(options), do: String.replace(options, "%3A", ":")

defp fix_plain_url_path(plain_url) do
  case Regex.run(~r/^(\S+):\/([^\/])/, plain_url) do
    [match, scheme, first] ->
      replacement =
        case scheme do
          "local" -> "local:///" <> first
          scheme -> scheme <> "://" <> first
        end

      String.replace_prefix(plain_url, match, replacement)

    nil ->
      plain_url
  end
end
```

- [ ] **Step 4: Return 403 for signature authorization failures**

In `lib/image_plug/parser/imgproxy.ex`, add signature-specific handling before
the generic parser error response:

```elixir
@impl ImagePlug.Parser
def handle_error(%Plug.Conn{} = conn, {:error, reason}) when reason in [:invalid_signature] do
  send_signature_error(conn, reason)
end

def handle_error(%Plug.Conn{} = conn, {:error, {:invalid_signature_encoding, _signature} = reason}) do
  send_signature_error(conn, reason)
end

def handle_error(%Plug.Conn{} = conn, {:error, {:unsupported_signature, _signature} = reason}) do
  send_signature_error(conn, reason)
end

def handle_error(%Plug.Conn{} = conn, {:error, reason}) do
  conn
  |> Plug.Conn.put_resp_content_type("text/plain")
  |> Plug.Conn.send_resp(400, "invalid image request: #{inspect(reason)}")
end

defp send_signature_error(%Plug.Conn{} = conn, reason) do
  conn
  |> Plug.Conn.put_resp_content_type("text/plain")
  |> Plug.Conn.send_resp(403, "invalid image request: #{inspect(reason)}")
end
```

- [ ] **Step 5: Run focused parser tests**

Run:

```bash
mise exec -- mix test test/parser/imgproxy_test.exs test/parser/imgproxy/signature_test.exs --warnings-as-errors
```

Expected: all tests pass.

- [ ] **Step 6: Commit Task 4**

```bash
mise exec -- git add lib/image_plug/parser/imgproxy.ex test/parser/imgproxy_test.exs
mise exec -- git commit -m "Enforce imgproxy signatures in parser"
```

## Task 5: Add Request Safety and Cache Identity Regression Coverage

**Files:**
- Modify: `test/image_plug/request_safety_test.exs`
- Modify: `test/image_plug/cache/key_test.exs`

- [ ] **Step 1: Add request safety regression coverage**

Append to `test/image_plug/request_safety_test.exs`:

```elixir
test "invalid imgproxy signatures return before source identity, cache lookup, and origin" do
  conn =
    ImagePlug.call(conn(:get, "/invalid/w:300/plain/images/cat.jpg"),
      ImagePlug.init(
        parser: ImagePlug.Parser.Imgproxy,
        root_url: "not-a-valid-origin-url",
        imgproxy: [
          signature: [
            keys: ["746573742d6b6579"],
            salts: ["746573742d73616c74"]
          ]
        ],
        cache: {CacheProbe, []},
        origin_req_options: [plug: ImagePlug.Request.ProcessorTest.OriginShouldNotFetch]
      )
    )

  assert conn.status == 403
  assert conn.resp_body =~ "invalid_signature"
  refute_received :cache_lookup
  refute_received :cache_put
end

test "invalid imgproxy signatures return before origin fetch with a valid root URL" do
  conn =
    ImagePlug.call(conn(:get, "/invalid/w:300/plain/images/cat.jpg"),
      ImagePlug.init(
        parser: ImagePlug.Parser.Imgproxy,
        root_url: "http://origin.test",
        imgproxy: [
          signature: [
            keys: ["746573742d6b6579"],
            salts: ["746573742d73616c74"]
          ]
        ],
        origin_req_options: [plug: ImagePlug.Request.ProcessorTest.OriginShouldNotFetch]
      )
    )

  assert conn.status == 403
  assert conn.resp_body =~ "invalid_signature"
end

test "invalid imgproxy signatures return before option parsing at the plug boundary" do
  conn =
    ImagePlug.call(conn(:get, "/invalid/raw/plain/images/cat.jpg"),
      ImagePlug.init(
        parser: ImagePlug.Parser.Imgproxy,
        root_url: "http://origin.test",
        imgproxy: [
          signature: [
            keys: ["746573742d6b6579"],
            salts: ["746573742d73616c74"]
          ]
        ],
        origin_req_options: [plug: ImagePlug.Request.ProcessorTest.OriginShouldNotFetch]
      )
    )

  assert conn.status == 403
  assert conn.resp_body =~ "invalid_signature"
  refute conn.resp_body =~ "unsupported_option"
end
```

- [ ] **Step 2: Add cache identity regression coverage**

Append to `test/image_plug/cache/key_test.exs`:

```elixir
test "cache key excludes imgproxy signature authorization proof" do
  signed_opts =
    ImagePlug.init(
      parser: ImagePlug.Parser.Imgproxy,
      root_url: "http://origin.test",
      imgproxy: [
        signature: [
          keys: ["746573742d6b6579"],
          salts: ["746573742d73616c74"]
        ]
      ]
    )

  trusted_opts =
    ImagePlug.init(
      parser: ImagePlug.Parser.Imgproxy,
      root_url: "http://origin.test",
      imgproxy: [
        signature: [
          keys: ["746573742d6b6579"],
          salts: ["746573742d73616c74"],
          trusted_signatures: ["local-dev!"]
        ]
      ]
    )

  assert {:ok, signed_plan} =
           ImagePlug.Parser.Imgproxy.parse(
             conn(
               :get,
               "/NSbxuO5fQqTgDkui_3o6ho1UCFFcmzsugB2Uksho49o/w:300/plain/images/cat.jpg"
             ),
             signed_opts
           )

  assert {:ok, trusted_plan} =
           ImagePlug.Parser.Imgproxy.parse(
             conn(:get, "/local-dev!/w:300/plain/images/cat.jpg"),
             trusted_opts
           )

  signed_key =
    build_key!(
      conn(:get, "/NSbxuO5fQqTgDkui_3o6ho1UCFFcmzsugB2Uksho49o/w:300/plain/images/cat.jpg"),
      signed_plan,
      "https://origin.test/images/cat.jpg"
    )

  trusted_key =
    build_key!(
      conn(:get, "/local-dev!/w:300/plain/images/cat.jpg"),
      trusted_plan,
      "https://origin.test/images/cat.jpg"
    )

  assert signed_plan == trusted_plan
  assert signed_key.hash == trusted_key.hash
  refute inspect(signed_key.data) =~ "NSbxuO5fQqTgDkui"
  refute inspect(trusted_key.data) =~ "local-dev"
end
```

- [ ] **Step 3: Run focused tests**

Run:

```bash
mise exec -- mix test test/image_plug/request_safety_test.exs test/image_plug/cache/key_test.exs --warnings-as-errors
```

Expected: all tests pass if Tasks 1-4 are complete.

- [ ] **Step 4: Commit Task 5**

```bash
mise exec -- git add test/image_plug/request_safety_test.exs test/image_plug/cache/key_test.exs
mise exec -- git commit -m "Cover imgproxy signature safety boundaries"
```

## Task 6: Update User-Facing Documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/imgproxy_path_api.md`
- Modify: `docs/imgproxy_support_matrix.md`

- [ ] **Step 1: Update README signature section**

In `README.md`, replace only this sentence:

```markdown
For local development, the signature segment can be `_` or `unsafe`:
```

with:

````markdown
For unsigned local development, the signature segment can be `_` or `unsafe`:
````

Leave the existing text code block of local examples in place. After that code
block, add this production-style signing section:

````markdown

For production-style imgproxy compatibility, configure hex-encoded key/salt
pairs under `:imgproxy`:

```elixir
forward "/",
  to: ImagePlug,
  init_opts: [
    root_url: "http://localhost:4000",
    parser: ImagePlug.Parser.Imgproxy,
    imgproxy: [
      signature: [
        keys: ["736563726574"],
        salts: ["68656c6c6f"],
        signature_size: 32,
        trusted_signatures: []
      ]
    ]
  ]
```

When signing is configured, `_` and `unsafe` are rejected unless explicitly
listed in `trusted_signatures`. Trusted signatures are exact path-segment
matches accepted before HMAC decoding. This is intentionally narrower than
upstream imgproxy's disabled-signing behavior, which accepts any signature
segment when no key/salt pair is configured.
````

- [ ] **Step 2: Update `docs/imgproxy_path_api.md` URL Shape section**

In `docs/imgproxy_path_api.md`, change the URL shape from:

```text
    /_/option[:arg...]/option[:arg...]/plain/path/to/image[@extension]
```

to:

```text
    /<signature>/option[:arg...]/option[:arg...]/plain/path/to/image[@extension]
```

Then replace the sentence that says `_` is the disabled-signing signature
segment with:

```markdown
The signature segment is verified before option parsing, planning, source
identity resolution, cache lookup, or origin fetch. With no `:imgproxy`
signature configuration, ImagePlug accepts only `_` and `unsafe` as
disabled-signing placeholders. With signing configured, the signature must be a
raw/unpadded Base64URL HMAC-SHA256 digest of the raw path after the signature,
including the leading slash, or an exact configured trusted signature.
Before verification, ImagePlug applies imgproxy-compatible `fixPath`
normalization: `%3A` in processing options is treated as `:`, and normalized
plain URL schemes such as `http:/x` and `local:/x` are repaired to `http://x`
and `local:///x`.

`plain` source paths are path segments after the source marker. A plain source
may end in `@extension` to request an explicit output format from the source
path. The `@extension` form bypasses `Accept` negotiation like `format`, `f`,
and `ext`.
```

- [ ] **Step 3: Update support matrix signature rows**

In `docs/imgproxy_support_matrix.md`, change these rows:

```markdown
| Required signature path segment | Partial | Only disabled-signing placeholders `_` and `unsafe` are accepted. |
| HMAC URL signatures | Missing | No key/salt verification or signed path validation yet. |
```

to:

```markdown
| Required signature path segment | Supported | `_` and `unsafe` are accepted when signing is disabled; HMAC and exact trusted signatures are accepted when signing is configured. This is intentionally narrower than upstream disabled-signing behavior. |
| HMAC URL signatures | Supported | Imgproxy parser verifies raw/unpadded Base64URL HMAC-SHA256 signatures with hex key/salt pairs, optional truncation, rotation pairs, exact trusted signatures, and imgproxy-compatible `fixPath` before verification. Signature failures return 403. |
```

Also remove HMAC signatures from `## Suggested Next Additions` so the matrix does not continue listing this completed feature as future work.

- [ ] **Step 4: Run docs diff check**

Run:

```bash
mise exec -- git diff -- README.md docs/imgproxy_path_api.md docs/imgproxy_support_matrix.md
```

Expected: diff documents signing without claiming absolute source URL, encoded source URL, encrypted source URL, or info endpoint support.

- [ ] **Step 5: Commit Task 6**

```bash
mise exec -- git add README.md docs/imgproxy_path_api.md docs/imgproxy_support_matrix.md
mise exec -- git commit -m "Document imgproxy signature support"
```

## Task 7: Final Verification

**Files:**
- Verify all modified files.

- [ ] **Step 1: Format changed Elixir files**

Run:

```bash
mise exec -- mix format lib/image_plug.ex lib/image_plug/parser/imgproxy.ex lib/image_plug/parser/imgproxy/signature.ex test/image_plug_test.exs test/parser/imgproxy/signature_test.exs test/parser/imgproxy_test.exs test/image_plug/request_safety_test.exs test/image_plug/cache/key_test.exs
```

Expected: command exits 0 and may rewrite formatted files.

- [ ] **Step 2: Run strict Credo**

Run:

```bash
mise exec -- mix credo --strict
```

Expected: command exits 0.

- [ ] **Step 3: Run focused test suite with warnings as errors**

Run:

```bash
mise exec -- mix test test/parser/imgproxy/signature_test.exs test/parser/imgproxy_test.exs test/image_plug_test.exs test/image_plug/request_safety_test.exs test/image_plug/cache/key_test.exs test/image_plug/architecture_boundary_test.exs --warnings-as-errors
```

Expected: all tests pass with no warnings.

- [ ] **Step 4: Run full test suite with warnings as errors**

Run:

```bash
mise exec -- mix test --warnings-as-errors
```

Expected: all tests pass with no warnings.

- [ ] **Step 5: Compile with warnings as errors**

Run:

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: command exits 0.

- [ ] **Step 6: Inspect final diff**

Run:

```bash
mise exec -- git status --short
mise exec -- git diff --stat HEAD
```

Expected: only intended implementation, test, and documentation files are modified.

- [ ] **Step 7: Commit final formatting or verification fixes**

If Step 1 rewrote files after the previous task commits, run:

```bash
mise exec -- git add lib test README.md docs/imgproxy_path_api.md docs/imgproxy_support_matrix.md
mise exec -- git commit -m "Finalize imgproxy signature support"
```

If `git status --short` is empty, skip this commit.

## Self-Review

- Spec coverage: Tasks 1-4 implement parser-owned configuration and verification; Task 5 covers safety and cache boundaries; Task 6 updates public docs and the support matrix; Task 7 verifies formatting, focused tests, full tests, and warning-free compilation.
- Review coverage: This revision addresses the subagent findings by preserving raw slash structure, parsing from the same fixed path used for signature verification, excluding query strings from signed bytes, adding positive raw-path, `fixPath`, and `script_name` tests, boundary-checking mounted prefix stripping, keeping parser validation out of `ImagePlug.Request`, using NimbleOptions for top-level and nested public config, requiring at least one authorization method, rejecting empty decoded key/salt values, returning 403 for signature failures, documenting intentional divergences from upstream disabled-signing and trusted-only behavior, avoiding hand-built signature structs outside signature tests, updating both support-matrix signature rows and suggested next additions, and running tests with warnings as errors.
- Placeholder scan: This plan contains no deferred implementation markers. Each code-changing task names concrete files, commands, and expected outcomes.
- Type consistency: The plan consistently uses `ImagePlug.Parser.Imgproxy.Signature`, `%Signature{mode, key_salt_pairs, signature_size, trusted_signatures}`, `disabled/0`, `validate_options!/1`, and `verify/3` across tests and implementation.
