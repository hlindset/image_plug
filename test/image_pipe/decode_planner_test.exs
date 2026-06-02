defmodule ImagePipe.Transform.DecodePlannerTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.AutoOrient
  alias ImagePipe.Transform.DecodePlanner

  # --- Access selection (unchanged logic, now via 3-arg form) ---

  test "empty chain opens randomly with fail_on error regardless of format" do
    opts = DecodePlanner.open_options([], :jpeg, {3000, 2000})
    assert opts[:access] == :random
    assert opts[:fail_on] == :error
  end

  test "width-only fit resize opens sequentially" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 120}, :auto)
    opts = DecodePlanner.open_options([resize], :jpeg, {3000, 2000})
    assert opts[:access] == :sequential
  end

  test "height-only fit resize opens sequentially" do
    assert {:ok, resize} = Operation.resize(:fit, :auto, {:px, 120})
    opts = DecodePlanner.open_options([resize], :jpeg, {2000, 3000})
    assert opts[:access] == :sequential
  end

  test "auto-orient-only chains open sequentially" do
    opts = DecodePlanner.open_options([%AutoOrient{}], :jpeg, {3000, 2000})
    assert opts[:access] == :sequential
  end

  test "color-profile normalization is access-neutral (alone: random; with sequential: sequential)" do
    neutral_only =
      DecodePlanner.open_options([%Operation.NormalizeColorProfile{}], :png, {100, 100})

    assert neutral_only[:access] == :random

    with_sequential =
      DecodePlanner.open_options(
        [%AutoOrient{}, %Operation.NormalizeColorProfile{}],
        :png,
        {100, 100}
      )

    assert with_sequential[:access] == :sequential
  end

  test "crops stay random" do
    assert {:ok, crop} = Operation.crop_guided({:px, 80}, {:px, 80}, :center)
    opts = DecodePlanner.open_options([crop], :jpeg, {3000, 2000})
    assert opts[:access] == :random
  end

  # --- JPEG shrink-on-load ---

  test "JPEG shrink is quantized to largest power of 2 not exceeding load_shrink" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 400}, :auto)

    # src_w=3200, target_w=400 → load_shrink=8.0 → shrink 8
    opts8 = DecodePlanner.open_options([resize], :jpeg, {3200, 2400})
    assert opts8[:shrink] == 8

    # src_w=3000, target_w=400 → load_shrink=7.5 → shrink 4 (not 8)
    opts4 = DecodePlanner.open_options([resize], :jpeg, {3000, 2000})
    assert opts4[:shrink] == 4

    # src_w=1000, target_w=400 → load_shrink=2.5 → shrink 2
    opts2 = DecodePlanner.open_options([resize], :jpeg, {1000, 800})
    assert opts2[:shrink] == 2

    # src_w=600, target_w=400 → load_shrink=1.5 → shrink 1 (no shrink key)
    opts1 = DecodePlanner.open_options([resize], :jpeg, {600, 400})
    refute Keyword.has_key?(opts1, :shrink)
    refute Keyword.has_key?(opts1, :scale)
  end

  test "JPEG shrink uses min(wshrink, hshrink) to avoid over-shrinking" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 400}, {:px, 600})
    # src={3200,2400}, target={400,600} → wshrink=8, hshrink=4 → min=4
    opts = DecodePlanner.open_options([resize], :jpeg, {3200, 2400})
    assert opts[:shrink] == 4
  end

  test "JPEG width-only resize uses wshrink only (no hshrink constraint)" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 100}, :auto)
    # src_w=1600 → wshrink=16 → capped at 8
    opts = DecodePlanner.open_options([resize], :jpeg, {1600, 1200})
    assert opts[:shrink] == 8
  end

  test "JPEG height-only resize uses hshrink only" do
    assert {:ok, resize} = Operation.resize(:fit, :auto, {:px, 100})
    # src_h=1600 → hshrink=16 → capped at 8
    opts = DecodePlanner.open_options([resize], :jpeg, {1200, 1600})
    assert opts[:shrink] == 8
  end

  test "JPEG cover-mode resize is also shrink-eligible" do
    assert {:ok, resize} = Operation.resize(:cover, {:px, 200}, {:px, 200})
    # src={1600,1200}, target={200,200} → wshrink=8, hshrink=6 → min=6 → shrink 4
    opts = DecodePlanner.open_options([resize], :jpeg, {1600, 1200})
    assert opts[:shrink] == 4
  end

  test "JPEG auto×auto resize emits no shrink" do
    assert {:ok, resize} = Operation.resize(:fit, :auto, :auto)
    opts = DecodePlanner.open_options([resize], :jpeg, {3000, 2000})
    refute Keyword.has_key?(opts, :shrink)
  end

  test "JPEG shrink arithmetic operates on the dims it is handed" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 400}, :auto)
    # 1200/400 = 3.0 → shrink 2
    opts = DecodePlanner.open_options([resize], :jpeg, {1200, 800})
    assert opts[:shrink] == 2
  end

  test "EXIF quarter-turn swaps the shrink axes only when the chain auto-orients" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 400}, :auto)
    # Stored landscape 800×1200... no, stored 3200×800; width-only target 400.
    # Without the swap: wshrink = 3200/400 = 8 → shrink 8.
    # With the swap (axes become 800×3200): wshrink = 800/400 = 2 → shrink 2.
    chain = [%AutoOrient{}, resize]

    # Quarter-turn EXIF + AutoOrient present → swap → shrink computed on 800 width.
    swapped = DecodePlanner.open_options(chain, :jpeg, {3200, 800}, true)
    assert swapped[:shrink] == 2

    # Quarter-turn EXIF but NO AutoOrient in the chain → no swap → shrink on 3200.
    no_autoorient = DecodePlanner.open_options([resize], :jpeg, {3200, 800}, true)
    assert no_autoorient[:shrink] == 8

    # AutoOrient present but EXIF is not a quarter-turn → no swap.
    not_quarter = DecodePlanner.open_options(chain, :jpeg, {3200, 800}, false)
    assert not_quarter[:shrink] == 8
  end

  # --- WebP scale-on-load ---

  test "WebP gets fractional scale for large downscales" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 200}, :auto)
    # src_w=1600, target=200 → load_shrink=8.0 → scale=1/8=0.125
    opts = DecodePlanner.open_options([resize], :webp, {1600, 1200})
    assert_in_delta opts[:scale], 1.0 / 8.0, 0.001
    refute Keyword.has_key?(opts, :shrink)
  end

  test "WebP emits no scale when load_shrink <= 1" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 800}, :auto)
    opts = DecodePlanner.open_options([resize], :webp, {600, 400})
    refute Keyword.has_key?(opts, :scale)
    refute Keyword.has_key?(opts, :shrink)
  end

  # --- Over-shrink guards: the load shrink must never decode below the target ---

  test "dpr inflates the shrink target so the decode is not over-shrunk" do
    # src_w 4000, w 444, dpr 3 -> effective target 1332 -> wshrink 3.0 -> shrink 2
    # (Without accounting for dpr this would be 4000/444 ≈ 9 -> shrink 8, decoding
    # 500px and forcing the residual resize to upscale to 1332.)
    assert {:ok, resize} = Operation.resize(:fit, {:px, 444}, :auto, dpr: 3, enlargement: :allow)
    opts = DecodePlanner.open_options([resize], :jpeg, {4000, 2667})
    assert opts[:shrink] == 2
  end

  test "zoom inflates the shrink target so the decode is not over-shrunk" do
    # src_w 4000, w 200, zoom 4 -> effective target 800 -> wshrink 5.0 -> shrink 4
    assert {:ok, resize} = Operation.resize(:fit, {:px, 200}, :auto, zoom_x: 4.0, zoom_y: 4.0)
    opts = DecodePlanner.open_options([resize], :jpeg, {4000, 2667})
    assert opts[:shrink] == 4
  end

  test "min_width/min_height disable shrink (they enlarge to a floor, not a simple multiplier)" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 100}, :auto, min_width: {:px, 2000})
    opts = DecodePlanner.open_options([resize], :jpeg, {4000, 2667})
    refute Keyword.has_key?(opts, :shrink)
  end

  test "a crop before the resize disables shrink (cropped working set, not full source)" do
    assert {:ok, crop} = Operation.crop_region({:px, 0}, {:px, 0}, {:px, 600}, {:px, 600})
    assert {:ok, resize} = Operation.resize(:fit, {:px, 500}, {:px, 500})
    opts = DecodePlanner.open_options([crop, resize], :jpeg, {4000, 2667})
    refute Keyword.has_key?(opts, :shrink)
    refute Keyword.has_key?(opts, :scale)
  end

  test "a crop AFTER the resize (cover-style) does not disable shrink" do
    # cover is a single PlanResize that crops internally after resizing, so it is
    # not a crop-before-resize and remains shrink-eligible.
    assert {:ok, resize} = Operation.resize(:cover, {:px, 200}, {:px, 200})
    opts = DecodePlanner.open_options([resize], :jpeg, {1600, 1200})
    assert opts[:shrink] == 4
  end

  # --- Non-shrink-eligible formats ---

  test "PNG emits no shrink or scale regardless of target" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 10}, :auto)
    opts = DecodePlanner.open_options([resize], :png, {3000, 2000})
    refute Keyword.has_key?(opts, :shrink)
    refute Keyword.has_key?(opts, :scale)
    assert opts[:access] == :sequential
    assert opts[:fail_on] == :error
  end

  test "HEIF/AVIF emit no shrink or scale" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 10}, :auto)
    refute DecodePlanner.open_options([resize], :heif, {3000, 2000}) |> Keyword.has_key?(:shrink)
    refute DecodePlanner.open_options([resize], :avif, {3000, 2000}) |> Keyword.has_key?(:shrink)
  end

  test "unknown format emits no shrink or scale" do
    assert {:ok, resize} = Operation.resize(:fit, {:px, 10}, :auto)
    opts = DecodePlanner.open_options([resize], :some_unknown_format, {3000, 2000})
    refute Keyword.has_key?(opts, :shrink)
    refute Keyword.has_key?(opts, :scale)
  end

  # --- No-resize chain ---

  test "non-resize operations produce no shrink option for JPEG" do
    assert {:ok, blur} = Operation.blur(2.0)
    opts = DecodePlanner.open_options([blur], :jpeg, {3000, 2000})
    refute Keyword.has_key?(opts, :shrink)
  end

  # --- Legacy behavior: composition and effect operations ---

  test "composition operations force random access (no shrink for random-only ops)" do
    assert {:ok, padding} = Operation.padding({:px, 1}, {:px, 0}, {:px, 0}, {:px, 0})
    opts = DecodePlanner.open_options([padding], :jpeg, {3000, 2000})
    assert opts[:access] == :random
  end
end
