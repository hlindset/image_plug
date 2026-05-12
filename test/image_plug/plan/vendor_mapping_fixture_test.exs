defmodule ImagePlug.Plan.VendorMappingFixtureTest do
  use ExUnit.Case, async: true

  @fixtures [
    %{
      vendor: :imgproxy,
      input: "rt:fill/w:300/h:200/g:fp:0.25:0.75",
      classification: :supported_now,
      semantic_shape: [:resize_cover],
      notes: "focal guide belongs on cover-style semantic operation"
    },
    %{
      vendor: :imgproxy,
      input: "c:100:50:ce",
      classification: :supported_now,
      semantic_shape: [:crop_guided],
      notes: "guided crop with center gravity"
    },
    %{
      vendor: :imgproxy,
      input: "rt:auto/w:300/h:200",
      classification: :supported_now,
      semantic_shape: [:resize_auto],
      notes: "branch is source-aware execution, not cache key material"
    },
    %{
      vendor: :twicpics,
      input: "focus=auto/crop=300x200",
      classification: :representable_not_executable,
      semantic_shape: [:crop_guided, :strategy_guide],
      notes: "strategy guide is future-facing and not first-slice execution"
    },
    %{
      vendor: :twicpics,
      input: "crop=300x200@10,20",
      classification: :representable_not_executable,
      semantic_shape: [:crop_region],
      notes: "coordinate crop pressures explicit region space"
    },
    %{
      vendor: :iiif,
      input: "pct:10,10,80,80/300,",
      classification: :representable_not_executable,
      semantic_shape: [:crop_region, :resize_fit],
      notes: "IIIF region is source-space before size"
    },
    %{
      vendor: :cloudinary,
      input: "c_fill,g_auto,w_300,h_200",
      classification: :representable_not_executable,
      semantic_shape: [:resize_cover, :strategy_guide],
      notes: "smart crop can map to guided cover once strategy guides exist"
    }
  ]

  test "first-wave vendor fixtures are explicit and shallow" do
    assert Enum.map(@fixtures, & &1.vendor) == [
             :imgproxy,
             :imgproxy,
             :imgproxy,
             :twicpics,
             :twicpics,
             :iiif,
             :cloudinary
           ]

    assert Enum.all?(
             @fixtures,
             &(&1.classification in [
                 :supported_now,
                 :representable_not_executable,
                 :intentionally_unsupported,
                 :lossy_approximation
               ])
           )

    assert Enum.all?(@fixtures, fn fixture ->
             MapSet.new(Map.keys(fixture)) ==
               MapSet.new([:classification, :input, :notes, :semantic_shape, :vendor]) and
               fixture.vendor in [:imgproxy, :twicpics, :iiif, :cloudinary] and
               is_binary(fixture.input) and
               is_list(fixture.semantic_shape) and
               Enum.all?(fixture.semantic_shape, &is_atom/1) and
               is_binary(fixture.notes)
           end)
  end

  test "fixture identities are unique by vendor and input" do
    identities = Enum.map(@fixtures, &{&1.vendor, &1.input})

    assert Enum.uniq(identities) == identities
  end

  test "non-imgproxy fixtures do not expand first-slice parser scope" do
    assert Enum.all?(@fixtures, fn
             %{vendor: :imgproxy} -> true
             %{classification: classification} -> classification != :supported_now
           end)
  end
end
