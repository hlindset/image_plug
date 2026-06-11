defmodule ImagePipe.Test.ImgproxyDifferential.OptsSummary do
  @moduledoc """
  Renders an imgproxy `opts` string (as stored on a constellation) into a short
  human-readable summary for the visual-diff report's card labels. Self-contained
  on purpose — a tiny dedicated formatter, not a reach into the parser — covering
  the option codes used in `constellations.ex`, with unknown segments echoed
  verbatim so it never hides syntax it doesn't recognize.
  """

  use Boundary, top_level?: true, deps: []

  @doc "Human-readable summary of a slash-separated imgproxy opts string."
  @spec describe(String.t()) :: String.t()
  def describe(opts) do
    opts
    |> String.split("/", trim: true)
    |> Enum.map_join("; ", &segment/1)
  end

  defp segment(seg), do: seg |> String.split(":") |> segment_parts() |> with_fallback(seg)

  defp with_fallback(nil, seg), do: seg
  defp with_fallback(text, _seg), do: text

  defp segment_parts(["rs", mode, w, h]), do: "resize #{mode} #{w}×#{h}"
  defp segment_parts(["c", w, h]), do: "crop #{w}×#{h}"
  defp segment_parts(["t", n]), do: "trim (threshold #{n})"
  defp segment_parts(["g" | rest]), do: "gravity #{gravity(rest)}"
  defp segment_parts(["mw", n]), do: "min-width #{n}"
  defp segment_parts(["mh", n]), do: "min-height #{n}"
  defp segment_parts(["z", f]), do: "zoom #{f}"
  defp segment_parts(["pd" | vals]), do: "padding #{Enum.join(vals, ",")}"
  defp segment_parts(["ex" | rest]), do: "extend#{extend_suffix(rest)}"
  defp segment_parts(["exar" | _]), do: "extend-aspect-ratio"
  defp segment_parts(["dpr", n]), do: "dpr #{n}"
  defp segment_parts(["bg", r, g, b]), do: "background rgb(#{r},#{g},#{b})"
  defp segment_parts(["bl", n]), do: "blur #{n}"
  defp segment_parts(["sh", n]), do: "sharpen #{n}"
  defp segment_parts(["sm", f]), do: "strip-metadata #{onoff(f)}"
  defp segment_parts(["scp", f]), do: "strip-color-profile #{onoff(f)}"
  defp segment_parts(["el", f]), do: "enlarge #{onoff(f)}"
  defp segment_parts(["q", n]), do: "quality #{n}"
  defp segment_parts(["f", fmt]), do: "format #{fmt}"
  defp segment_parts(_), do: nil

  defp gravity([code]), do: gravity_name(code)
  defp gravity([code, x, y]), do: "#{gravity_name(code)} +#{x},+#{y}"
  defp gravity(other), do: Enum.join(other, ":")

  defp gravity_name("ce"), do: "center"
  defp gravity_name("no"), do: "north"
  defp gravity_name("so"), do: "south"
  defp gravity_name("ea"), do: "east"
  defp gravity_name("we"), do: "west"
  defp gravity_name("noea"), do: "north-east"
  defp gravity_name("nowe"), do: "north-west"
  defp gravity_name("soea"), do: "south-east"
  defp gravity_name("sowe"), do: "south-west"
  defp gravity_name("sm"), do: "smart"
  defp gravity_name(other), do: other

  defp extend_suffix([_flag]), do: ""
  defp extend_suffix([_flag, code]), do: " (#{gravity_name(code)})"
  defp extend_suffix([_flag, code, x, y]), do: " (#{gravity_name(code)} +#{x},+#{y})"
  defp extend_suffix(_), do: ""

  defp onoff("0"), do: "off"
  defp onoff("1"), do: "on"
  defp onoff(x), do: x
end
