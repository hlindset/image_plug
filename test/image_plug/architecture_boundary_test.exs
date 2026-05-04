defmodule ImagePlug.ArchitectureBoundaryTest do
  use ExUnit.Case, async: true

  @expected_core_files [
    "lib/image_plug/cache/material.ex",
    "lib/image_plug/cache/material/contain.ex",
    "lib/image_plug/decode_planner.ex",
    "lib/image_plug/image_materializer.ex",
    "lib/image_plug/output_negotiation.ex",
    "lib/image_plug/plan.ex",
    "lib/image_plug/pipeline.ex",
    "lib/image_plug/transform/contain.ex",
    "lib/image_plug/transform_chain.ex"
  ]

  @forbidden_parts [
    ["ImagePlug.", "ParamParser.", "Native"],
    ["ImagePlug.", "Processing", "Request"],
    ["ImagePlug.", "Pipeline", "Planner"]
  ]

  test "runtime modules do not depend on native parser IR or old planning contracts" do
    files = core_runtime_files()

    for expected_file <- @expected_core_files do
      assert expected_file in files
    end

    for file <- files do
      body = File.read!(file)

      for parts <- @forbidden_parts do
        forbidden = IO.iodata_to_binary(parts)

        refute body =~ forbidden
      end
    end
  end

  defp core_runtime_files do
    "lib/image_plug/**/*.ex"
    |> Path.wildcard()
    |> Enum.reject(&native_parser_file?/1)
    |> Enum.sort()
  end

  defp native_parser_file?("lib/image_plug/param_parser/native.ex"), do: true
  defp native_parser_file?("lib/image_plug/param_parser/native/" <> _path), do: true
  defp native_parser_file?(_file), do: false
end
