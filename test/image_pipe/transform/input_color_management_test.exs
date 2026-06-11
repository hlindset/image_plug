defmodule ImagePipe.Transform.InputColorManagementTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.InputColorManagement, as: ICM

  describe "working_space/2 (supports_hdr?: false)" do
    test "8-bit color and grey stay as-is" do
      assert ICM.working_space(:VIPS_INTERPRETATION_sRGB, false) == :VIPS_INTERPRETATION_sRGB
      assert ICM.working_space(:VIPS_INTERPRETATION_RGB, false) == :VIPS_INTERPRETATION_RGB
      assert ICM.working_space(:VIPS_INTERPRETATION_B_W, false) == :VIPS_INTERPRETATION_B_W
    end

    test "16-bit tone-maps to 8-bit standard" do
      assert ICM.working_space(:VIPS_INTERPRETATION_RGB16, false) == :VIPS_INTERPRETATION_sRGB
      assert ICM.working_space(:VIPS_INTERPRETATION_GREY16, false) == :VIPS_INTERPRETATION_B_W
    end

    test "CMYK and unknown go to sRGB" do
      assert ICM.working_space(:VIPS_INTERPRETATION_CMYK, false) == :VIPS_INTERPRETATION_sRGB
      assert ICM.working_space(:VIPS_INTERPRETATION_scRGB, false) == :VIPS_INTERPRETATION_sRGB
    end
  end
end
