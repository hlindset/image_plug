defmodule ImagePipe.Parser.IIIF.Info do
  @moduledoc "Builds the IIIF Image API 3.0 info.json document map."

  alias ImagePipe.Plan.SourceInfo

  @context "http://iiif.io/api/image/3/context.json"

  @extra_features [
    "regionByPx",
    "regionByPct",
    "regionSquare",
    "sizeByW",
    "sizeByH",
    "sizeByWh",
    "sizeByPct",
    "sizeByConfinedWh",
    "sizeUpscaling",
    "rotationBy90s",
    "baseUriRedirect",
    "cors",
    "jsonldMediaType"
  ]

  @spec document(SourceInfo.t(), map()) :: map()
  def document(%SourceInfo{} = info, params) do
    {w, h} = SourceInfo.display_dimensions(info)

    %{
      "@context" => @context,
      "id" => params.id,
      "type" => "ImageService3",
      "protocol" => "http://iiif.io/api/image",
      "profile" => params.level,
      "width" => w,
      "height" => h,
      # `extraQualities`/`extraFormats` list what is supported *beyond* the baseline
      # (`default` quality; `jpg`/`png` formats at Level 2), per the IIIF spec.
      "extraQualities" =>
        params.qualities |> Enum.reject(&(&1 == :default)) |> Enum.map(&to_string/1),
      "extraFormats" =>
        params.formats |> Enum.reject(&(&1 in [:jpg, :png])) |> Enum.map(&to_string/1),
      "extraFeatures" => @extra_features
    }
  end
end
