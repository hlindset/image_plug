defmodule ImagePipeDemo.Fiddle.ProcessingPath do
  @moduledoc """
  Pure builder: DemoState -> unsigned imgproxy processing path.
  Spike 1: Request + Crop only, unsigned `_`, bare `images/x.jpg` source form.
  """

  alias ImagePipeDemo.Fiddle.DemoState

  @doc "Full unsigned path: `/_/{opts}/plain/{source}` (or `/_/plain/{source}` with no opts)."
  def build(%DemoState{} = state), do: "/_" <> path_suffix(state)

  defp path_suffix(%DemoState{} = state) do
    opts = state |> option_segments() |> Enum.join("/")
    opts_path = if opts == "", do: "", else: "/" <> opts
    opts_path <> "/plain/" <> state.source
  end

  defp option_segments(%DemoState{} = state), do: maybe_crop([], state)

  defp maybe_crop(segments, %DemoState{crop_enabled: false}), do: segments
  defp maybe_crop(segments, %DemoState{} = state), do: segments ++ [crop_segment(state)]

  defp crop_segment(%DemoState{} = state) do
    base = [
      "c",
      crop_dimension(state.crop_width_unit, state.crop_width, state.crop_width_percent),
      crop_dimension(state.crop_height_unit, state.crop_height, state.crop_height_percent)
    ]

    parts = if state.crop_gravity == "inherit", do: base, else: base ++ [state.crop_gravity]
    Enum.join(parts, ":")
  end

  defp crop_dimension(:full, _px, _pct), do: "0"
  defp crop_dimension(:percent, _px, pct), do: percent_string(pct)
  defp crop_dimension(:px, px, _pct), do: Integer.to_string(max(1, px))

  # Mirror JS `String(percent / 100)`: 50 -> "0.5", 25 -> "0.25", 1 -> "0.01".
  defp percent_string(pct), do: Float.to_string(pct / 100)
end
