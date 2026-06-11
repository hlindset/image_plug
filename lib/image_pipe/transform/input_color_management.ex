defmodule ImagePipe.Transform.InputColorManagement do
  @moduledoc """
  Fixed, data-determined input-conditioning preamble (NOT a `Plan.Operation`):
  imports the embedded ICC profile into a working space before any processing
  step, mirroring imgproxy's `colorspaceToProcessing`. Seeded once by
  `ImagePipe.Transform.PlanExecutor`. `supports_hdr?` is hardwired `false`
  today (the #121 seam).
  """

  @doc "Working-space interpretation for a decoded image (port of guessTargetColorspace)."
  @spec working_space(atom(), boolean()) :: atom()
  def working_space(interpretation, supports_hdr?)

  def working_space(:VIPS_INTERPRETATION_sRGB, _hdr), do: :VIPS_INTERPRETATION_sRGB
  def working_space(:VIPS_INTERPRETATION_RGB, _hdr), do: :VIPS_INTERPRETATION_RGB
  def working_space(:VIPS_INTERPRETATION_B_W, _hdr), do: :VIPS_INTERPRETATION_B_W

  def working_space(:VIPS_INTERPRETATION_RGB16, true), do: :VIPS_INTERPRETATION_RGB16
  def working_space(:VIPS_INTERPRETATION_RGB16, false), do: :VIPS_INTERPRETATION_sRGB
  def working_space(:VIPS_INTERPRETATION_GREY16, true), do: :VIPS_INTERPRETATION_GREY16
  def working_space(:VIPS_INTERPRETATION_GREY16, false), do: :VIPS_INTERPRETATION_B_W
  def working_space(:VIPS_INTERPRETATION_CMYK, _hdr), do: :VIPS_INTERPRETATION_sRGB
  def working_space(_other, true), do: :VIPS_INTERPRETATION_RGB16
  def working_space(_other, false), do: :VIPS_INTERPRETATION_sRGB

  @doc """
  Reads the Profile Connection Space from bytes 20–23 of the ICC header.
  Returns `:VIPS_PCS_XYZ` when those bytes equal `"XYZ "`, otherwise
  `:VIPS_PCS_LAB`. Profiles shorter than 128 bytes (or `nil`) default to
  `:VIPS_PCS_LAB`.

  Port of `vips_icc_get_pcs` in imgproxy `vips/vips.c`.
  """
  @spec pcs(binary() | nil) :: :VIPS_PCS_XYZ | :VIPS_PCS_LAB
  def pcs(profile) when is_binary(profile) and byte_size(profile) >= 128 do
    case profile do
      <<_::binary-size(20), "XYZ ", _::binary>> -> :VIPS_PCS_XYZ
      _ -> :VIPS_PCS_LAB
    end
  end

  def pcs(_), do: :VIPS_PCS_LAB

  @doc """
  Returns `true` when the ICC profile header matches the canonical sRGB
  IEC61966-2.1 profile as identified by `vips_icc_is_srgb_iec61966` in
  imgproxy `vips/vips.c`.

  Checks (all must match):
  - offset  8 – version `<<2, 16, 0, 0>>` (profile version 2.1)
  - offset 16 – colorspace `"RGB "`
  - offset 24 – creation date `<<7, 206, 0, 2, 0, 9>>` (1998-12-01)
  - offset 48 – device manufacturer `"IEC "`
  - offset 52 – device model `"sRGB"`
  - offset 80 – profile creator `"HP  "`

  Profiles shorter than 128 bytes (or `nil`) return `false`.
  """
  @spec srgb_iec61966?(binary() | nil) :: boolean()
  def srgb_iec61966?(profile) when is_binary(profile) and byte_size(profile) >= 128 do
    match?(
      <<
        _::binary-size(8),
        # offset 8: version 2.1
        2, 16, 0, 0,
        _::binary-size(4),
        # offset 16: colorspace "RGB "
        "RGB ",
        _::binary-size(4),
        # offset 24: date 1998-12-01
        7, 206, 0, 2, 0, 9,
        _::binary-size(18),
        # offset 48: device manufacturer "IEC "
        "IEC ",
        # offset 52: device model "sRGB"
        "sRGB",
        _::binary-size(24),
        # offset 80: profile creator "HP  "
        "HP  ",
        _::binary
      >>,
      profile
    )
  end

  def srgb_iec61966?(_), do: false
end
