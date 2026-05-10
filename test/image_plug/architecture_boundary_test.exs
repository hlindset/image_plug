defmodule ImagePlug.ArchitectureBoundaryTest do
  use ExUnit.Case, async: true

  @runtime_globs ["lib/image_plug/runtime.ex", "lib/image_plug/runtime/**/*.ex"]
  @imgproxy_parser_globs [
    "lib/image_plug/parser/imgproxy.ex",
    "lib/image_plug/parser/imgproxy/**/*.ex"
  ]
  @cache_key_files ["lib/image_plug/cache/key.ex"]
  @boundary_files %{
    ImagePlug.Cache => "lib/image_plug/cache.ex",
    ImagePlug.Parser => "lib/image_plug/parser.ex",
    ImagePlug.Parser.Imgproxy => "lib/image_plug/parser/imgproxy.ex",
    ImagePlug.Runtime => "lib/image_plug/runtime.ex",
    ImagePlug.Transform => "lib/image_plug/transform.ex"
  }
  @concrete_plan_names [
    :AutoOrient,
    :Canvas,
    :CropGuided,
    :CropRegion,
    :Flip,
    :ResizeAuto,
    :ResizeCover,
    :ResizeFit,
    :ResizeStretch,
    :Rotate
  ]
  @concrete_transform_names [
    :Scale,
    :Contain,
    :Cover,
    :Crop,
    :Focus,
    :Resize,
    :Rotate,
    :Flip,
    :AutoOrient,
    :ExtendCanvas
  ]
  @post_fetch_transform_state_modules [
    ImagePlug.Transform.Resolver,
    ImagePlug.Transform.SourceMetadata,
    ImagePlug.Transform.ResolvedPlan,
    ImagePlug.Transform.Derivation
  ]

  test "parser boundary declarations stay limited to parser, plan, and transform construction APIs" do
    parser = boundary_declaration(ImagePlug.Parser)
    imgproxy = boundary_declaration(ImagePlug.Parser.Imgproxy)

    assert_boundary_deps(parser, [ImagePlug.Plan])
    assert_boundary_exports(parser, [ImagePlug.Parser.Imgproxy])

    assert_boundary_deps(imgproxy, [ImagePlug.Parser, ImagePlug.Plan])
    assert_boundary_exports(imgproxy, [])

    assert_allowed_deps(parser, [ImagePlug.Plan, ImagePlug.Transform])
    assert_allowed_deps(imgproxy, [ImagePlug.Parser, ImagePlug.Plan, ImagePlug.Transform])
  end

  test "runtime boundary declaration depends on generic facades only" do
    runtime = boundary_declaration(ImagePlug.Runtime)

    assert_boundary_deps(runtime, [
      ImagePlug.Plan,
      ImagePlug.Cache,
      ImagePlug.Output,
      ImagePlug.Transform
    ])

    refute_boundary_deps(runtime, [ImagePlug.Parser | concrete_transform_modules()])

    assert_boundary_exports(runtime, [
      ImagePlug.Runtime.RequestRunner,
      ImagePlug.Runtime.Origin,
      ImagePlug.Runtime.ResponseDisposition,
      ImagePlug.Runtime.ResponseSender,
      ImagePlug.Runtime.SourceIdentity,
      ImagePlug.Runtime.Options
    ])
  end

  test "cache boundary declaration avoids post-fetch transform state dependencies" do
    cache = boundary_declaration(ImagePlug.Cache)

    assert_boundary_deps(cache, [
      ImagePlug.Plan,
      ImagePlug.Output,
      ImagePlug.Transform
    ])

    refute_boundary_deps(cache, @post_fetch_transform_state_modules)

    assert_boundary_exports(cache, [
      ImagePlug.Cache.Entry,
      ImagePlug.Cache.Key,
      ImagePlug.Cache.FileSystem
    ])
  end

  test "transform boundary declaration depends on plan and not higher layers" do
    transform = boundary_declaration(ImagePlug.Transform)

    assert_boundary_deps(transform, [ImagePlug.Plan])

    refute_boundary_deps(transform, [
      ImagePlug.Parser,
      ImagePlug.Runtime,
      ImagePlug.Cache,
      ImagePlug.Output
    ])

    assert_boundary_exports_include(transform, [
      ImagePlug.Transform.State,
      ImagePlug.Transform.Chain,
      ImagePlug.Transform.DecodePlanner,
      ImagePlug.Transform.Materializer,
      ImagePlug.Transform.Material,
      ImagePlug.Transform.Types,
      ImagePlug.Transform.Operation.Resize,
      ImagePlug.Transform.Operation.ExtendCanvas,
      ImagePlug.Transform.Operation.AutoOrient,
      ImagePlug.Transform.Operation.Rotate,
      ImagePlug.Transform.Operation.Flip,
      ImagePlug.Transform.Operation.Scale,
      ImagePlug.Transform.Operation.Cover,
      ImagePlug.Transform.Operation.Contain,
      ImagePlug.Transform.Operation.Crop,
      ImagePlug.Transform.Operation.Focus
    ])
  end

  test "runtime does not depend on concrete transform modules" do
    violations =
      for file <- runtime_files(),
          violation <- concrete_transform_references(file) do
        "#{file}:#{violation.line} must not name #{violation.module}; use ImagePlug.Transform dispatch instead"
      end

    assert violations == []
  end

  test "stale adaptive resize executable operation is removed" do
    refute Code.ensure_loaded?(Module.concat(ImagePlug.Transform.Operation, AdaptiveResize))
  end

  test "runtime does not depend on concrete plan operation modules" do
    violations =
      for file <- runtime_files(),
          violation <- concrete_plan_references(file) do
        "#{file}:#{violation.line} must not name #{violation.module}; use generic Plan/Transform facades instead"
      end

    assert violations == []
  end

  test "runtime does not inspect plan operation semantic staging" do
    violations =
      for file <- runtime_files(),
          violation <- plan_operation_semantic_references(file) do
        "#{file}:#{violation.line} must not call #{violation.module}.semantic?/1; use ImagePlug.Transform executable planning instead"
      end

    assert violations == []
  end

  test "runtime does not depend on imgproxy parser structs" do
    violations =
      for file <- runtime_files(),
          violation <- imgproxy_parser_references(file) do
        "#{file}:#{violation.line} must not name #{violation.module}; keep Imgproxy parser dependencies out of runtime"
      end

    assert violations == []
  end

  test "cache key construction does not depend on post-fetch resolver state" do
    violations =
      for file <- @cache_key_files,
          violation <- post_fetch_resolver_references(file) do
        "#{file}:#{violation.line} must not name #{violation.module}; final cache keys are prefetch-safe"
      end

    assert violations == []
  end

  test "imgproxy parser does not depend on executable transform operation modules" do
    violations =
      for file <- imgproxy_parser_files(),
          violation <- concrete_transform_references(file) do
        "#{file}:#{violation.line} must not name #{violation.module}; parser output is semantic Plan operations"
      end

    assert violations == []
  end

  test "concrete plan reference check rejects nested grouped aliases" do
    file = tmp_file("runtime_plan")

    on_exit(fn -> File.rm(file) end)

    File.write!(file, """
    defmodule ImagePlug.Runtime.BoundaryExample do
      alias ImagePlug.Plan.Operation.{ResizeFit.Params}
    end
    """)

    assert [%{line: 2, module: "ImagePlug.Plan.Operation.ResizeFit"}] =
             concrete_plan_references(file)
  end

  test "concrete transform reference check rejects nested grouped aliases" do
    file = tmp_file("runtime")

    on_exit(fn -> File.rm(file) end)

    File.write!(file, """
    defmodule ImagePlug.Runtime.BoundaryExample do
      alias ImagePlug.Transform.Operation.{Scale.Params}
    end
    """)

    assert [%{line: 2, module: "ImagePlug.Transform.Operation.Scale"}] =
             concrete_transform_references(file)
  end

  test "concrete transform reference check rejects aliases grouped under concrete transforms" do
    file = tmp_file("nested_runtime")

    on_exit(fn -> File.rm(file) end)

    File.write!(file, """
    defmodule ImagePlug.Runtime.BoundaryExample do
      alias ImagePlug.Transform.Operation.{Scale.{Params}}
    end
    """)

    assert [%{line: 2, module: "ImagePlug.Transform.Operation.Scale"}] =
             concrete_transform_references(file)
  end

  test "concrete transform reference check rejects relative Operation aliases" do
    file = tmp_file("relative_runtime")

    on_exit(fn -> File.rm(file) end)

    File.write!(file, """
    defmodule ImagePlug.Runtime.BoundaryExample do
      alias ImagePlug.Transform.Operation
      def build, do: %Operation.Resize{}
    end
    """)

    assert [%{line: 3, module: "Operation.Resize"}] = concrete_transform_references(file)
  end

  test "post-fetch resolver reference check rejects resolver state modules" do
    file = tmp_file("cache_key")

    on_exit(fn -> File.rm(file) end)

    File.write!(file, """
    defmodule ImagePlug.Cache.Key.BoundaryExample do
      alias ImagePlug.Transform.{Resolver, SourceMetadata}
      def material(%ImagePlug.Transform.ResolvedPlan{}), do: %ImagePlug.Transform.Derivation{}
    end
    """)

    assert post_fetch_resolver_references(file) |> Enum.sort_by(&{&1.line, &1.module}) == [
             %{line: 2, module: "ImagePlug.Transform.Resolver"},
             %{line: 2, module: "ImagePlug.Transform.SourceMetadata"},
             %{line: 3, module: "ImagePlug.Transform.Derivation"},
             %{line: 3, module: "ImagePlug.Transform.ResolvedPlan"}
           ]
  end

  test "imgproxy parser reference check rejects grouped and indirect aliases" do
    file = tmp_file("imgproxy")

    on_exit(fn -> File.rm(file) end)

    File.write!(file, """
    defmodule ImagePlug.Runtime.BoundaryExample do
      alias ImagePlug.Parser.{Imgproxy}

      def parse(path), do: Imgproxy.parse(path)

      alias ImagePlug.Parser
      def parse_again(path), do: Parser.Imgproxy.parse(path)
      def struct_reference, do: %Parser.Imgproxy.SomeStruct{}
    end
    """)

    assert [
             %{line: 2, module: "ImagePlug.Parser.Imgproxy"},
             %{line: 4, module: "Imgproxy"},
             %{line: 7, module: "Parser.Imgproxy"},
             %{line: 8, module: "Parser.Imgproxy"}
           ] = imgproxy_parser_references(file)
  end

  defp runtime_files do
    @runtime_globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.sort()
  end

  defp boundary_declaration(module) do
    file = Map.fetch!(@boundary_files, module)
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    opts =
      ast
      |> boundary_module_ast(module)
      |> boundary_use_opts()

    %{
      module: module,
      deps: opts |> Keyword.get(:deps, []) |> Enum.map(&normalize_boundary_dep/1),
      exports: opts |> Keyword.get(:exports, []) |> normalize_boundary_exports(module)
    }
  end

  defp assert_boundary_deps(declaration, expected_deps) do
    actual_deps = boundary_dep_names(declaration)

    assert actual_deps == Enum.sort(expected_deps)
    assert Enum.all?(declaration.deps, &runtime_dep?/1)
  end

  defp assert_allowed_deps(declaration, allowed_deps) do
    unexpected_deps = declaration |> boundary_dep_names() |> Kernel.--(allowed_deps)

    assert unexpected_deps == []
  end

  defp refute_boundary_deps(declaration, forbidden_deps) do
    forbidden_deps = MapSet.new(forbidden_deps)

    violations =
      declaration
      |> boundary_dep_names()
      |> Enum.filter(&MapSet.member?(forbidden_deps, &1))

    assert violations == []
  end

  defp assert_boundary_exports(declaration, expected_exports) do
    assert declaration.exports == Enum.sort(expected_exports)
  end

  defp assert_boundary_exports_include(declaration, expected_exports) do
    missing_exports = Enum.sort(expected_exports) -- declaration.exports

    assert missing_exports == []
  end

  defp concrete_transform_modules do
    Enum.map(@concrete_transform_names, &Module.concat(ImagePlug.Transform.Operation, &1))
  end

  defp boundary_dep_names(declaration) do
    declaration.deps
    |> Enum.map(fn {dep, _mode} -> dep end)
    |> Enum.sort()
  end

  defp runtime_dep?({_dep, :runtime}), do: true
  defp runtime_dep?({_dep, _mode}), do: false

  defp boundary_module_ast(ast, module) do
    {_ast, module_ast} =
      Macro.prewalk(ast, nil, fn
        {:defmodule, _meta, [{:__aliases__, _module_meta, parts}, [do: block]]} = node, acc ->
          case Module.concat(parts) do
            ^module -> {node, block}
            _other -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    module_ast
  end

  defp boundary_use_opts(module_ast) do
    {_ast, opts} =
      Macro.prewalk(module_ast, nil, fn
        {:use, _meta, [{:__aliases__, _boundary_meta, [:Boundary]}, opts]} = node, _acc
        when is_list(opts) ->
          {node, opts}

        node, acc ->
          {node, acc}
      end)

    opts
  end

  defp normalize_boundary_dep({dep, mode}) when mode in [:compile, :runtime] do
    {module_alias(dep), mode}
  end

  defp normalize_boundary_dep(dep), do: {module_alias(dep), :runtime}

  defp normalize_boundary_exports(:all, _boundary), do: :all

  defp normalize_boundary_exports(exports, boundary) do
    exports
    |> Enum.map(&boundary_export_module(boundary, &1))
    |> Enum.sort()
  end

  defp boundary_export_module(boundary, {export, _opts}) do
    boundary_export_module(boundary, export)
  end

  defp boundary_export_module(_boundary, {:__aliases__, _meta, [:ImagePlug | _rest] = parts}) do
    Module.concat(parts)
  end

  defp boundary_export_module(boundary, {:__aliases__, _meta, parts}) do
    Module.concat([boundary | parts])
  end

  defp module_alias({:__aliases__, _meta, parts}), do: Module.concat(parts)

  defp imgproxy_parser_files do
    @imgproxy_parser_globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.sort()
  end

  defp tmp_file(label) do
    unique = System.unique_integer([:positive])
    Path.join(System.tmp_dir!(), "image_plug_architecture_boundary_test_#{label}_#{unique}.ex")
  end

  defp concrete_plan_references(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {:alias, meta,
         [
           {{:., _dot_meta, [grouped_alias_prefix, :{}]}, _call_meta, grouped_aliases}
         ]} = node,
        violations ->
          grouped_aliases
          |> Enum.map(&concrete_plan_grouped_alias(grouped_alias_prefix, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&violation(meta, concrete_plan_module(&1)))
          |> then(&{node, &1 ++ violations})

        {:__aliases__, meta, [:ImagePlug, :Plan, :Operation, operation | _rest]} = node,
        violations
        when operation in @concrete_plan_names ->
          {node, [violation(meta, concrete_plan_module(operation)) | violations]}

        {:__aliases__, meta, [:Plan, :Operation, operation | _rest]} = node, violations
        when operation in @concrete_plan_names ->
          {node, [violation(meta, "Plan.Operation.#{operation}") | violations]}

        {:__aliases__, meta, [:Operation, operation | _rest]} = node, violations
        when operation in @concrete_plan_names ->
          {node, [violation(meta, "Operation.#{operation}") | violations]}

        node, violations ->
          {node, violations}
      end)

    violations
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp plan_operation_semantic_references(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {{:., meta, [{:__aliases__, _alias_meta, [:ImagePlug, :Plan, :Operation]}, :semantic?]},
         _call_meta, _args} = node,
        violations ->
          {node, [violation(meta, "ImagePlug.Plan.Operation") | violations]}

        {{:., meta, [{:__aliases__, _alias_meta, [:Plan, :Operation]}, :semantic?]}, _call_meta,
         _args} = node,
        violations ->
          {node, [violation(meta, "Plan.Operation") | violations]}

        {{:., meta, [{:__aliases__, _alias_meta, [:Operation]}, :semantic?]}, _call_meta, _args} =
            node,
        violations ->
          {node, [violation(meta, "Operation") | violations]}

        node, violations ->
          {node, violations}
      end)

    violations
    |> Enum.reverse()
    |> Enum.uniq()
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

        {:__aliases__, meta, [:ImagePlug, :Transform, :Operation, transform | _rest]} = node,
        violations
        when transform in @concrete_transform_names ->
          {node, [violation(meta, concrete_transform_module(transform)) | violations]}

        {:__aliases__, meta, [:Transform, :Operation, transform | _rest]} = node, violations
        when transform in @concrete_transform_names ->
          {node, [violation(meta, "Transform.Operation.#{transform}") | violations]}

        {:__aliases__, meta, [:Operation, transform | _rest]} = node, violations
        when transform in @concrete_transform_names ->
          {node, [violation(meta, "Operation.#{transform}") | violations]}

        node, violations ->
          {node, violations}
      end)

    violations
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp post_fetch_resolver_references(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {:alias, meta,
         [
           {{:., _dot_meta, [{:__aliases__, _module_meta, [:ImagePlug, :Transform]}, :{}]},
            _call_meta, grouped_aliases}
         ]} = node,
        violations ->
          grouped_aliases
          |> Enum.map(&post_fetch_resolver_alias/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&violation(meta, &1))
          |> then(&{node, &1 ++ violations})

        {:__aliases__, meta, [:ImagePlug, :Transform, module | _rest]} = node, violations
        when module in [:Resolver, :SourceMetadata, :ResolvedPlan, :Derivation] ->
          {node, [violation(meta, "ImagePlug.Transform.#{module}") | violations]}

        {:__aliases__, meta, [:Transform, module | _rest]} = node, violations
        when module in [:Resolver, :SourceMetadata, :ResolvedPlan, :Derivation] ->
          {node, [violation(meta, "Transform.#{module}") | violations]}

        node, violations ->
          {node, violations}
      end)

    violations
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp imgproxy_parser_references(file) do
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
          |> Enum.filter(&imgproxy_parser_alias?/1)
          |> Enum.map(&violation(meta, imgproxy_parser_module(&1)))
          |> then(&{node, &1 ++ violations})

        {:__aliases__, meta, [:ImagePlug, :Parser, :Imgproxy]} = node, violations ->
          {node, [violation(meta, "ImagePlug.Parser.Imgproxy") | violations]}

        {:__aliases__, meta, [:ImagePlug, :Parser, :Imgproxy | _rest]} = node, violations ->
          {node, [violation(meta, "ImagePlug.Parser.Imgproxy") | violations]}

        {:__aliases__, meta, [:Parser, :Imgproxy]} = node, violations ->
          {node, [violation(meta, "Parser.Imgproxy") | violations]}

        {:__aliases__, meta, [:Parser, :Imgproxy | _rest]} = node, violations ->
          {node, [violation(meta, "Parser.Imgproxy") | violations]}

        {:__aliases__, meta, [:Imgproxy]} = node, violations ->
          {node, [violation(meta, "Imgproxy") | violations]}

        {:__aliases__, meta, [:Imgproxy | _rest]} = node, violations ->
          {node, [violation(meta, "Imgproxy") | violations]}

        node, violations ->
          {node, violations}
      end)

    violations
    |> Enum.reverse()
    |> Enum.uniq()
    |> reject_grouped_alias_child_duplicates()
  end

  defp imgproxy_parser_alias?({:__aliases__, _meta, [:Imgproxy]}), do: true
  defp imgproxy_parser_alias?({:__aliases__, _meta, [:Imgproxy | _rest]}), do: true
  defp imgproxy_parser_alias?(_ast), do: false

  defp imgproxy_parser_module({:__aliases__, _meta, [:Imgproxy]}),
    do: "ImagePlug.Parser.Imgproxy"

  defp imgproxy_parser_module({:__aliases__, _meta, [:Imgproxy | _rest]}),
    do: "ImagePlug.Parser.Imgproxy"

  defp reject_grouped_alias_child_duplicates(violations) do
    grouped_alias_lines =
      violations
      |> Enum.filter(&(&1.module == "ImagePlug.Parser.Imgproxy"))
      |> MapSet.new(& &1.line)

    Enum.reject(
      violations,
      &(&1.module == "Imgproxy" and MapSet.member?(grouped_alias_lines, &1.line))
    )
  end

  defp concrete_transform_grouped_alias(prefix, alias) do
    prefix
    |> alias_parts()
    |> Kernel.++(grouped_alias_parts(alias))
    |> concrete_transform_name()
  end

  defp concrete_plan_grouped_alias(prefix, alias) do
    prefix
    |> alias_parts()
    |> Kernel.++(grouped_alias_parts(alias))
    |> concrete_plan_name()
  end

  defp concrete_plan_name([:ImagePlug, :Plan, :Operation, operation | _rest])
       when operation in @concrete_plan_names,
       do: operation

  defp concrete_plan_name([:Plan, :Operation, operation | _rest])
       when operation in @concrete_plan_names,
       do: operation

  defp concrete_plan_name([:Operation, operation | _rest])
       when operation in @concrete_plan_names,
       do: operation

  defp concrete_plan_name(_parts), do: nil

  defp concrete_transform_name([:ImagePlug, :Transform, :Operation, transform | _rest])
       when transform in @concrete_transform_names,
       do: transform

  defp concrete_transform_name([:Transform, :Operation, transform | _rest])
       when transform in @concrete_transform_names,
       do: transform

  defp concrete_transform_name([:Operation, transform | _rest])
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

  defp concrete_transform_module(transform), do: "ImagePlug.Transform.Operation.#{transform}"

  defp concrete_plan_module({:__aliases__, _meta, [operation]}),
    do: concrete_plan_module(operation)

  defp concrete_plan_module({:__aliases__, _meta, [operation | _rest]}),
    do: concrete_plan_module(operation)

  defp concrete_plan_module(operation), do: "ImagePlug.Plan.Operation.#{operation}"

  defp post_fetch_resolver_alias({:__aliases__, _meta, [module]})
       when module in [:Resolver, :SourceMetadata, :ResolvedPlan, :Derivation],
       do: "ImagePlug.Transform.#{module}"

  defp post_fetch_resolver_alias({:__aliases__, _meta, [module | _rest]})
       when module in [:Resolver, :SourceMetadata, :ResolvedPlan, :Derivation],
       do: "ImagePlug.Transform.#{module}"

  defp post_fetch_resolver_alias(_alias), do: nil

  defp violation(meta, module) do
    %{line: Keyword.fetch!(meta, :line), module: module}
  end
end
