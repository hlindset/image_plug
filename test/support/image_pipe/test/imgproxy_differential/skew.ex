defmodule ImagePipe.Test.ImgproxyDifferential.Skew do
  @moduledoc """
  libvips skew detection for the differential harness. The committed fixtures were
  baked by `manifest.imgproxy_libvips`; the pixel premise ("same kernels →
  near-exact") only holds when ImagePipe runs that exact version. Exact-match
  because resampling kernels can change on a patch bump.
  """

  @doc "ImagePipe's runtime libvips version."
  @spec runtime_libvips() :: String.t()
  def runtime_libvips, do: Vix.Vips.version()

  @doc "True when runtime libvips exactly matches the manifest's recorded version."
  @spec aligned?(map()) :: boolean()
  def aligned?(%{imgproxy_libvips: version}), do: runtime_libvips() == version

  @doc "True when running under CI (per the given env map; defaults to the system env)."
  @spec ci?(map()) :: boolean()
  def ci?(env \\ System.get_env()), do: Map.get(env, "CI", "") in ["1", "true", "TRUE"]
end
