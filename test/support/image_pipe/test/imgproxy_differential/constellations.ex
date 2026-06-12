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
    exif_2: "exif_2.jpg",
    exif_3: "exif_3.jpg",
    exif_4: "exif_4.jpg",
    exif_5: "exif_5.jpg",
    exif_6: "exif_6.jpg",
    exif_7: "exif_7.jpg",
    exif_8: "exif_8.jpg",
    icc_p3: "icc_p3.png",
    small: "small.png",
    cmyk: "cmyk.jpg",
    rgb16: "rgb16.png",
    rgba16: "rgba16.png"
  }

  @doc "Map of `source` atom -> committed source filename."
  def source_files, do: @source_files

  @default_tol %{threshold: 2, budget: 64}

  @doc """
  Tolerance applied to a `:equal` constellation that carries no explicit `:tol`
  (`%{threshold: 2, budget: 64}` — strict Δ2, small budget). The conformance test,
  `gen_report`, and `diagnose` all read this so the default can't drift between them.
  """
  def default_tol, do: @default_tol

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
      c("rotate_exif", :exif_6, "rs:fit:120:120"),
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
      c("strip_exif", :exif_6, "rs:fit:120:120/sm:1"),

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
      # extend + EAST gravity + absolute offset. imgproxy moves the image AWAY from
      # the anchored edge — east: left = width − innerWidth − offX
      # (calc_position.go:44-46) → left = 400 − 200 − 20 = 180 — and clamps the origin
      # to [0, outer − inner] (allowOverflow=false). ExtendCanvas now subtracts the
      # offset for right/bottom anchors and clamps to match (#200).
      c("extend_offset_east_marker", :marker, "rs:fit:400:150/ex:1:ea:20:0"),
      # extend-aspect-ratio + dpr. The AR canvas (600×400) and placement match, and
      # the centred image is now 533px wide (not 534): ImagePipe folds dpr into the
      # single resize scale (round(266.67×2)=533, imath.Scale) instead of rounding the
      # fit dimension first (#199). With the dims aligned the residual is the same
      # libvips-version resampling seam as [[min_dims_dpr_marker]]: 201 band-bytes over
      # Δ2 confined to 3 columns (x=100, x=188-190) at sharp marker edges, max Δ28,
      # spread vertically along the edges (a 1px structural shift would instead diverge
      # every edge at near-full contrast — thousands of bytes — and blow the budget).
      # Budget set just above the seam while KEEPING the strict Δ2 threshold.
      %{
        c("extend_ar_dpr_marker", :marker, "rs:fit:300:200/exar:1/dpr:2")
        | tol: %{threshold: 2, budget: 256}
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

      # --- #203 Tier 1: high-yield combination seams (existing sources) ---
      #
      # T1.1: EXIF quarter-turn × asymmetric cover. exif_6 is storage 400×300 /
      # display 300×400; the existing rotate_exif is a symmetric fit and can't expose
      # the per-axis storage↔display compensation that an asymmetric cover does.
      c("exif_cover_asym", :exif_6, "rs:fill:200:150"),
      # T1.2: EXIF quarter-turn × non-center INLINE crop gravity (c:W:H:TYPE, not the
      # inert result-gravity form). North crop gravity must rotate into the storage
      # frame before the quarter turn.
      c("exif_crop_north", :exif_6, "c:200:120:no"),
      # T1.3: EXIF × extend with non-center gravity. Extend runs post-orientation-flush
      # in the display frame, fed by the compensated resize dims; south gravity places
      # the fit-scaled image in the 200×200 canvas. The square 200:200 box downscales the
      # rotated block more than the sibling 200:300 extend_so cases, surfacing the same
      # libvips-version downscale skew the landscape exif_2/3/4_extend_so cases show:
      # maxΔ=16, 0 band-bytes over Δ16, image in the correct post-orientation quadrant.
      # Δ32/budget-64 absorbs the version skew (the exif-extend convention) while a 1px
      # block-edge shift (Δ≈160 over the block perimeter) blows the budget.
      %{
        c("exif_extend_south", :exif_6, "rs:fit:200:200/ex:1:so")
        | tol: %{threshold: 32, budget: 64}
      },
      # T1.4: #124 colorspace import compounded with a blur. scp:0 alone is already a
      # PASS (scp0_colorspace_124) since #124 imports the P3 source into the working
      # space before processing, exactly like imgproxy — so the blur runs in the same
      # space on both sides. Authored :equal (the issue's DIVERGE prediction predates
      # the #124 close); the bake confirms or refutes.
      c("scp0_blur_icc_p3", :icc_p3, "rs:fit:200:200/scp:0/bl:3"),
      # T1.5: alpha-flatten × transparent extend-padding × background. Does the
      # (0,0,0,0) extend padding composite onto bg the same way the source's own alpha
      # does? Forced PNG keeps it pixel-claimable.
      c("alpha_extend_bg", :alpha, "rs:fit:64:64/ex:1/bg:255:0:0"),
      # T1.6: generalize the #199 fit+dpr rounding fold through a SECOND wrapper
      # (extend, not exar) with a fractional fit dim. Since #199 landed (#218) the
      # fit/zoom/dpr fold into one imath.Scale per axis, so this is a PASS-confirmation
      # that the fold isn't exar-specific. The residual is the identical libvips-version
      # edge-AA seam as [[extend_ar_dpr_marker]]: 201 band-bytes over Δ2, maxΔ=28, 0 over
      # Δ32 — confined to sharp marker edges. Budget set just above the seam KEEPING the
      # strict Δ2 threshold (a 1px structural shift diverges every edge and blows it).
      %{
        c("extend_dpr_fractional_marker", :marker, "rs:fit:300:200/ex:1/dpr:2")
        | tol: %{threshold: 2, budget: 256}
      },
      # T1.7: corner extend compounds #200 on BOTH axes. small (120×90) with enlarge-off
      # stays inside the 400×300 canvas, so the SE-corner offset has real play on the
      # east AND south anchors simultaneously (a marker source fills a 4:3 box exactly,
      # leaving the offset inert) — a stronger pin than the single-axis
      # extend_offset_east_marker. PASS-confirmation since #200 landed (#218).
      c("extend_corner_offset_small", :small, "rs:fit:400:300/ex:1:soea:20:20"),
      # #220: the INERT-extend sibling of T1.7. marker (1600×1200, 4:3) fits the
      # 4:3 box exactly (scale 0.25 → 400×300 == the ex:1 target), so the soea
      # offset clamps to 0 and no border is added. imgproxy's extendImage() returns
      # early (`width <= imgWidth && height <= imgHeight`) leaving the untouched
      # 3-band RGB; ExtendCanvas previously still ran Image.embed and emitted 4-band
      # RGBA (a band-layout FINDING, not pixel-comparable). The no-op short-circuit
      # closes it — both sides are now the 3-band fit result, so this pins band parity.
      c("extend_inert_marker", :marker, "rs:fit:400:300/ex:1:soea:20:20"),
      # T1.8: EXIF-6 ∘ user rot:90 compose (#146 deferred PendingOrientation). After
      # #211/#219 the rotation-primitive seam is gone and the harder transpose/transverse
      # ∘ rot:90 already passes, so this quarter-turn ∘ quarter-turn is a PASS-confirmation.
      c("exif_user_rot90", :exif_6, "rot:90"),
      # T1.9: user-rotate branch of inline crop-gravity compensation — same seam as T1.2
      # but driven by the user rotate input (crop.go adjusts CropGravity for user
      # rotate/flip too). Rotation-primitive seam excluded by #219, so any divergence is
      # genuine CropGravity user-rotate compensation.
      c("rot90_crop_north_marker", :marker, "rot:90/c:200:120:no"),

      # --- #203 Tier 2: coverage completeness (mostly PASS-confirmations) ---
      #
      # T2.1: inline crop EAST offset — confirms #200 does NOT generalize to the crop
      # path (imgproxy feeds calcPosition→Crop directly with the correct sign).
      c("crop_east_offset_marker", :marker, "c:300:200:ea:20:0"),
      # T2.2: cover result-crop SOUTH offset — same #200-non-generalization confirmation
      # for the cropToResult path.
      c("cover_gravity_south_offset_marker", :marker, "rs:fill:300:200/g:so:0:20"),
      # T2.3: focal-point INLINE crop gravity (fp on the crop path, untested in the
      # suite). calc_position ScaleToEven vs crop.ex round-ties-to-even.
      c("crop_focal_marker", :marker, "c:200:200:fp:0.3:0.7"),
      # T2.4: odd-gap center origin in the cover result-crop. marker 1600×1200 fill
      # 300×200 cover-scales to 300×225 (gap 25 on height — ODD), center gravity; checks
      # ShrinkToEven(outer−inner+1,2) is wired into result-crop, generalizing #195/#196
      # beyond extend.
      c("cover_odd_gap_center_marker", :marker, "rs:fill:300:200/g:ce"),
      # T2.5: trim × shrink-on-load suppression cross. trim nils ImgData before
      # scaleOnLoad, so the fit can't shrink-on-load and resamples from full resolution;
      # tested only in isolation before. Both sides agree on the trimmed box and the fit
      # scale (dims match at 267×200), so the residual is pure resampling-path skew on the
      # zone-plate source — the worst-case resampling cell in the suite. maxΔ=42 (≪ the
      # ~255 a misaligned full-contrast ring would show), spread diffusely across the
      # plate. Threshold set just above that 42 skew ceiling with a tight budget: a
      # structural crop/scale shift misaligns the center rings (maxΔ→~255, thousands of
      # band-bytes) and blows budget 64, while the diffuse AA skew clears it.
      %{
        c("trim_resize_high_freq", :high_freq, "t:10/rs:fit:300:200")
        | tol: %{threshold: 48, budget: 64}
      },
      # T2.6: enlarge-off DprScale collapse under forced min-dim upscale. small
      # (120×90) is smaller than the target, so DprScale collapses to 1.0 while mw/mh
      # force an upscale (#198 result_box effective_dpr path).
      c("min_dims_dpr_enlarge_off_small", :small, "rs:fit:100:100/mw:200/mh:200/dpr:2"),
      # T2.7: padding × extend stacking. small + enlarge-off keeps the fit at 120×90, so
      # ex:1 genuinely extends to the 200×150 box (live, not inert) and pd:20 then stacks
      # on top — both canvas ops compose.
      c("extend_padding_stack_small", :small, "rs:fit:200:150/ex:1/pd:20"),
      # T2.8: crop + resize with BOTH gravities live — inline crop gravity north
      # (c:1000:1000:no, the source window) and result gravity south (g:so, the cover
      # window). The most common real shape; zero prior coverage of the two-gravity chain.
      c("crop_resize_two_gravities_marker", :marker, "c:1000:1000:no/rs:fill:300:200/g:so"),
      # T2.9: corner gravity on the cover result-crop (calcPosition corner placement).
      c("cover_corner_gravity_marker", :marker, "rs:fill:300:300/g:noea"),
      # T2.10: focal-point on the cover result-crop (fp tested on crop in T2.3; untested
      # on the result-crop site).
      c("cover_focal_marker", :marker, "rs:fill:300:300/g:fp:0.2:0.8"),
      # T2.11: fill-down + non-center (corner) gravity — only center fill-down today.
      # The residual is the identical libvips-version anti-aliasing seam as
      # [[fill_down_marker]]: 166 band-bytes over Δ2 at one sharp marker edge, maxΔ=14,
      # the edge at the same position in both. Strict Δ2 threshold, budget widened just
      # over the seam (a real crop shift blows far past 256).
      %{
        c("fill_down_corner_gravity_marker", :marker, "rs:fill-down:500:500/g:soea")
        | tol: %{threshold: 2, budget: 256}
      },
      # T2.12: force resize (stretch; no aspect preservation, no result-crop — a
      # distinct code path), untested entirely.
      c("force_resize_marker", :marker, "rs:force:300:200"),
      # T2.13: auto resize (picks fit/fill by source vs target orientation), untested
      # entirely. Landscape source into a portrait target.
      c("auto_resize_marker", :marker, "rs:auto:200:300"),
      # #233: auto resize square↔landscape. imgproxy buckets fill-vs-fit by the SIGN of
      # width−height, with square (diff == 0) in the non-negative (landscape) bucket, so
      # both directions FILL (cover + result-crop) rather than fit. ImagePipe used a
      # three-class (landscape/portrait/square) exact-match classifier that fit these
      # cells; this pins the corrected sign bucketing. Landscape source (1600×1200) into a
      # square target covers to 300×300; square source (512×512) into a landscape target
      # covers to 300×200 (scp:0 strips the P3 profile so only geometry is compared).
      c("auto_resize_square_target_marker", :marker, "rs:auto:300:300"),
      c("auto_resize_square_source_icc", :icc_p3, "rs:auto:300:200/scp:0"),
      # T2.14: inline pre-resize crop corner, no resize — the genuine c:W:H:TYPE corner
      # form on the crop path.
      c("crop_corner_marker", :marker, "c:600:600:soea"),
      # T2.15: user rot:180 half-turn baseline (no axis swap). De-risked by #211/#219 —
      # the affine primitive seamed even at 180°, now fixed (vips_rot).
      c("user_rot180_marker", :marker, "rot:180"),
      # T2.16: horizontal / vertical flip alone (horizontal streams, vertical
      # materializes). fl:1 = horizontal, fl:0:1 = vertical.
      c("flip_h_marker", :marker, "fl:1"),
      c("flip_v_marker", :marker, "fl:0:1"),
      # T2.17: user rotate ∘ flip suborder compose (rotation-primitive seam excluded by
      # #219, so a divergence would be genuine suborder).
      c("rot90_flip_h_marker", :marker, "rot:90/fl:1"),
      # T2.18: EXIF-6 ∘ user-flip compose (flip never used the affine path, so
      # unaffected by #211/#219 — this exercises the EXIF ∘ user-flip suborder directly).
      c("exif_user_flip_h", :exif_6, "fl:1"),

      # --- #226: gravity × placement-site coverage tail (west crop/cover, north
      # extend, smart pre-resize crop) ---
      #
      # PASS-confirmations filling anchor × site cells #203's triage table left open.
      # The placement bugs that motivated the table (#194 cropToResult box, #195/#196
      # extend center origin, #200 extend offset sign/clamp) are all fixed and every
      # anchor/site is exercised somewhere, so a divergence here is a genuine
      # site-specific calcPosition bug, not yield.
      #
      # West on the pre-resize crop site (c:W:H:TYPE). marker 1600×1200, a 300×200
      # window anchored west → left=0, vertically centered (top=500). West has 1300px of
      # horizontal play here, so a left/center confusion shifts the window across sharp
      # marker edges (maxΔ→~255) — unlike the cover/extend sites whose box aspect can
      # leave the west anchor inert.
      c("crop_west_marker", :marker, "c:300:200:we"),
      # West on the cover result-crop site (rs:fill/g:TYPE). The box is PORTRAIT (200×300)
      # so the cover surplus is horizontal: marker 4:3 covers 200×300 at scale 0.25 →
      # 400×300, and the 200-wide result-crop has 200px of horizontal play. West → left=0
      # (the left half of the cover). A landscape box (e.g. 300×200) leaves only vertical
      # surplus, making west inert — so the box puts the west anchor on a live axis.
      c("cover_west_gravity_marker", :marker, "rs:fill:200:300/g:we"),
      # North on the extend site — the exact vertical mirror of [[extend_gravity_small]]
      # (south). small (120×90) with enlarge-off stays 120×90 inside the 300×200 canvas,
      # so north has real vertical play (110px) and anchors the image to the top (y=0),
      # not the centre. extend already covers south/east/west/soea but never the top.
      c("extend_gravity_north_small", :small, "rs:fit:300:200/ex:1:no"),
      # Smart (attention) crop on the pre-resize crop site (c:W:H:sm). The two libvips
      # versions pick the SAME salient window on the sharp marker source — the bake is an
      # exact match (maxΔ=0), so it holds at the strict default Δ2/64. Smart crop is still
      # attention-skew-prone (the #203 T3.8 caveat), so a future regression here is most
      # likely a libvips-version attention difference picking a different window: that is a
      # structural divergence to quarantine (`:triage` + a tracking issue), never a tol to
      # widen.
      c("crop_smart_marker", :marker, "c:300:300:sm"),

      # --- #224 Part 1: the OSS-bakeable effect (pixelate) ---
      #
      # Before #224 the suite exercised only `blur` and `sharpen` of the stage-9
      # `applyFilters` family. `pixelate` (`pix`) is the one remaining OSS-supported
      # effect — imgproxy's `apply_filters.go` applies exactly {blur, sharpen,
      # pixelate}; brightness/contrast/saturation/monochrome/duotone are imgproxy-Pro
      # (absent from the OSS `darthsim/imgproxy` container's option keys), so they are
      # not differential gaps and stay out of this suite, like `cp`/`icc`. `pix:8` on
      # the sharp-edged marker is a plain libvips block-average both sides also call.
      # The block boundaries align (maxΔ=14, ≪ the ~210 a 1px-misaligned block would
      # show as it straddles a sharp marker edge); the residual is diffuse
      # block-average rounding/libvips-version skew, every delta in (Δ2, Δ16] over
      # ~23k band-bytes, 0 over Δ16. Threshold set just above the 14 skew ceiling with
      # a tight budget — the heavy-downscale convention — so a real block-offset (which
      # pushes bytes past Δ16 at the edges) blows it.
      %{
        c("pixelate_marker", :marker, "pix:8")
        | tol: %{threshold: 16, budget: 64}
      },
      # The OSS-valid effects-chain ORDER pin. The issue's pix→br→co→sa form is Pro
      # (br/co/sa), but the three OSS filters stack in a fixed stage-9 order both
      # sides share — imgproxy `apply_filters.go`/`vips.c` runs blur → sharpen →
      # pixelate, and ImagePipe's `effect_operations` emits the same blur → sharpen →
      # pixelate (URL option order is inert; the plan fixes it). Stacking all three on
      # the zone-plate source pins that ordering end-to-end: a reordered chain (e.g.
      # pixelate before blur/sharpen) would composite a grossly different image (maxΔ
      # into the 100s across the frame), where the measured residual is diffuse
      # zone-plate block/resample skew (maxΔ=36, ≪255). Threshold set just above that
      # skew ceiling with a tight budget — the zone-plate convention — so the order is
      # held while libvips-version skew is absorbed.
      %{
        c("effects_chain_order_high_freq", :high_freq, "rs:fit:240:240/bl:2/sh:2/pix:8")
        | tol: %{threshold: 40, budget: 64}
      },

      # --- #224 Part 2: the three zero-fixture committed sources ---
      #
      # cmyk.jpg is a 120×90 CMYK JPEG. `rs:fit:200:200` is a no-op resize (fit
      # without enlarge leaves the smaller source unscaled), so the pixel claim is the
      # PURE stage-4 colorspaceToProcessing CMYK→sRGB working-space import — no
      # resampling confound. The import is unconditional (support-matrix stage 4), and
      # distinct from `cp:cmyk` CMYK *output* targeting (#214).
      c("cmyk_import", :cmyk, "rs:fit:200:200"),
      # rgb16/rgba16 are 512×512 16-bit PNGs. `ph:1` preserves the high bit-depth
      # through to the PNG output (the #121 preserve-HDR path), `ph:0` tone-maps to
      # 8-bit — the two halves of the HDR pipeline, neither covered before. The
      # 512→200 fit genuinely downscales, so each is import + 16-bit (or tone-mapped)
      # resample + PNG round-trip. The alpha source additionally exercises the 16-bit
      # RGBA path.
      c("rgb16_preserve_hdr", :rgb16, "ph:1/rs:fit:200:200"),
      c("rgb16_tonemap_8bit", :rgb16, "ph:0/rs:fit:200:200"),
      # rgba16_preserve_hdr DIVERGES (quarantined → #229). The source alpha is
      # uniformly fully opaque (min=max=65535); ImagePipe preserves it pristine
      # (live alpha a constant 65535), while imgproxy's ph:1 16-bit RGBA path
      # perturbs it (fixture alpha avg 65435, down to ~65311 — maxΔ 224/65535 ≈
      # 0.34%). The RGB bands match to Δ1, so the visible image agrees; only the
      # alpha band differs, and ImagePipe is the more-correct side. The conformance
      # tol model can't fairly judge it either: it decomposes the 16-bit USHORT band
      # into hi/lo bytes, so a 0.34% real alpha delta surfaces as Δ224 in the LOW
      # byte across the whole band — an 8-bit Δ-threshold/budget can't express a
      # 16-bit tolerance (a harness limitation independent of the alpha quirk).
      # Tracked under #229; imgproxy still bakes the fixture so the gap stays
      # measured — distinct from #222 (a metadata/band-LAYOUT contract layer, blind
      # to pixel values) and #220 (a spurious alpha CHANNEL). The rgb16 (no
      # alpha) preserve case above is a clean PASS, covering the core 16-bit PNG
      # round-trip; the rgba16 TONEMAP case below also PASSES (8-bit, alpha 255 both
      # sides).
      %{
        c("rgba16_preserve_hdr", :rgba16, "ph:1/rs:fit:200:200")
        | verdict: :diverges,
          divergence: %{metric: :fraction_over, threshold: 32, floor: 0.05},
          triage: %{
            reason:
              "imgproxy perturbs a fully-opaque 16-bit alpha (maxΔ 224/65535); ImagePipe " <>
                "preserves it. 8-bit band-byte tol can't express a 16-bit-channel tolerance.",
            issue: "#229"
          }
      },
      c("rgba16_tonemap_8bit", :rgba16, "ph:0/rs:fit:200:200"),

      # --- lossy group: contract-only (dims/content-type/decode), no pixel claim ---
      lossy("lossy_webp", :high_freq_webp, "rs:fill:240:180/f:webp"),
      lossy("lossy_jpeg_q40", :high_freq, "rs:fill:240:180/q:40/f:jpg"),
      lossy("lossy_avif", :high_freq, "rs:fill:240:180/f:avif")
    ] ++ exif_orientation_constellations()
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

  # --- #204: EXIF orientation source fixtures (2/3/4/5/7/8) ---
  #
  # Each orientation is the same 400×300 corner-block base retagged with a
  # different EXIF Orientation. The Batch-A shape (cover / non-center crop /
  # extend-with-gravity) hits the per-axis storage↔display dims, the crop-gravity
  # rotate-into-storage, and the post-flush gravity seams respectively. The extend
  # target is 200:300 (not square) so south gravity keeps real vertical play on the
  # portrait-display quarter-turns. 5/7 (transpose/transverse) additionally cross
  # with a user op (rot/flip) — the deepest #146 compose, flip ∘ quarter-turn ∘
  # user-op. Orientation 6 is omitted from the sweep — it is already covered by
  # the `rotate_exif`/`strip_exif` cases above (its source `:exif_6` lives in
  # `@source_files` for them).
  @exif_orientations [2, 3, 4, 5, 7, 8]

  defp exif_orientation_constellations do
    cover_crop =
      for o <- @exif_orientations, {suffix, opts} <- exif_base_seams() do
        c("exif_#{o}_#{suffix}", :"exif_#{o}", opts)
      end

    cover_crop ++ exif_extend_constellations() ++ exif_transpose_crosses()
  end

  # cover + non-center crop are a clean 6×2 cross-product (uniform per-orientation
  # intent — see the family comment above). extend_so is listed explicitly because
  # its libvips skew profile differs by orientation class.
  defp exif_base_seams do
    [
      {"cover", "rs:fill:200:150"},
      {"crop_no", "c:200:120/g:no"}
    ]
  end

  # extend_so seam. 5/7/8 (axis-swap → portrait display, fit width-bound, ~33px of
  # south play) match imgproxy at the default tol. 2/3/4 (landscape display, 150px
  # of south play) show diffuse libvips-version downscale skew over the scaled
  # blue-block region: max Δ16, the flat ground and extend background pixel-perfect,
  # and the block in the correct post-orientation quadrant (flip-H→right,
  # 180→right-bottom, flip-V→left-bottom) — a placement bug would land it elsewhere
  # or leave a sharp high-Δ edge, neither of which is present. 0 band-bytes over Δ32,
  # so Δ32/budget-64 absorbs the version skew while a 1px block-edge shift (Δ≈160
  # over the ~350px block perimeter) blows the budget — the min_dims_clamp rationale.
  defp exif_extend_constellations do
    skew = %{threshold: 32, budget: 64}

    [
      %{c("exif_2_extend_so", :exif_2, "rs:fit:200:300/ex:1:so") | tol: skew},
      %{c("exif_3_extend_so", :exif_3, "rs:fit:200:300/ex:1:so") | tol: skew},
      %{c("exif_4_extend_so", :exif_4, "rs:fit:200:300/ex:1:so") | tol: skew},
      c("exif_5_extend_so", :exif_5, "rs:fit:200:300/ex:1:so"),
      c("exif_7_extend_so", :exif_7, "rs:fit:200:300/ex:1:so"),
      c("exif_8_extend_so", :exif_8, "rs:fit:200:300/ex:1:so")
    ]
  end

  defp exif_transpose_crosses do
    [
      # EXIF transpose/transverse ∘ user rot:90 — the deepest #146 compose path
      # (axis-swapping EXIF stacked with an axis-swapping user rotate). The user
      # rotate now flushes via the exact `vips_rot` instead of Image.rotate/2's
      # affine resampler, which had left a 1px black edge seam (#211).
      c("exif_5_cover_rot90", :exif_5, "rs:fill:200:150/rot:90"),
      c("exif_7_cover_rot90", :exif_7, "rs:fill:200:150/rot:90"),
      c("exif_5_cover_fl", :exif_5, "rs:fill:200:150/fl:1"),
      c("exif_7_cover_fl", :exif_7, "rs:fill:200:150/fl:1")
    ]
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
