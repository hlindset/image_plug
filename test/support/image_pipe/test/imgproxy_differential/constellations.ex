defmodule ImagePipe.Test.ImgproxyDifferential.Constellations do
  @moduledoc """
  The canonical, authored constellation list for the imgproxy differential
  conformance harness. Imported by BOTH the generator Mix task and the comparison
  test, so the two cannot drift. Each entry is authored intent; provenance lives
  in the generated manifest, joined by `:id`.
  """

  use Boundary, top_level?: true, deps: []

  @source_files %{
    high_freq: "high_freq.jpg",
    high_freq_webp: "high_freq.webp",
    marker: "marker.png",
    border: "border.png",
    alpha: "alpha.png",
    exif_jpeg: "exif.jpg",
    icc_p3: "icc_p3.png",
    small: "small.png"
  }

  @doc "Map of `source` atom -> committed source filename."
  def source_files, do: @source_files

  @doc "The authored constellation list."
  def all do
    [
      # --- transform group: :equal (PNG output, pixel comparison) ---
      c("rs_fill_zone", :high_freq, "rs:fill:240:180/g:ce"),
      c("rs_fit_zone", :high_freq, "rs:fit:300:300"),
      c("rs_fill_zone_q4", :high_freq, "rs:fill:200:150"),
      c("rs_fill_webp_residual", :high_freq_webp, "rs:fill:233:151"),
      c("crop_gravity_marker", :marker, "c:120:90/g:nowe"),
      c("trim_border_equal", :border, "t:10"),
      c("alpha_resize", :alpha, "rs:fit:64:64"),
      c("rotate_exif", :exif_jpeg, "rs:fit:120:120"),
      c("enlarge_small", :small, "rs:fit:400:400/el:1"),
      triage(
        c("min_dims_clamp", :high_freq, "rs:fit:300:300/mw:280/mh:280"),
        "dims 373x280 vs imgproxy 300x280 — min-dim aspect semantics (#194)"
      ),
      c("zoom_marker", :marker, "z:0.5"),
      triage(
        c("fill_down_marker", :marker, "rs:fill-down:500:500"),
        "~0.02% over Δ2 — fill-down crop seam vs 1px shift (#197)"
      ),
      c("gravity_offset_marker", :marker, "rs:fill:120:120/g:no:10:20"),
      c("padding_border", :border, "rs:fit:120:120/pd:10:20"),
      triage(
        c("extend_small", :small, "rs:fit:300:200/ex:1"),
        "~0.67% over Δ2 in the padded region (#195)"
      ),
      triage(
        c("extend_ar_small", :small, "rs:fit:300:200/exar:1"),
        "~0.5% over Δ2, same family as extend (#196)"
      ),
      c("dpr_marker", :marker, "rs:fit:80:80/dpr:2"),
      c("background_alpha", :alpha, "rs:fit:64:64/bg:255:0:0"),
      c("blur_zone", :high_freq, "rs:fit:240:240/bl:3"),
      c("sharpen_zone", :high_freq, "rs:fit:240:240/sh:2"),
      c("strip_exif", :exif_jpeg, "rs:fit:120:120/sm:1"),

      # icc_p3 trim agrees with imgproxy in stored pixels; the trim-detection
      # colorspace difference is behavioral-only (not observable here), so this is
      # an :equal conformance case on a profiled source.
      c("trim_icc_p3", :icc_p3, "t:10"),

      # --- :diverges (whole-frame fraction metric; runs regardless of libvips skew) ---
      # #124: with scp:0 ImagePipe skips the P3 working-space conversion imgproxy
      # always performs, so processing diverges. The effect is diffuse (~2.6% of
      # band-bytes exceed Δ2 on the P3 source), so it is measured as a whole-frame
      # fraction-over-Δ, not a flat-region mean. (`sa`/tone ops would amplify it but
      # are imgproxy Pro-only.) Floor set below the measured value with margin.
      diverge(
        "scp0_colorspace_124",
        :icc_p3,
        "rs:fit:200:200/scp:0",
        %{metric: :fraction_over, threshold: 2, floor: 0.01, issue: "#124"}
      ),

      # --- lossy group: contract-only (dims/content-type/decode), no pixel claim ---
      lossy("lossy_webp", :high_freq_webp, "rs:fill:240:180/f:webp"),
      lossy("lossy_jpeg_q40", :high_freq, "rs:fill:240:180/q:40/f:jpg"),
      lossy("lossy_avif", :high_freq, "rs:fill:240:180/f:avif")
    ]
  end

  @doc """
  The imgproxy request path for a constellation, shared by the generator and the
  test so they cannot diverge. Transform-group requests force `f:png` (lossless,
  isolates transform pixels); lossy-group requests keep the format in `opts`.
  """
  def imgproxy_path(%{group: group, opts: opts, source: source}) do
    opts_segment = if group == :transform, do: "#{opts}/f:png", else: opts
    "/unsafe/#{opts_segment}/plain/local:///#{Map.fetch!(@source_files, source)}"
  end

  defp c(id, source, opts),
    do: %{
      id: id,
      source: source,
      opts: opts,
      verdict: :equal,
      group: :transform,
      tol: nil,
      divergence: nil
    }

  defp diverge(id, source, opts, divergence),
    do: %{
      id: id,
      source: source,
      opts: opts,
      verdict: :diverges,
      group: :transform,
      tol: nil,
      divergence: divergence
    }

  defp lossy(id, source, opts),
    do: %{
      id: id,
      source: source,
      opts: opts,
      verdict: :equal,
      group: :lossy,
      tol: nil,
      divergence: nil
    }

  # Marks a constellation as a recorded-but-unresolved imgproxy discrepancy. The
  # comparison test tags it `:imgproxy_triage` (excluded by default) so it is
  # skipped rather than failing, while staying visible and runnable via
  # `--include imgproxy_triage`. `reason` carries the tracking issue (#NNN). Not an
  # authored field — it does not affect `Manifest.authored_sha256/1`.
  defp triage(constellation, reason), do: Map.put(constellation, :triage, reason)
end
