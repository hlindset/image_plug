defmodule ImagePlug.Parser.Imgproxy.SignatureTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Parser.Imgproxy
  alias ImagePlug.Parser.Imgproxy.Signature

  test "imgproxy parser exposes parser-owned option validation" do
    assert [signature: %Signature{mode: :disabled}] = Imgproxy.validate_options!([])
  end

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
      assert_raise ArgumentError,
                   ~r/at least one key\/salt pair or trusted signature is required/,
                   fn ->
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
        assert_raise ArgumentError,
                     ~r/keys and salts must be non-empty hex-encoded strings/,
                     fn ->
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
        assert_raise ArgumentError,
                     ~r/trusted_signatures must be a list of non-empty strings/,
                     fn ->
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
