defmodule ImagePipe.Transform.OrientationTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.Orientation, as: O

  describe "compensate_gravity/4 — directional remap (offsets 0)" do
    test "anchor types remap under 90/180/270" do
      assert O.compensate_gravity({:anchor, :center, :top}, 90, false, false) ==
               {:anchor, :left, :center}

      assert O.compensate_gravity({:anchor, :center, :top}, 180, false, false) ==
               {:anchor, :center, :bottom}

      assert O.compensate_gravity({:anchor, :center, :top}, 270, false, false) ==
               {:anchor, :right, :center}
    end

    test "corner antipode at 180" do
      assert O.compensate_gravity({:anchor, :left, :top}, 180, false, false) ==
               {:anchor, :right, :bottom}
    end

    test "flipX swaps left/right; flipY swaps top/bottom" do
      assert O.compensate_gravity({:anchor, :left, :top}, 0, true, false) ==
               {:anchor, :right, :top}

      assert O.compensate_gravity({:anchor, :left, :top}, 0, false, true) ==
               {:anchor, :left, :bottom}
    end
  end

  describe "compensate_gravity/4 — focus point" do
    test "90° maps (x,y) -> (y, 1-x)" do
      assert O.compensate_gravity({:fp, 0.25, 0.10}, 90, false, false) == {:fp, 0.10, 0.75}
    end

    test "flipX maps x -> 1-x" do
      assert O.compensate_gravity({:fp, 0.25, 0.10}, 0, true, false) == {:fp, 0.75, 0.10}
    end
  end

  describe "compensate_gravity/4 — never-remapped types" do
    test "smart/detect pass through unchanged" do
      assert O.compensate_gravity(:smart, 90, false, false) == :smart

      assert O.compensate_gravity({:smart, :face_assist}, 90, false, false) ==
               {:smart, :face_assist}
    end
  end

  describe "compensate_gravity_for/2 — offsets (port of gravity.go:96-153)" do
    alias ImagePipe.Transform.PendingOrientation, as: PO

    test "flipX negates X for center/N/S, 1-x for FP; type remaps too" do
      assert O.compensate_gravity_for({{:anchor, :center, :top}, 5.0, 3.0}, %PO{user_flip_x: true}) ==
               {{:anchor, :center, :top}, -5.0, 3.0}

      assert O.compensate_gravity_for({{:fp, 0.25, 0.1}, 0.0, 0.0}, %PO{user_flip_x: true}) ==
               {{:fp, 0.75, 0.1}, 1.0, 0.0}
    end

    test "flipY negates Y for center/E/W, 1-y for FP" do
      assert O.compensate_gravity_for({{:anchor, :left, :center}, 2.0, 4.0}, %PO{
               user_flip_y: true
             }) ==
               {{:anchor, :left, :center}, 2.0, -4.0}
    end

    # ---- ROTATE offset rows, derived from local/imgproxy-master/processing/gravity.go:117-153.
    # The offset switch keys on the POST-remap GravityType (gravity.go remaps g.Type at
    # lines 119-121 BEFORE the offset switch at 123-153 reads g.Type).
    #
    # Anchor mapping: {:anchor,:center,:top}=North, {:anchor,:center,:bottom}=South,
    # {:anchor,:left,:center}=West, {:anchor,:right,:center}=East,
    # {:anchor,:center,:center}=Center.

    test "rotate 90 — anchor types (offset switch keys on post-remap type)" do
      # Center: no rotation remap; post-remap Center -> X,Y = Y,-X (gravity.go:126-127)
      assert O.compensate_gravity_for(
               {{:anchor, :center, :center}, 5.0, 3.0},
               %PO{user_angle: 90}
             ) == {{:anchor, :center, :center}, 3.0, -5.0}

      # North -> West (gravity.go:10); post-remap West in {Center,East,West} -> Y,-X
      assert O.compensate_gravity_for({{:anchor, :center, :top}, 5.0, 3.0}, %PO{user_angle: 90}) ==
               {{:anchor, :left, :center}, 3.0, -5.0}

      # South -> East (gravity.go:12); post-remap East -> Y,-X
      assert O.compensate_gravity_for({{:anchor, :center, :bottom}, 5.0, 3.0}, %PO{user_angle: 90}) ==
               {{:anchor, :right, :center}, 3.0, -5.0}

      # East -> North (gravity.go:11); post-remap North hits default -> X,Y = Y,X (gravity.go:131)
      assert O.compensate_gravity_for({{:anchor, :right, :center}, 5.0, 3.0}, %PO{user_angle: 90}) ==
               {{:anchor, :center, :top}, 3.0, 5.0}

      # West -> South (gravity.go:13); post-remap South hits default -> Y,X
      assert O.compensate_gravity_for({{:anchor, :left, :center}, 5.0, 3.0}, %PO{user_angle: 90}) ==
               {{:anchor, :center, :bottom}, 3.0, 5.0}
    end

    test "rotate 180 — anchor types (offset switch keys on post-remap type)" do
      # Center: no remap; post-remap Center -> -X,-Y (gravity.go:135-136)
      assert O.compensate_gravity_for(
               {{:anchor, :center, :center}, 5.0, 3.0},
               %PO{user_angle: 180}
             ) == {{:anchor, :center, :center}, -5.0, -3.0}

      # North -> South (gravity.go:20); post-remap South in {North,South} -> X = -X (gravity.go:137-138)
      assert O.compensate_gravity_for({{:anchor, :center, :top}, 5.0, 3.0}, %PO{user_angle: 180}) ==
               {{:anchor, :center, :bottom}, -5.0, 3.0}

      # East -> West (gravity.go:21); post-remap West in {East,West} -> Y = -Y (gravity.go:139-140)
      assert O.compensate_gravity_for({{:anchor, :right, :center}, 5.0, 3.0}, %PO{user_angle: 180}) ==
               {{:anchor, :left, :center}, 5.0, -3.0}
    end

    test "rotate 90/180/270 — focus point (tuple coords AND offset transform)" do
      # 90: tuple FP {y,1-x}; offset FP X,Y = Y,1-X (gravity.go:128-129)
      assert O.compensate_gravity_for({{:fp, 0.25, 0.10}, 0.2, 0.3}, %PO{user_angle: 90}) ==
               {{:fp, 0.10, 0.75}, 0.3, 0.8}

      # 180: tuple FP {1-x,1-y}; offset FP 1-X,1-Y (gravity.go:141-142)
      assert O.compensate_gravity_for({{:fp, 0.25, 0.10}, 0.2, 0.3}, %PO{user_angle: 180}) ==
               {{:fp, 0.75, 0.90}, 0.8, 0.7}

      # 270: tuple FP {1-y,x}; offset FP 1-Y,X (gravity.go:148-149)
      assert O.compensate_gravity_for({{:fp, 0.25, 0.10}, 0.2, 0.3}, %PO{user_angle: 270}) ==
               {{:fp, 0.90, 0.25}, 0.7, 0.2}
    end
  end

  describe "swap_dims?/1 and swap_resize/1" do
    test "swap on quarter-turn only" do
      assert O.swap_dims?(90) and O.swap_dims?(270)
      refute O.swap_dims?(0) or O.swap_dims?(180)
    end

    test "swap_resize swaps width/height, min, zoom; leaves dpr" do
      resize = %ImagePipe.Transform.Operation.Resize{
        mode: :fit,
        width: {:pixels, 100},
        height: :auto,
        min_width: {:pixels, 10},
        min_height: nil,
        zoom_x: 2.0,
        zoom_y: 1.0,
        dpr: 3.0,
        enlarge: false
      }

      swapped = O.swap_resize(resize)
      assert swapped.width == :auto and swapped.height == {:pixels, 100}
      assert swapped.min_width == nil and swapped.min_height == {:pixels, 10}
      assert swapped.zoom_x == 1.0 and swapped.zoom_y == 2.0
      assert swapped.dpr == 3.0
    end
  end
end
