defmodule ImagePlug.Parser.Imgproxy do
  @moduledoc """
  Parser for ImagePlug's imgproxy path-oriented URL syntax.
  """

  use Boundary,
    deps: [
      ImagePlug.Format,
      ImagePlug.Parser,
      ImagePlug.Plan,
      ImagePlug.Transform
    ],
    exports: [
      SourceScheme
    ]

  @behaviour ImagePlug.Parser

  alias ImagePlug.Parser.Imgproxy.Options
  alias ImagePlug.Parser.Imgproxy.ParsedRequest
  alias ImagePlug.Parser.Imgproxy.Path
  alias ImagePlug.Parser.Imgproxy.PlanBuilder
  alias ImagePlug.Parser.Imgproxy.Presets
  alias ImagePlug.Parser.Imgproxy.Signature

  @imgproxy_schema NimbleOptions.new!(
                     signature: [type: :keyword_list, required: false],
                     source_schemes: [
                       type: {:custom, __MODULE__, :validate_source_schemes, []},
                       default: %{}
                     ],
                     presets: [
                       type: {:custom, Presets, :validate_config, []},
                       default: %{}
                     ]
                   )

  def parse(%Plug.Conn{} = conn), do: parse(conn, [])

  @doc false
  def validate_options!(imgproxy_opts) when is_list(imgproxy_opts) do
    case NimbleOptions.validate(imgproxy_opts, @imgproxy_schema) do
      {:ok, validated} ->
        Keyword.update(
          validated,
          :signature,
          Signature.disabled(),
          &Signature.normalize_config!/1
        )

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError, "invalid imgproxy config: #{Exception.message(error)}"
    end
  end

  def validate_options!(_imgproxy_opts),
    do: raise(ArgumentError, "invalid imgproxy options: expected a keyword list")

  @doc false
  def validate_source_schemes(%{} = schemes) do
    if Enum.all?(schemes, &valid_source_scheme_entry?/1) do
      {:ok, schemes}
    else
      {:error, "expected a map from binary scheme names to {module, keyword_options}"}
    end
  end

  def validate_source_schemes(_schemes),
    do: {:error, "expected a map from binary scheme names to {module, keyword_options}"}

  @impl ImagePlug.Parser
  def parse(%Plug.Conn{} = conn, opts) do
    with {:ok, parsed_request} <- parse_request(conn, opts) do
      PlanBuilder.to_plan(parsed_request, opts)
    end
  end

  defp parse_request(%Plug.Conn{} = conn, opts) do
    with {:ok, signature, signed_path, path_info} <- Path.extract(conn),
         :ok <- verify_signature(signature, signed_path, opts),
         {:ok, option_segments, source_kind, raw_source_path} <- Path.split_source(path_info),
         {:ok, request_options} <- Options.parse(option_segments, preset_config(opts)),
         {:ok, source_path, source_format} <- Path.parse_source(source_kind, raw_source_path) do
      parsed_request(
        signature,
        source_path,
        source_format,
        request_options
      )
    end
  end

  @impl ImagePlug.Parser
  def handle_error(%Plug.Conn{} = conn, {:error, :invalid_signature}) do
    send_signature_error(conn, :invalid_signature)
  end

  def handle_error(
        %Plug.Conn{} = conn,
        {:error, {:invalid_signature_encoding, _signature}}
      ) do
    send_signature_error(conn, :invalid_signature_encoding)
  end

  def handle_error(%Plug.Conn{} = conn, {:error, {:unsupported_signature, _signature}}) do
    send_signature_error(conn, :unsupported_signature)
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

  defp verify_signature(signature, signed_path, opts) do
    Signature.verify(signature, signed_path, signature_config(opts))
  end

  defp signature_config(opts) do
    opts
    |> Keyword.get(:imgproxy, [])
    |> Keyword.get(:signature, Signature.disabled())
  end

  defp preset_config(opts) do
    opts
    |> Keyword.get(:imgproxy, [])
    |> Keyword.get(:presets, Presets.empty())
  end

  defp valid_source_scheme_entry?({scheme, {translator, translator_opts}}) do
    is_binary(scheme) and valid_source_scheme_translator?(translator) and
      Keyword.keyword?(translator_opts)
  end

  defp valid_source_scheme_entry?(_entry), do: false

  defp valid_source_scheme_translator?(translator) when is_atom(translator) do
    Code.ensure_loaded?(translator) and function_exported?(translator, :translate, 2)
  end

  defp valid_source_scheme_translator?(_translator), do: false

  defp parsed_request(
         signature,
         source_path,
         source_format,
         request_options
       ) do
    output_format = source_format || request_options.output.format

    {:ok,
     %ParsedRequest{
       signature: signature,
       source_kind: :plain,
       source_path: source_path,
       pipelines: request_options.pipelines,
       output: %{request_options.output | format: output_format},
       policy: request_options.policy,
       cache: request_options.cache,
       response: request_options.response
     }}
  end
end
