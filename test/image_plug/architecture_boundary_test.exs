defmodule ImagePlug.ArchitectureBoundaryTest do
  use ExUnit.Case, async: true

  @runtime_globs ["lib/image_plug/runtime.ex", "lib/image_plug/runtime/**/*.ex"]
  @concrete_transform_names [
    :Scale,
    :Contain,
    :Cover,
    :Crop,
    :Focus,
    :Resize,
    :AdaptiveResize,
    :Rotate,
    :Flip,
    :AutoOrient,
    :ExtendCanvas
  ]

  test "runtime does not depend on concrete transform modules" do
    violations =
      for file <- runtime_files(),
          violation <- concrete_transform_references(file) do
        "#{file}:#{violation.line} must not name #{violation.module}; use ImagePlug.Transform dispatch instead"
      end

    assert violations == []
  end

  test "runtime does not depend on native parser structs" do
    violations =
      for file <- runtime_files(),
          violation <- native_parser_references(file) do
        "#{file}:#{violation.line} must not name #{violation.module}; keep Native parser dependencies out of runtime"
      end

    assert violations == []
  end

  test "concrete transform reference check rejects nested grouped aliases" do
    file = Path.join(System.tmp_dir!(), "image_plug_architecture_boundary_test_runtime.ex")

    on_exit(fn -> File.rm(file) end)

    File.write!(file, """
    defmodule ImagePlug.Runtime.BoundaryExample do
      alias ImagePlug.Transform.{Scale.Params}
    end
    """)

    assert [%{line: 2, module: "ImagePlug.Transform.Scale"}] =
             concrete_transform_references(file)
  end

  test "concrete transform reference check rejects aliases grouped under concrete transforms" do
    file = Path.join(System.tmp_dir!(), "image_plug_architecture_boundary_test_nested_runtime.ex")

    on_exit(fn -> File.rm(file) end)

    File.write!(file, """
    defmodule ImagePlug.Runtime.BoundaryExample do
      alias ImagePlug.Transform.{Scale.{Params}}
    end
    """)

    assert [%{line: 2, module: "ImagePlug.Transform.Scale"}] =
             concrete_transform_references(file)
  end

  test "native parser reference check rejects grouped and indirect aliases" do
    file = Path.join(System.tmp_dir!(), "image_plug_architecture_boundary_test_native.ex")

    on_exit(fn -> File.rm(file) end)

    File.write!(file, """
    defmodule ImagePlug.Runtime.BoundaryExample do
      alias ImagePlug.Parser.{Native}

      def parse(path), do: Native.parse(path)

      alias ImagePlug.Parser
      def parse_again(path), do: Parser.Native.parse(path)
      def struct_reference, do: %Parser.Native.SomeStruct{}
    end
    """)

    assert [
             %{line: 2, module: "ImagePlug.Parser.Native"},
             %{line: 4, module: "Native"},
             %{line: 7, module: "Parser.Native"},
             %{line: 8, module: "Parser.Native"}
           ] = native_parser_references(file)
  end

  defp runtime_files do
    @runtime_globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.sort()
  end

  defp concrete_transform_references(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {:alias, meta,
         [
           {{:., _dot_meta, [grouped_alias_prefix, :{}]}, _call_meta, grouped_aliases}
         ]} = node,
        violations ->
          grouped_aliases
          |> Enum.map(&concrete_transform_grouped_alias(grouped_alias_prefix, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&violation(meta, concrete_transform_module(&1)))
          |> then(&{node, &1 ++ violations})

        {:__aliases__, meta, [:ImagePlug, :Transform, transform]} = node, violations
        when transform in @concrete_transform_names ->
          {node, [violation(meta, concrete_transform_module(transform)) | violations]}

        {:__aliases__, meta, [:ImagePlug, :Transform, transform | _rest]} = node, violations
        when transform in @concrete_transform_names ->
          {node, [violation(meta, concrete_transform_module(transform)) | violations]}

        {:__aliases__, meta, [:Transform, transform]} = node, violations
        when transform in @concrete_transform_names ->
          {node, [violation(meta, "Transform.#{transform}") | violations]}

        {:__aliases__, meta, [:Transform, transform | _rest]} = node, violations
        when transform in @concrete_transform_names ->
          {node, [violation(meta, "Transform.#{transform}") | violations]}

        node, violations ->
          {node, violations}
      end)

    violations
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp native_parser_references(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {:alias, meta,
         [
           {{:., _dot_meta, [{:__aliases__, _module_meta, [:ImagePlug, :Parser]}, :{}]},
            _call_meta, grouped_aliases}
         ]} = node,
        violations ->
          grouped_aliases
          |> Enum.filter(&native_parser_alias?/1)
          |> Enum.map(&violation(meta, native_parser_module(&1)))
          |> then(&{node, &1 ++ violations})

        {:__aliases__, meta, [:ImagePlug, :Parser, :Native]} = node, violations ->
          {node, [violation(meta, "ImagePlug.Parser.Native") | violations]}

        {:__aliases__, meta, [:ImagePlug, :Parser, :Native | _rest]} = node, violations ->
          {node, [violation(meta, "ImagePlug.Parser.Native") | violations]}

        {:__aliases__, meta, [:Parser, :Native]} = node, violations ->
          {node, [violation(meta, "Parser.Native") | violations]}

        {:__aliases__, meta, [:Parser, :Native | _rest]} = node, violations ->
          {node, [violation(meta, "Parser.Native") | violations]}

        {:__aliases__, meta, [:Native]} = node, violations ->
          {node, [violation(meta, "Native") | violations]}

        {:__aliases__, meta, [:Native | _rest]} = node, violations ->
          {node, [violation(meta, "Native") | violations]}

        node, violations ->
          {node, violations}
      end)

    violations
    |> Enum.reverse()
    |> Enum.uniq()
    |> reject_grouped_alias_child_duplicates()
  end

  defp native_parser_alias?({:__aliases__, _meta, [:Native]}), do: true
  defp native_parser_alias?({:__aliases__, _meta, [:Native | _rest]}), do: true
  defp native_parser_alias?(_ast), do: false

  defp native_parser_module({:__aliases__, _meta, [:Native]}), do: "ImagePlug.Parser.Native"

  defp native_parser_module({:__aliases__, _meta, [:Native | _rest]}),
    do: "ImagePlug.Parser.Native"

  defp reject_grouped_alias_child_duplicates(violations) do
    grouped_alias_lines =
      violations
      |> Enum.filter(&(&1.module == "ImagePlug.Parser.Native"))
      |> MapSet.new(& &1.line)

    Enum.reject(
      violations,
      &(&1.module == "Native" and MapSet.member?(grouped_alias_lines, &1.line))
    )
  end

  defp concrete_transform_grouped_alias(prefix, alias) do
    prefix
    |> alias_parts()
    |> Kernel.++(grouped_alias_parts(alias))
    |> concrete_transform_name()
  end

  defp concrete_transform_name([:ImagePlug, :Transform, transform | _rest])
       when transform in @concrete_transform_names,
       do: transform

  defp concrete_transform_name([:Transform, transform | _rest])
       when transform in @concrete_transform_names,
       do: transform

  defp concrete_transform_name(_parts), do: nil

  defp grouped_alias_parts({:__aliases__, _meta, parts}), do: parts

  defp grouped_alias_parts({{:., _dot_meta, [prefix, :{}]}, _call_meta, _grouped_aliases}),
    do: alias_parts(prefix)

  defp grouped_alias_parts(_alias), do: []

  defp alias_parts({:__aliases__, _meta, parts}), do: parts
  defp alias_parts(_alias), do: []

  defp concrete_transform_module({:__aliases__, _meta, [transform]}),
    do: concrete_transform_module(transform)

  defp concrete_transform_module({:__aliases__, _meta, [transform | _rest]}),
    do: concrete_transform_module(transform)

  defp concrete_transform_module(transform), do: "ImagePlug.Transform.#{transform}"

  defp violation(meta, module) do
    %{line: Keyword.fetch!(meta, :line), module: module}
  end
end
