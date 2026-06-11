defmodule ImagePipe.Transform.InputColorManagementTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.InputColorManagement, as: ICM

  # Minimal 128-byte profile with the given 4-byte tag at offset 20 (PCS field).
  defp profile_with_pcs(tag) do
    <<0::size(20 * 8), tag::binary-size(4), 0::size(104 * 8)>>
  end

  # Minimal 128-byte header whose byte fields satisfy every check in
  # vips_icc_is_srgb_iec61966:
  #   offset  8 – version  <<2, 16, 0, 0>>   (2.1)
  #   offset 16 – colorspace "RGB "
  #   offset 24 – date    <<7, 206, 0, 2, 0, 9>>  (1998-12-01)
  #   offset 48 – mfr     "IEC "
  #   offset 52 – model   "sRGB"
  #   offset 80 – creator "HP  "
  defp srgb_iec61966_header do
    date = <<7, 206, 0, 2, 0, 9>>

    <<
      # offset 0–7: profile size + preferred CMM (ignored)
      0::size(8 * 8),
      # offset 8–11: version 2.1 = <<2, 16, 0, 0>>
      2, 16, 0, 0,
      # offset 12–15: profile/device class (ignored)
      0::size(4 * 8),
      # offset 16–19: colorspace "RGB "
      "RGB ",
      # offset 20–23: PCS (XYZ – not checked by srgb_iec61966?)
      "XYZ ",
      # offset 24–29: date <<7, 206, 0, 2, 0, 9>>
      date::binary,
      # offset 30–47: rest of date padding + profile file signature (ignored)
      0::size(18 * 8),
      # offset 48–51: device manufacturer "IEC "
      "IEC ",
      # offset 52–55: device model "sRGB"
      "sRGB",
      # offset 56–79: device attributes + rendering intent + illuminant (ignored)
      0::size(24 * 8),
      # offset 80–83: profile creator "HP  "
      "HP  ",
      # offset 84–127: remainder
      0::size(44 * 8)
    >>
  end

  @p3_fixture "test/support/image_pipe/test/imgproxy_differential/sources/icc_p3.png"

  describe "pcs/1" do
    test "returns :VIPS_PCS_XYZ when bytes 20–23 are 'XYZ '" do
      assert ICM.pcs(profile_with_pcs("XYZ ")) == :VIPS_PCS_XYZ
    end

    test "returns :VIPS_PCS_LAB for any non-XYZ tag" do
      assert ICM.pcs(profile_with_pcs("Lab ")) == :VIPS_PCS_LAB
    end

    test "returns :VIPS_PCS_LAB for profiles shorter than 128 bytes" do
      assert ICM.pcs(<<0, 1, 2>>) == :VIPS_PCS_LAB
    end

    test "returns :VIPS_PCS_LAB for nil" do
      assert ICM.pcs(nil) == :VIPS_PCS_LAB
    end

    test "returns :VIPS_PCS_XYZ for the Display-P3 fixture (its header carries XYZ PCS)" do
      {:ok, img} = Image.open(@p3_fixture)
      {:ok, p3} = Vix.Vips.Image.header_value(img, "icc-profile-data")
      assert ICM.pcs(p3) == :VIPS_PCS_XYZ
    end
  end

  describe "srgb_iec61966?/1" do
    test "true for a header that satisfies all vips_icc_is_srgb_iec61966 checks" do
      assert ICM.srgb_iec61966?(srgb_iec61966_header())
    end

    test "false for a Display-P3 fixture profile" do
      {:ok, img} = Image.open(@p3_fixture)
      {:ok, p3} = Vix.Vips.Image.header_value(img, "icc-profile-data")
      refute ICM.srgb_iec61966?(p3)
    end

    test "false for a profile shorter than 128 bytes" do
      refute ICM.srgb_iec61966?(<<0, 1, 2>>)
    end

    test "false for nil" do
      refute ICM.srgb_iec61966?(nil)
    end

    test "false when any single check field differs" do
      base = srgb_iec61966_header()

      # Mutate manufacturer "IEC " → "IEC!"
      <<pre::binary-size(48), _::binary-size(4), rest::binary>> = base
      assert ICM.srgb_iec61966?(<<pre::binary, "IEC!", rest::binary>>) == false

      # Mutate model "sRGB" → "sRGb"
      <<pre2::binary-size(52), _::binary-size(4), rest2::binary>> = base
      assert ICM.srgb_iec61966?(<<pre2::binary, "sRGb", rest2::binary>>) == false

      # Mutate creator "HP  " → "hp  "
      <<pre3::binary-size(80), _::binary-size(4), rest3::binary>> = base
      assert ICM.srgb_iec61966?(<<pre3::binary, "hp  ", rest3::binary>>) == false
    end
  end

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
