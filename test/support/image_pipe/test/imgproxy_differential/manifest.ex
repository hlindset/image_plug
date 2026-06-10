defmodule ImagePipe.Test.ImgproxyDifferential.Manifest do
  @moduledoc """
  Generated provenance for the imgproxy differential harness. Stored as a
  git-diffable Elixir term (`manifest.exs`). The manifest is machine-only
  (REPORT.md is the human-readable record); it is data crossing a serialization
  boundary, so `load!/1` validates shape and fails loudly on anything malformed.
  """

  @authored_keys [:source, :opts, :verdict, :group, :tol, :divergence]

  @doc "Pretty-print the manifest term to `path`."
  @spec write!(Path.t(), map()) :: :ok
  def write!(path, %{} = manifest) do
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      inspect(manifest, pretty: true, limit: :infinity, printable_limit: :infinity) <> "\n"
    )
  end

  @doc "Load and validate a manifest term from `path`."
  @spec load!(Path.t()) :: map()
  def load!(path) do
    {term, _binding} = Code.eval_file(path)
    validate!(term)
  end

  defp validate!(
         %{
           imgproxy_digest: d,
           imgproxy_libvips: l,
           pipe_libvips_at_gen: p,
           sources: sources,
           entries: entries
         } = m
       )
       when is_binary(d) and is_binary(l) and is_binary(p) and is_map(sources) and is_map(entries) do
    Enum.each(entries, fn {id, entry} -> validate_entry!(id, entry) end)
    m
  end

  defp validate!(other) do
    raise "invalid manifest: missing required top-level keys in #{inspect(other, limit: 5)}"
  end

  defp validate_entry!(_id, %{
         kind: :transform,
         authored_sha256: a,
         fixture_filename: f,
         fixture_sha256: fs
       })
       when is_binary(a) and is_binary(f) and is_binary(fs),
       do: :ok

  defp validate_entry!(_id, %{
         kind: :lossy,
         authored_sha256: a,
         width: w,
         height: h,
         content_type: ct
       })
       when is_binary(a) and is_integer(w) and is_integer(h) and is_binary(ct),
       do: :ok

  defp validate_entry!(id, entry) do
    raise "invalid manifest: entry #{inspect(id)} is malformed: #{inspect(entry)}"
  end

  @doc "Stable, field-order-independent hash of a constellation's authored fields."
  @spec authored_sha256(map()) :: String.t()
  def authored_sha256(constellation) do
    canonical = Enum.map(@authored_keys, fn k -> {k, Map.get(constellation, k)} end)
    :crypto.hash(:sha256, :erlang.term_to_binary(canonical)) |> Base.encode16(case: :lower)
  end

  @doc "SHA-256 (lowercase hex) of a file's bytes."
  @spec file_sha256(Path.t()) :: String.t()
  def file_sha256(path) do
    :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
  end
end
