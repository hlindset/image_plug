# Imgproxy HMAC Signatures Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add imgproxy-compatible HMAC URL signature verification, including trusted signatures, as an imgproxy parser-only feature.

**Architecture:** Signature configuration and verification live under `ImagePlug.Parser.Imgproxy.*`. Core request option validation calls an explicit parser behaviour callback, but core does not know the shape of imgproxy signing config. Verified signatures authorize parsing only; signature strings never enter `ImagePlug.Plan`, cache keys, output, runtime, origin, response, or transform boundaries.

**Tech Stack:** Elixir, Plug, ExUnit, NimbleOptions, `:crypto.mac/4`, URL-safe Base64, `Plug.Crypto.secure_compare/2`, Boundary.

---

## File Structure

- Modify `lib/image_plug/parser.ex`: add the explicit parser option validation callback.
- Modify `lib/image_plug/request/options.ex`: call the parser callback after core/cache option validation.
- Modify `lib/image_plug/parser/imgproxy.ex`: implement `validate_options!/1`, alias signature support, build raw signed paths, and verify before option/source parsing.
- Create `lib/image_plug/parser/imgproxy/signature.ex`: own imgproxy signature config normalization and request-time verification.
- Modify `test/support/image_plug/request_safety_test/invalid_plan_parser.ex`: implement the new parser callback.
- Modify `test/support/image_plug/request_safety_test/invalid_pipeline_plan_parser.ex`: implement the new parser callback.
- Create `test/support/image_plug/request_options_test/parser_with_options.ex`: prove core dispatches parser-specific option validation explicitly.
- Modify `test/image_plug/request_options_test.exs`: cover parser callback dispatch and parser config errors.
- Create `test/parser/imgproxy/signature_test.exs`: cover config normalization and upstream compatibility vectors.
- Modify `test/parser/imgproxy_test.exs`: cover signed parser URLs, disabled-signing compatibility, and trusted-signature parser behavior.
- Modify `test/image_plug/request_safety_test.exs`: prove invalid signatures return before origin identity, cache lookup, and origin fetch.
- Modify `test/image_plug/cache/key_test.exs`: prove HMAC and trusted signatures for the same canonical request share cache identity.
- Modify `README.md`: document signing configuration and disabled-signing behavior.
- Modify `docs/imgproxy_path_api.md`: document signature verification semantics.
- Modify `docs/imgproxy_support_matrix.md`: change HMAC URL signatures from `Missing` to `Supported`.

## Task 1: Add Explicit Parser Option Validation Contract

**Files:**
- Modify: `lib/image_plug/parser.ex`
- Modify: `lib/image_plug/request/options.ex`
- Modify: `test/support/image_plug/request_safety_test/invalid_plan_parser.ex`
- Modify: `test/support/image_plug/request_safety_test/invalid_pipeline_plan_parser.ex`
- Create: `test/support/image_plug/request_options_test/parser_with_options.ex`
- Modify: `test/image_plug/request_options_test.exs`

- [ ] **Step 1: Add failing tests for parser option validation dispatch**

Append these tests to `test/image_plug/request_options_test.exs`:

```elixir
test "validate! delegates parser-owned options to the selected parser" do
  opts =
    Options.validate!(
      Keyword.put(@base_opts, :parser, ImagePlug.RequestOptionsTest.ParserWithOptions)
      |> Keyword.put(:parser_option, "accepted")
    )

  assert opts[:parser_validated?] == true
  assert opts[:parser_option] == "accepted"
end

test "validate! surfaces parser-owned option validation errors as invalid ImagePlug options" do
  assert_raise ArgumentError,
               ~r/invalid ImagePlug options: invalid parser options/,
               fn ->
                 Options.validate!(
                   Keyword.put(@base_opts, :parser, ImagePlug.RequestOptionsTest.ParserWithOptions)
                   |> Keyword.put(:parser_option, "rejected")
                 )
               end
end
```

Create `test/support/image_plug/request_options_test/parser_with_options.ex`:

```elixir
defmodule ImagePlug.RequestOptionsTest.ParserWithOptions do
  @behaviour ImagePlug.Parser

  @impl ImagePlug.Parser
  def validate_options!(opts) do
    case Keyword.fetch(opts, :parser_option) do
      {:ok, "accepted"} ->
        Keyword.put(opts, :parser_validated?, true)

      {:ok, "rejected"} ->
        raise ArgumentError, "invalid parser options: parser_option must be accepted"

      :error ->
        opts
    end
  end

  @impl ImagePlug.Parser
  def parse(_conn, _opts), do: {:error, :unused}

  @impl ImagePlug.Parser
  def handle_error(conn, {:error, _reason}), do: conn
end
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
mise exec -- mix test test/image_plug/request_options_test.exs
```

Expected: compile failure because `ImagePlug.Parser` has no `validate_options!/1` callback or assertion failure because `parser_validated?` is missing.

- [ ] **Step 3: Add parser callback to `ImagePlug.Parser`**

In `lib/image_plug/parser.ex`, insert this callback before `parse/2`:

```elixir
@doc """
Validate and normalize parser-owned options during Plug initialization.
"""
@callback validate_options!(keyword()) :: keyword()
```

- [ ] **Step 4: Dispatch parser option validation in `ImagePlug.Request.Options`**

Change `validate!/1` in `lib/image_plug/request/options.ex` to:

```elixir
def validate!(opts) do
  opts
  |> Cache.validate_config!()
  |> validate_known_opts!()
  |> validate_parser_opts!()
end
```

Add this private function below `validate_known_opts!/1`:

```elixir
defp validate_parser_opts!(opts) do
  parser = Keyword.fetch!(opts, :parser)

  try do
    parser.validate_options!(opts)
  rescue
    error in ArgumentError ->
      raise ArgumentError, "invalid ImagePlug options: #{Exception.message(error)}"
  end
end
```

- [ ] **Step 5: Implement pass-through callbacks for existing parser modules**

Add to `lib/image_plug/parser/imgproxy.ex` after `def parse(%Plug.Conn{} = conn)`:

```elixir
@impl ImagePlug.Parser
def validate_options!(opts), do: opts
```

Add this callback implementation to both request safety support parsers:

```elixir
@impl ImagePlug.Parser
def validate_options!(opts), do: opts
```

The files are:

- `test/support/image_plug/request_safety_test/invalid_plan_parser.ex`
- `test/support/image_plug/request_safety_test/invalid_pipeline_plan_parser.ex`

- [ ] **Step 6: Run focused tests**

Run:

```bash
mise exec -- mix test test/image_plug/request_options_test.exs test/image_plug/request_safety_test.exs
```

Expected: all tests pass.

- [ ] **Step 7: Commit Task 1**

```bash
mise exec -- git add lib/image_plug/parser.ex lib/image_plug/request/options.ex lib/image_plug/parser/imgproxy.ex test/support/image_plug/request_safety_test/invalid_plan_parser.ex test/support/image_plug/request_safety_test/invalid_pipeline_plan_parser.ex test/support/image_plug/request_options_test/parser_with_options.ex test/image_plug/request_options_test.exs
mise exec -- git commit -m "Add parser option validation callback"
```

## Task 2: Add Imgproxy Signature Config Normalization

**Files:**
- Create: `lib/image_plug/parser/imgproxy/signature.ex`
- Modify: `lib/image_plug/parser/imgproxy.ex`
- Create: `test/parser/imgproxy/signature_test.exs`
- Modify: `test/image_plug/request_options_test.exs`

- [ ] **Step 1: Write failing config tests**

Create `test/parser/imgproxy/signature_test.exs`:

```elixir
defmodule ImagePlug.Parser.Imgproxy.SignatureTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Parser.Imgproxy.Signature

  describe "from_options/1" do
    test "returns disabled config when imgproxy signature config is absent" do
      assert %Signature{mode: :disabled, key_salt_pairs: [], signature_size: 32} =
               Signature.from_options([])
    end

    test "normalizes hex key and salt pairs" do
      opts = [
        imgproxy: [
          signature: [
            keys: ["746573742d6b6579"],
            salts: ["746573742d73616c74"],
            signature_size: 8,
            trusted_signatures: ["local-dev!"]
          ]
        ]
      ]

      assert %Signature{
               mode: :enabled,
               key_salt_pairs: [{"test-key", "test-salt"}],
               signature_size: 8,
               trusted_signatures: trusted_signatures
             } = Signature.from_options(opts)

      assert MapSet.equal?(trusted_signatures, MapSet.new(["local-dev!"]))
    end

    test "rejects mismatched key and salt counts" do
      opts = [imgproxy: [signature: [keys: ["74657374"], salts: []]]]

      assert_raise ArgumentError, ~r/keys and salts must have the same length/, fn ->
        Signature.validate_options!(opts)
      end
    end

    test "rejects malformed hex key and salt values" do
      for config <- [
            [keys: ["not-hex"], salts: ["74657374"]],
            [keys: ["74657374"], salts: ["not-hex"]]
          ] do
        assert_raise ArgumentError, ~r/invalid imgproxy signature config/, fn ->
          Signature.validate_options!(imgproxy: [signature: config])
        end
      end
    end

    test "rejects signature sizes outside 1..32" do
      for signature_size <- [0, 33, "8"] do
        assert_raise ArgumentError, ~r/signature_size must be an integer from 1 to 32/, fn ->
          Signature.validate_options!(
            imgproxy: [
              signature: [
                keys: ["74657374"],
                salts: ["73616c74"],
                signature_size: signature_size
              ]
            ]
          )
        end
      end
    end

    test "rejects malformed trusted signatures" do
      for trusted_signatures <- ["local-dev", [""], [:not_binary]] do
        assert_raise ArgumentError, ~r/trusted_signatures must be a list of non-empty strings/, fn ->
          Signature.validate_options!(
            imgproxy: [
              signature: [
                keys: ["74657374"],
                salts: ["73616c74"],
                trusted_signatures: trusted_signatures
              ]
            ]
          )
        end
      end
    end
  end
end
```

Append this test to `test/image_plug/request_options_test.exs`:

```elixir
test "validate! normalizes imgproxy signature options through the imgproxy parser" do
  opts =
    Options.validate!(
      Keyword.put(@base_opts, :imgproxy,
        signature: [
          keys: ["746573742d6b6579"],
          salts: ["746573742d73616c74"],
          signature_size: 8,
          trusted_signatures: ["local-dev!"]
        ]
      )
    )

  assert %ImagePlug.Parser.Imgproxy.Signature{
           mode: :enabled,
           key_salt_pairs: [{"test-key", "test-salt"}],
           signature_size: 8
         } = get_in(opts, [:imgproxy, :signature])
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
mise exec -- mix test test/parser/imgproxy/signature_test.exs test/image_plug/request_options_test.exs
```

Expected: compile failure because `ImagePlug.Parser.Imgproxy.Signature` does not exist.

- [ ] **Step 3: Implement signature config module**

Create `lib/image_plug/parser/imgproxy/signature.ex`:

```elixir
defmodule ImagePlug.Parser.Imgproxy.Signature do
  @moduledoc false

  @enforce_keys [:mode, :key_salt_pairs, :signature_size, :trusted_signatures]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          mode: :disabled | :enabled,
          key_salt_pairs: [{binary(), binary()}],
          signature_size: 1..32,
          trusted_signatures: MapSet.t(String.t())
        }

  @spec validate_options!(keyword()) :: keyword()
  def validate_options!(opts) do
    signature = from_options(opts)

    imgproxy =
      opts
      |> Keyword.get(:imgproxy, [])
      |> Keyword.put(:signature, signature)

    Keyword.put(opts, :imgproxy, imgproxy)
  end

  @spec from_options(keyword()) :: t()
  def from_options(opts) do
    opts
    |> Keyword.get(:imgproxy, [])
    |> Keyword.get(:signature)
    |> normalize_config()
  end

  defp normalize_config(nil) do
    %__MODULE__{
      mode: :disabled,
      key_salt_pairs: [],
      signature_size: 32,
      trusted_signatures: MapSet.new()
    }
  end

  defp normalize_config(%__MODULE__{} = signature), do: signature

  defp normalize_config(config) when is_list(config) do
    keys = Keyword.get(config, :keys, [])
    salts = Keyword.get(config, :salts, [])
    signature_size = Keyword.get(config, :signature_size, 32)
    trusted_signatures = Keyword.get(config, :trusted_signatures, [])

    with {:ok, key_salt_pairs} <- key_salt_pairs(keys, salts),
         {:ok, signature_size} <- signature_size(signature_size),
         {:ok, trusted_signatures} <- trusted_signatures(trusted_signatures) do
      %__MODULE__{
        mode: :enabled,
        key_salt_pairs: key_salt_pairs,
        signature_size: signature_size,
        trusted_signatures: trusted_signatures
      }
    else
      {:error, reason} -> raise ArgumentError, "invalid imgproxy signature config: #{reason}"
    end
  end

  defp normalize_config(_config),
    do: raise(ArgumentError, "invalid imgproxy signature config: signature must be a keyword list")

  defp key_salt_pairs(keys, salts) when is_list(keys) and is_list(salts) do
    case length(keys) == length(salts) do
      true -> decode_key_salt_pairs(keys, salts)
      false -> {:error, "keys and salts must have the same length"}
    end
  end

  defp key_salt_pairs(_keys, _salts), do: {:error, "keys and salts must be lists"}

  defp decode_key_salt_pairs([], []), do: {:ok, []}

  defp decode_key_salt_pairs(keys, salts) do
    result =
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

    case result do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_hex(value) when is_binary(value) do
    case Base.decode16(value, case: :mixed) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, "keys and salts must be hex-encoded strings"}
    end
  end

  defp decode_hex(_value), do: {:error, "keys and salts must be hex-encoded strings"}

  defp signature_size(value) when is_integer(value) and value in 1..32, do: {:ok, value}
  defp signature_size(_value), do: {:error, "signature_size must be an integer from 1 to 32"}

  defp trusted_signatures(values) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and &1 != "")) do
      {:ok, MapSet.new(values)}
    else
      {:error, "trusted_signatures must be a list of non-empty strings"}
    end
  end

  defp trusted_signatures(_values),
    do: {:error, "trusted_signatures must be a list of non-empty strings"}
end
```

- [ ] **Step 4: Wire imgproxy parser option validation**

Replace the temporary `validate_options!/1` in `lib/image_plug/parser/imgproxy.ex` with:

```elixir
alias ImagePlug.Parser.Imgproxy.Signature
```

and:

```elixir
@impl ImagePlug.Parser
def validate_options!(opts), do: Signature.validate_options!(opts)
```

- [ ] **Step 5: Run focused tests**

Run:

```bash
mise exec -- mix test test/parser/imgproxy/signature_test.exs test/image_plug/request_options_test.exs
```

Expected: all tests pass.

- [ ] **Step 6: Commit Task 2**

```bash
mise exec -- git add lib/image_plug/parser/imgproxy/signature.ex lib/image_plug/parser/imgproxy.ex test/parser/imgproxy/signature_test.exs test/image_plug/request_options_test.exs
mise exec -- git commit -m "Add imgproxy signature configuration"
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
    config = Signature.from_options([])

    assert :ok = Signature.verify("_", "/plain/images/cat.jpg", config)
    assert :ok = Signature.verify("unsafe", "/plain/images/cat.jpg", config)
    assert Signature.verify("signed-value", "/plain/images/cat.jpg", config) ==
             {:error, {:unsupported_signature, "signed-value"}}
  end

  test "matches upstream full and truncated primitive HMAC vectors" do
    full =
      Signature.from_options(
        imgproxy: [
          signature: [
            keys: ["746573742d6b6579"],
            salts: ["746573742d73616c74"]
          ]
        ]
      )

    truncated =
      Signature.from_options(
        imgproxy: [
          signature: [
            keys: ["746573742d6b6579"],
            salts: ["746573742d73616c74"],
            signature_size: 8
          ]
        ]
      )

    assert :ok = Signature.verify("dtLwhdnPPiu_epMl1LrzheLpvHas-4mwvY6L3Z8WwlY", "asd", full)
    assert :ok = Signature.verify("dtLwhdnPPis", "asd", truncated)
    assert Signature.verify("dtLwhdnPPis", "asd", full) == {:error, :invalid_signature}
  end

  test "matches upstream key rotation vectors" do
    config =
      Signature.from_options(
        imgproxy: [
          signature: [
            keys: ["746573742d6b6579", "746573742d6b657932"],
            salts: ["746573742d73616c74", "746573742d73616c7432"]
          ]
        ]
      )

    assert :ok = Signature.verify("dtLwhdnPPiu_epMl1LrzheLpvHas-4mwvY6L3Z8WwlY", "asd", config)
    assert :ok = Signature.verify("jbDffNPt1-XBgDccsaE-XJB9lx8JIJqdeYIZKgOqZpg", "asd", config)
  end

  test "accepts exact trusted signatures before Base64 decoding" do
    config =
      Signature.from_options(
        imgproxy: [
          signature: [
            keys: ["746573742d6b6579"],
            salts: ["746573742d73616c74"],
            trusted_signatures: ["truested", "local-dev!"]
          ]
        ]
      )

    assert :ok = Signature.verify("truested", "asd", config)
    assert :ok = Signature.verify("local-dev!", "/w:300/plain/images/cat.jpg", config)
    assert Signature.verify("untrusted", "asd", config) == {:error, :invalid_signature}
  end

  test "matches public docs signing vector" do
    config =
      Signature.from_options(
        imgproxy: [
          signature: [
            keys: ["736563726574"],
            salts: ["68656c6c6f"]
          ]
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
    config =
      Signature.from_options(
        imgproxy: [
          signature: [
            keys: ["746573742d6b6579"],
            salts: ["746573742d73616c74"]
          ]
        ]
      )

    assert Signature.verify("local-dev!", "/w:300/plain/images/cat.jpg", config) ==
             {:error, {:invalid_signature_encoding, "local-dev!"}}

    assert Signature.verify("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "/w:300/plain/images/cat.jpg", config) ==
             {:error, :invalid_signature}
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
mise exec -- mix test test/parser/imgproxy/signature_test.exs
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
  case Base.url_decode64(signature, padding: false) do
    {:ok, decoded} -> {:ok, decoded}
    :error -> {:error, {:invalid_signature_encoding, signature}}
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
mise exec -- mix test test/parser/imgproxy/signature_test.exs
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

Add these tests near the existing signature tests in `test/parser/imgproxy_test.exs`:

```elixir
@signed_parser_opts [
  imgproxy: [
    signature: %ImagePlug.Parser.Imgproxy.Signature{
      mode: :enabled,
      key_salt_pairs: [{"test-key", "test-salt"}],
      signature_size: 32,
      trusted_signatures: MapSet.new()
    }
  ]
]

test "accepts valid signed imgproxy URLs when signing is enabled" do
  assert {:ok, %Plan{source: {:plain, ["images", "cat.jpg"]}}} =
           Imgproxy.parse(
             conn(
               :get,
               "/NSbxuO5fQqTgDkui_3o6ho1UCFFcmzsugB2Uksho49o/w:300/plain/images/cat.jpg"
             ),
             @signed_parser_opts
           )
end

test "rejects disabled-signing placeholders when signing is enabled" do
  assert Imgproxy.parse(conn(:get, "/_/plain/images/cat.jpg"), @signed_parser_opts) ==
           {:error, :invalid_signature}

  assert Imgproxy.parse(conn(:get, "/unsafe/plain/images/cat.jpg"), @signed_parser_opts) ==
           {:error, :invalid_signature}
end

test "accepts exact trusted signatures before HMAC decoding" do
  opts = [
    imgproxy: [
      signature: %ImagePlug.Parser.Imgproxy.Signature{
        mode: :enabled,
        key_salt_pairs: [{"test-key", "test-salt"}],
        signature_size: 32,
        trusted_signatures: MapSet.new(["local-dev!"])
      }
    ]
  ]

  assert {:ok, %Plan{source: {:plain, ["images", "cat.jpg"]}}} =
           Imgproxy.parse(conn(:get, "/local-dev!/w:300/plain/images/cat.jpg"), opts)
end

test "rejects invalid signature encodings before parsing options" do
  assert Imgproxy.parse(conn(:get, "/local-dev!/raw/plain/images/cat.jpg"), @signed_parser_opts) ==
           {:error, {:invalid_signature_encoding, "local-dev!"}}
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
mise exec -- mix test test/parser/imgproxy_test.exs
```

Expected: signed URL test fails because parser still accepts only `_` and `unsafe`.

- [ ] **Step 3: Verify signatures before source and option parsing**

In `lib/image_plug/parser/imgproxy.ex`, update `parse_request/2`:

```elixir
def parse_request(%Plug.Conn{path_info: [signature | path_info]}, opts) do
  with :ok <- verify_signature(signature, path_info, opts),
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
defp verify_signature(signature, path_info, opts) do
  signed_path = "/" <> Enum.join(path_info, "/")

  opts
  |> Signature.from_options()
  |> then(&Signature.verify(signature, signed_path, &1))
end
```

- [ ] **Step 4: Run focused parser tests**

Run:

```bash
mise exec -- mix test test/parser/imgproxy_test.exs test/parser/imgproxy/signature_test.exs
```

Expected: all tests pass.

- [ ] **Step 5: Commit Task 4**

```bash
mise exec -- git add lib/image_plug/parser/imgproxy.ex test/parser/imgproxy_test.exs
mise exec -- git commit -m "Enforce imgproxy signatures in parser"
```

## Task 5: Add Request Safety and Cache Identity Coverage

**Files:**
- Modify: `test/image_plug/request_safety_test.exs`
- Modify: `test/image_plug/cache/key_test.exs`

- [ ] **Step 1: Add failing request safety test**

Append to `test/image_plug/request_safety_test.exs`:

```elixir
test "invalid imgproxy signatures return before source identity, cache lookup, and origin" do
  conn =
    ImagePlug.call(conn(:get, "/invalid/w:300/plain/images/cat.jpg"),
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

  assert conn.status == 400
  assert conn.resp_body =~ "invalid_signature"
  refute_received :cache_lookup
  refute_received :cache_put
end
```

- [ ] **Step 2: Add failing cache identity test**

Append to `test/image_plug/cache/key_test.exs`:

```elixir
test "cache key excludes imgproxy signature authorization proof" do
  assert {:ok, signed_plan} =
           ImagePlug.Parser.Imgproxy.parse(
             conn(
               :get,
               "/NSbxuO5fQqTgDkui_3o6ho1UCFFcmzsugB2Uksho49o/w:300/plain/images/cat.jpg"
             ),
             imgproxy: [
               signature: %ImagePlug.Parser.Imgproxy.Signature{
                 mode: :enabled,
                 key_salt_pairs: [{"test-key", "test-salt"}],
                 signature_size: 32,
                 trusted_signatures: MapSet.new()
               }
             ]
           )

  assert {:ok, trusted_plan} =
           ImagePlug.Parser.Imgproxy.parse(
             conn(:get, "/local-dev!/w:300/plain/images/cat.jpg"),
             imgproxy: [
               signature: %ImagePlug.Parser.Imgproxy.Signature{
                 mode: :enabled,
                 key_salt_pairs: [{"test-key", "test-salt"}],
                 signature_size: 32,
                 trusted_signatures: MapSet.new(["local-dev!"])
               }
             ]
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

- [ ] **Step 3: Run tests to verify behavior**

Run:

```bash
mise exec -- mix test test/image_plug/request_safety_test.exs test/image_plug/cache/key_test.exs
```

Expected: all tests pass if Tasks 1-4 are complete. If a test fails, fix parser ordering or cache assertions before proceeding.

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

In `README.md`, replace the paragraph that says local development can use `_` or `unsafe` with:

````markdown
For unsigned local development, the signature segment can be `_` or `unsafe`:

```text
/_/plain/images/cat-300.jpg
/unsafe/w:300/plain/images/cat-300.jpg
```

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
matches accepted before HMAC decoding.
````

- [ ] **Step 2: Update `docs/imgproxy_path_api.md` URL Shape section**

Add this after the paragraph that defines the general URL shape:

```markdown
The signature segment is verified before option parsing, planning, source
identity resolution, cache lookup, or origin fetch. With no `:imgproxy`
signature configuration, ImagePlug accepts only `_` and `unsafe` as
disabled-signing placeholders. With signing configured, the signature must be a
URL-safe Base64 HMAC-SHA256 digest of the path after the signature, including
the leading slash, or an exact configured trusted signature.
```

- [ ] **Step 3: Update support matrix**

In `docs/imgproxy_support_matrix.md`, change the HMAC row from:

```markdown
| HMAC URL signatures | Missing | No key/salt verification or signed path validation yet. |
```

to:

```markdown
| HMAC URL signatures | Supported | Imgproxy parser verifies URL-safe Base64 HMAC-SHA256 signatures with hex key/salt pairs, optional truncation, rotation pairs, and exact trusted signatures. |
```

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
mise exec -- mix format lib/image_plug/parser.ex lib/image_plug/request/options.ex lib/image_plug/parser/imgproxy.ex lib/image_plug/parser/imgproxy/signature.ex test/support/image_plug/request_safety_test/invalid_plan_parser.ex test/support/image_plug/request_safety_test/invalid_pipeline_plan_parser.ex test/support/image_plug/request_options_test/parser_with_options.ex test/image_plug/request_options_test.exs test/parser/imgproxy/signature_test.exs test/parser/imgproxy_test.exs test/image_plug/request_safety_test.exs test/image_plug/cache/key_test.exs
```

Expected: command exits 0 and may rewrite formatted files.

- [ ] **Step 2: Run focused test suite**

Run:

```bash
mise exec -- mix test test/parser/imgproxy/signature_test.exs test/parser/imgproxy_test.exs test/image_plug/request_options_test.exs test/image_plug/request_safety_test.exs test/image_plug/cache/key_test.exs
```

Expected: all tests pass.

- [ ] **Step 3: Run full test suite**

Run:

```bash
mise exec -- mix test
```

Expected: all tests pass.

- [ ] **Step 4: Compile with warnings as errors**

Run:

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: command exits 0.

- [ ] **Step 5: Inspect final diff**

Run:

```bash
mise exec -- git status --short
mise exec -- git diff --stat HEAD
```

Expected: only intended implementation, test, and documentation files are modified.

- [ ] **Step 6: Commit final formatting or verification fixes**

If Step 1 rewrote files after the previous task commits, run:

```bash
mise exec -- git add lib test README.md docs/imgproxy_path_api.md docs/imgproxy_support_matrix.md
mise exec -- git commit -m "Finalize imgproxy signature support"
```

If `git status --short` is empty, skip this commit.

## Self-Review

- Spec coverage: Tasks 1-4 implement parser-owned configuration and verification; Task 5 covers safety and cache boundaries; Task 6 updates public docs and the support matrix; Task 7 verifies formatting, focused tests, full tests, and warning-free compilation.
- Placeholder scan: This plan contains no deferred implementation markers. Each code-changing task names concrete files, commands, and expected outcomes.
- Type consistency: The plan consistently uses `ImagePlug.Parser.Imgproxy.Signature`, `%Signature{mode, key_salt_pairs, signature_size, trusted_signatures}`, `validate_options!/1`, `from_options/1`, and `verify/3` across tests and implementation.
