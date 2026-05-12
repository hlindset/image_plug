defmodule ImagePlug.Plan.OperationKeyDataTest do
  use ExUnit.Case, async: true

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
end
