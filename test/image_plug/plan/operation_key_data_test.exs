defmodule ImagePlug.Plan.OperationKeyDataTest do
  use ExUnit.Case, async: true

  alias ImagePlug.Plan.Operation
  alias ImagePlug.Transform.KeyData

  describe "tagged geometry data" do
    test "materializes symbolic dimensions" do
      assert KeyData.data(:auto) == [unit: :auto]
      assert KeyData.data(:full_axis) == [unit: :full_axis]
    end

    test "materializes logical pixel dimensions" do
      assert KeyData.data({:px, 300}) == [unit: :logical_px, value: 300]
    end

    test "canonicalizes ratio dimensions" do
      assert KeyData.data({:ratio, 6, 8}) == [unit: :ratio, numerator: 3, denominator: 4]
      assert KeyData.data({:ratio, 0, 10}) == [unit: :ratio, numerator: 0, denominator: 1]
    end
  end

  describe "DPR data" do
    test "canonicalizes equivalent DPR ones" do
      expected = [unit: :ratio, numerator: 1, denominator: 1]

      assert KeyData.dpr_data(1) == expected
      assert KeyData.dpr_data(1.0) == expected
      assert KeyData.dpr_data("1.00") == expected
    end

    test "canonicalizes floats through fixed decimal precision" do
      assert KeyData.dpr_data(1.3324232) == [
               unit: :ratio,
               numerator: 1_665_529,
               denominator: 1_250_000
             ]
    end

    test "parses decimal strings exactly" do
      assert KeyData.dpr_data("1.3324232") == [
               unit: :ratio,
               numerator: 1_665_529,
               denominator: 1_250_000
             ]

      assert KeyData.dpr_data("1.33242321") == [
               unit: :ratio,
               numerator: 133_242_321,
               denominator: 100_000_000
             ]
    end
  end

  describe "resize operation data" do
    test "materializes unresolved resize auto semantic intent" do
      assert {:ok, operation} =
               Operation.resize(:auto, {:px, 300}, {:px, 200}, dpr: 2.0)

      material = KeyData.data(operation)

      assert material == [
               op: :resize,
               mode: :auto,
               width: [unit: :logical_px, value: 300],
               height: [unit: :logical_px, value: 200],
               dpr: [unit: :ratio, numerator: 2, denominator: 1],
               enlargement: :deny,
               guide: :center,
               min_width: nil,
               min_height: nil,
               zoom_x: 1.0,
               zoom_y: 1.0,
               rule: :imgproxy_orientation_match_v1
             ]

      refute Keyword.has_key?(material, :selected_branch)
      refute Keyword.has_key?(material, :branch)
      refute inspect(material) =~ "resize_fit"
      refute inspect(material) =~ "resize_cover"
    end

    test "canonicalizes equivalent DPR values through operation key data" do
      expected_dpr = [unit: :ratio, numerator: 1, denominator: 1]

      for dpr <- [1, 1.0, "1.00"] do
        assert {:ok, operation} = Operation.resize(:fit, {:px, 300}, :auto, dpr: dpr)
        assert KeyData.data(operation)[:dpr] == expected_dpr
      end
    end
  end
end
