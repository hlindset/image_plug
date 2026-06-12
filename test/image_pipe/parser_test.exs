defmodule ImagePipe.ParserTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser

  defmodule NoOptionParser do
    @behaviour ImagePipe.Parser

    @impl ImagePipe.Parser
    def parse(_conn, _opts), do: {:error, :unused}

    @impl ImagePipe.Parser
    def handle_error(conn, _error), do: conn
  end

  defmodule OptionParser do
    @behaviour ImagePipe.Parser

    @impl ImagePipe.Parser
    def parse(_conn, _opts), do: {:error, :unused}

    @impl ImagePipe.Parser
    def handle_error(conn, _error), do: conn

    @impl ImagePipe.Parser
    def validate_options!(opts), do: Keyword.put(opts, :validated_namespace, normalized: true)
  end

  describe "validate_options!/2" do
    test "dispatches to a parser that owns option validation" do
      result = Parser.validate_options!(OptionParser, parser: OptionParser)

      assert result[:parser] == OptionParser
      assert result[:validated_namespace] == [normalized: true]
    end

    test "is an identity for a parser that takes no host options" do
      opts = [parser: NoOptionParser, max_body_bytes: 1_000]

      assert Parser.validate_options!(NoOptionParser, opts) == opts
    end
  end
end
