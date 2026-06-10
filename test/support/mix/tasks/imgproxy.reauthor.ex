defmodule Mix.Tasks.Imgproxy.Reauthor do
  @shortdoc "Refresh manifest authored-field hashes without re-running imgproxy"
  @moduledoc """
  Recomputes `authored_sha256` for every constellation from `constellations.ex`
  and rewrites the manifest, leaving fixtures and REPORT untouched. Use after a
  `tol` tweak or a `:diverges`→`:equal` verdict flip (no pixels change).

      MIX_ENV=test mise exec -- mix imgproxy.reauthor
  """
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.ImgproxyDifferential.{Constellations, Manifest}

  @manifest_path "test/support/image_pipe/test/imgproxy_differential/manifest.exs"

  @impl Mix.Task
  def run(_args) do
    manifest = Manifest.load!(@manifest_path)
    by_id = Map.new(Constellations.all(), fn c -> {c.id, c} end)

    entries =
      Map.new(manifest.entries, fn {id, entry} ->
        {id, %{entry | authored_sha256: Manifest.authored_sha256(Map.fetch!(by_id, id))}}
      end)

    Manifest.write!(@manifest_path, %{manifest | entries: entries})
    Mix.shell().info("Reauthored #{map_size(entries)} manifest entries")
  end
end
