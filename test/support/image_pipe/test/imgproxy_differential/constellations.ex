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
      # #194: imgproxy runs a universal cropToResult — scale into the requested box,
      # then crop back to it (gravity center). ImagePipe's fit path lacked it, so the
      # mw/mh min-dimension upscale left the result at 373×280 instead of cropping to
      # 300×280. Fixed in PlanExecutor/Resize (fit result-crop). The centered crop now
      # matches imgproxy's content exactly; the residual pixel delta is libvips-version
      # resampling skew on the high-frequency zone-plate source (max Δ27, zero
      # structural flips). The Δ32 threshold absorbs that skew while still failing any
      # crop misplacement — a 1px shift exceeds Δ32 on >148k band-bytes.
      %{
        c("min_dims_clamp", :high_freq, "rs:fit:300:300/mw:280/mh:280")
        | tol: %{threshold: 32, budget: 64}
      },
      c("zoom_marker", :marker, "z:0.5"),
      # #197: not a placement shift — the differing band-bytes sit in 3 columns at a
      # single sharp red→dark marker edge (max Δ14), with pixels identical on both
      # sides of the edge and the edge at the same x in both. A 1px crop shift would
      # diverge across every edge in the frame (thousands of band-bytes, Δ up to ~210),
      # not 166 at one seam. It is libvips-version anti-aliasing skew at that edge, so
      # the budget is widened (still Δ2; a real crop shift blows far past 256).
      %{
        c("fill_down_marker", :marker, "rs:fill-down:500:500")
        | tol: %{threshold: 2, budget: 256}
      },
      c("gravity_offset_marker", :marker, "rs:fill:120:120/g:no:10:20"),
      c("padding_border", :border, "rs:fit:120:120/pd:10:20"),
      c("extend_small", :small, "rs:fit:300:200/ex:1"),
      c("extend_ar_small", :small, "rs:fit:300:200/exar:1"),
      c("dpr_marker", :marker, "rs:fit:80:80/dpr:2"),
      c("background_alpha", :alpha, "rs:fit:64:64/bg:255:0:0"),
      c("blur_zone", :high_freq, "rs:fit:240:240/bl:3"),
      c("sharpen_zone", :high_freq, "rs:fit:240:240/sh:2"),
      c("strip_exif", :exif_jpeg, "rs:fit:120:120/sm:1"),

      # icc_p3 trim agrees with imgproxy in stored pixels; the trim-detection
      # colorspace difference is behavioral-only (not observable here), so this is
      # an :equal conformance case on a profiled source.
      c("trim_icc_p3", :icc_p3, "t:10"),

      # --- combination constellations: option intersections (the isolated suite
      # crosses none of these) ---
      #
      # extend + absolute gravity offset + dpr. The source (1600×1200) is LARGER
      # than the requested box, so the fit shrink keeps imgproxy's DprScale at the
      # full 2.0 (a source smaller than the target collapses DprScale to 1.0 under
      # enlarge-off, masking the interaction — see prepare.go calcScale). The
      # integer-clean 400×150 box scales the image to exactly 400×300 (no fractional
      # fit rounding, isolating the dpr interaction from [[extend_ar_dpr_marker]]).
      # imgproxy then dpr-scales BOTH the extend target box — TargetWidth =
      # Scale(400, 2) = 800 (prepare.go:176) — and the absolute west offset —
      # offX = RoundToEven(5 × 2) = 10 (calc_position.go:25-35) — so the canvas is
      # 800×300 with the image at x=10, full height. (West + a horizontally-
      # letterboxed image leaves no vertical room, so the y-offset is held at 0 to
      # avoid imgproxy's calcPosition clamp, which ExtendCanvas does not replicate —
      # tracked under the east/south case [[extend_offset_east_marker]].) ImagePipe
      # threaded neither dpr to the canvas op (it produced a 400×300 canvas at x=5);
      # resolved by carrying the canvas-preserving resize scale into ExtendCanvas,
      # the same way padding does.
      c("extend_offset_dpr_marker", :marker, "rs:fit:400:150/ex:1:we:5:0/dpr:2"),
      # extend + EAST gravity + absolute offset. Quarantined (#200): a pre-existing
      # sign divergence the dpr fix does not touch. imgproxy moves the image AWAY
      # from the anchored edge — east: left = width − innerWidth − offX
      # (calc_position.go:44-46) → left = 400 − 200 − 20 = 180. ExtendCanvas anchors
      # right (canvas − image) then ADDS the offset, landing the image past the east
      # edge (clamped by embed). Independent of dpr (shown here at dpr:1); the dpr
      # fix scales the magnitude but not the sign, so it stays quarantined.
      %{
        c("extend_offset_east_marker", :marker, "rs:fit:400:150/ex:1:ea:20:0")
        | triage: %{
            reason: "extend east/south offset sign (adds, should subtract)",
            issue: "#200"
          }
      },
      # extend-aspect-ratio + dpr. Quarantined (#199): the AR canvas dims match
      # (600×400) and the placement is correct, but the centred image is 1px wider
      # than imgproxy's (534 vs 533) — ImagePipe rounds the fit dimension and THEN
      # multiplies by dpr (round(266.67)=267, ×2=534) where imgproxy folds dpr into
      # one scale (round(266.67×2)=533, imath.Scale). One full column (col 567)
      # diverges at Δ255. A general fit+dpr fractional-rounding divergence, not an
      # extend bug; the resize-scale rework is out of scope for this PR.
      %{
        c("extend_ar_dpr_marker", :marker, "rs:fit:300:200/exar:1/dpr:2")
        | triage: %{reason: "fit+dpr separate-rounding 1px width divergence", issue: "#199"}
      },
      # extend + non-center gravity, no dpr. small (120×90) is smaller than the
      # 300×200 box on both axes, so south gravity has real vertical play: the
      # image lands bottom-centre, not centre. Exercises non-center extend
      # placement without the dpr interaction above.
      c("extend_gravity_small", :small, "rs:fit:300:200/ex:1:so"),
      # min-dims + dpr. Exercises #198's result_box effective_dpr path: the mw/mh
      # floor upscales past the dpr-scaled fit box (→ 600×560), so the result crop
      # must compute its box against the effective dpr, not the raw request. Dims
      # match; the residual is a libvips-version resampling seam — 188 band-bytes
      # over Δ2 confined to 2 columns (x=19, x=143) at sharp marker edges, max Δ29,
      # the edges at the SAME x in both (a 1px crop shift would diverge every edge
      # at near-full contrast, thousands of bytes). Budget is set just above the
      # 188-byte seam while KEEPING the strict Δ2 threshold — that rejects a
      # structural shift (which blows the budget) yet absorbs the AA skew, more
      # sensitive than raising the threshold to 32.
      %{
        c("min_dims_dpr_marker", :marker, "rs:fit:300:300/mw:280/mh:280/dpr:2")
        | tol: %{threshold: 2, budget: 256}
      },
      # fit + min-dims + non-center gravity. The fit result-crop (#194) must honor
      # north gravity, cropping the mw/mh-upscaled frame from the top, not center —
      # which it does (a center crop would shift content half the surplus and blow
      # the budget). The residual is the same libvips-version upscale seam as
      # [[min_dims_dpr_marker]]: 94 band-bytes over Δ2 in 2 columns (x=9, x=71), max
      # Δ29, edges unshifted. Budget set just above the seam at the strict Δ2.
      %{
        c("fit_min_dims_gravity_marker", :marker, "rs:fit:300:300/mw:280/mh:280/g:no")
        | tol: %{threshold: 2, budget: 128}
      },
      # cover/fill + min-dims. imgproxy's cropToResult box for the cover path is the
      # literal requested dims (TargetWidth/Height), independent of the mw/mh floor
      # that drove the scale; verifies ImagePipe crops to the same 300×200 box.
      c("cover_min_dims_marker", :marker, "rs:fill:300:200/mw:280/mh:200"),
      # padding + dpr. Padding sides scale by dpr (ScaleToEven), the already-covered
      # interaction for extend; the existing padding_border case has no dpr.
      c("padding_dpr_border", :border, "rs:fit:120:120/pd:10:20/dpr:2"),

      # #124: with scp:0 ImagePipe now imports the P3 source into the sRGB working
      # space before processing and re-embeds the source profile at finalize, exactly
      # like imgproxy. The colorspace divergence is closed, so this is a pixel-equality
      # conformance case on a Display-P3 source.
      c("scp0_colorspace_124", :icc_p3, "rs:fit:200:200/scp:0"),

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

  # `triage: nil` is a non-authored field (see Manifest.@authored_keys): a truthy
  # value quarantines the case behind `--include imgproxy_triage` without touching
  # the authored hash, so quarantining alone needs no reauthor.
  defp c(id, source, opts),
    do: %{
      id: id,
      source: source,
      opts: opts,
      verdict: :equal,
      group: :transform,
      tol: nil,
      divergence: nil,
      triage: nil
    }

  defp lossy(id, source, opts),
    do: %{
      id: id,
      source: source,
      opts: opts,
      verdict: :equal,
      group: :lossy,
      tol: nil,
      divergence: nil,
      triage: nil
    }
end
