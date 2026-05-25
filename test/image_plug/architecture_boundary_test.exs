defmodule ImagePlug.ArchitectureBoundaryTest do
  use ExUnit.Case, async: true

  @request_source_response_globs [
    "lib/image_plug/request.ex",
    "lib/image_plug/request/**/*.ex",
    "lib/image_plug/source.ex",
    "lib/image_plug/source/**/*.ex",
    "lib/image_plug/response.ex",
    "lib/image_plug/response/**/*.ex"
  ]
  @parser_forbidden_globs [
    "lib/image_plug/request.ex",
    "lib/image_plug/request/**/*.ex",
    "lib/image_plug/source.ex",
    "lib/image_plug/source/**/*.ex",
    "lib/image_plug/response.ex",
    "lib/image_plug/response/**/*.ex",
    "lib/image_plug/cache.ex",
    "lib/image_plug/cache/**/*.ex",
    "lib/image_plug/output.ex",
    "lib/image_plug/output/**/*.ex"
  ]
  @imgproxy_parser_globs [
    "lib/image_plug/parser/imgproxy.ex",
    "lib/image_plug/parser/imgproxy/**/*.ex"
  ]
  @cache_key_files ["lib/image_plug/cache/key.ex"]
  @boundary_files %{
    ImagePlug.Application => "lib/application.ex",
    ImagePlug.Cache => "lib/image_plug/cache.ex",
    ImagePlug.Format => "lib/image_plug/format.ex",
    ImagePlug.Output => "lib/image_plug/output.ex",
    ImagePlug.Plan => "lib/image_plug/plan.ex",
    ImagePlug.Parser => "lib/image_plug/parser.ex",
    ImagePlug.Parser.Imgproxy => "lib/image_plug/parser/imgproxy.ex",
    ImagePlug.Request => "lib/image_plug/request.ex",
    ImagePlug.Response => "lib/image_plug/response.ex",
    ImagePlug.Source => "lib/image_plug/source.ex",
    ImagePlug.Telemetry => "lib/image_plug/telemetry.ex",
    ImagePlug.Transform => "lib/image_plug/transform.ex"
  }
  @concrete_plan_names [
    :Background,
    :Canvas,
    :CropGuided,
    :CropRegion,
    :Padding,
    :Resize
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
    :Background,
    :AutoOrient,
    :ExtendCanvas,
    :Padding,
    :AdaptiveResize
  ]
  @orientation_transform_modules [
    "ImagePlug.Transform.Operation.AutoOrient",
    "ImagePlug.Transform.Operation.Rotate",
    "ImagePlug.Transform.Operation.Flip"
  ]
  @post_fetch_transform_state_modules [
    ImagePlug.Transform.PlanExecutor
  ]
  @cache_prefetch_forbidden_transform_state_names [
    :PlanExecutor
  ]
  @runtime_forbidden_transform_execution_names [:PlanExecutor]
  @cache_prefetch_forbidden_transform_functions [
    :execute_plan
  ]

  test "parser boundary declarations stay limited to format, parser, plan, and transform construction APIs" do
    parser = boundary_declaration(ImagePlug.Parser)
    imgproxy = boundary_declaration(ImagePlug.Parser.Imgproxy)

    assert_boundary_deps(parser, [ImagePlug.Format, ImagePlug.Plan, ImagePlug.Transform])
    assert_boundary_exports(parser, [ImagePlug.Parser.Imgproxy])

    assert_boundary_deps(imgproxy, [
      ImagePlug.Format,
      ImagePlug.Parser,
      ImagePlug.Plan,
      ImagePlug.Transform
    ])

    assert_boundary_exports(imgproxy, [ImagePlug.Parser.Imgproxy.SourceScheme])

    assert_allowed_deps(parser, [ImagePlug.Format, ImagePlug.Plan, ImagePlug.Transform])

    assert_allowed_deps(imgproxy, [
      ImagePlug.Format,
      ImagePlug.Parser,
      ImagePlug.Plan,
      ImagePlug.Transform
    ])
  end

  test "request boundary declaration depends on generic facades only" do
    request = boundary_declaration(ImagePlug.Request)

    assert_boundary_deps(request, [
      ImagePlug.Format,
      ImagePlug.Plan,
      ImagePlug.Cache,
      ImagePlug.Source,
      ImagePlug.Output,
      ImagePlug.Response,
      ImagePlug.Telemetry,
      ImagePlug.Transform
    ])

    refute_boundary_deps(request, [ImagePlug.Parser | concrete_transform_modules()])

    assert_boundary_exports(request, [
      ImagePlug.Request.Options,
      ImagePlug.Request.Runner,
      ImagePlug.Request.SourceSessionSupervisor
    ])
  end

  test "application boundary owns OTP startup and depends on request lifecycle infrastructure" do
    application = boundary_declaration(ImagePlug.Application)

    assert_boundary_deps(application, [ImagePlug.Request])
    assert_boundary_exports(application, [])
  end

  test "source boundary owns source identity and fetch context" do
    source = boundary_declaration(ImagePlug.Source)

    assert_boundary_deps(source, [ImagePlug.Plan, ImagePlug.Telemetry])

    refute_boundary_deps(source, [
      ImagePlug.Request,
      ImagePlug.Response,
      ImagePlug.Cache,
      ImagePlug.Output,
      ImagePlug.Transform,
      ImagePlug.Parser
    ])

    assert_boundary_exports(source, [
      ImagePlug.Source.Resolved,
      ImagePlug.Source.Response,
      ImagePlug.Source.StreamError,
      ImagePlug.Source.HTTP,
      ImagePlug.Source.File,
      ImagePlug.Source.S3
    ])
  end

  test "response boundary owns plug response delivery" do
    response = boundary_declaration(ImagePlug.Response)

    assert_boundary_deps(response, [
      ImagePlug.Cache,
      ImagePlug.Output,
      ImagePlug.Plan,
      ImagePlug.Telemetry
    ])

    refute_boundary_deps(response, [ImagePlug.Request, ImagePlug.Source, ImagePlug.Transform])

    assert_boundary_exports(response, [
      ImagePlug.Response.PreparedStream,
      ImagePlug.Response.Sender
    ])
  end

  test "response delivery stays unaware of source sessions and cache staging" do
    forbidden_terms = [
      "ImagePlug.Request.SourceSession",
      "ImagePlug.Request.SourceSessionSupervisor",
      "ImagePlug.Cache.Sink",
      "Cache.open_sink",
      "Cache.write_chunk",
      "Cache.commit_sink",
      "Cache.abort_sink",
      "Cache.put"
    ]

    violations =
      for file <- [
            "lib/image_plug/response/prepared_stream.ex",
            "lib/image_plug/response/sender.ex"
          ],
          File.exists?(file),
          {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          term <- forbidden_terms,
          String.contains?(line, term) do
        "#{file}:#{number} must not depend on #{term}; SourceSession owns cache staging"
      end

    assert violations == []
  end

  test "request code treats cache sinks as opaque cache values" do
    request_sources =
      "lib/image_plug/request/**/*.ex"
      |> Path.wildcard()
      |> Map.new(fn file -> {file, File.read!(file)} end)

    forbidden_terms = [
      "ImagePlug.Cache.Sink",
      "Cache.Sink",
      ".Sink",
      "%Sink{",
      "%ImagePlug.Cache.Sink{"
    ]

    violations =
      for {file, source} <- request_sources,
          term <- forbidden_terms,
          String.contains?(source, term) do
        "#{file} must not inspect cache sink internals through #{term}"
      end

    assert violations == []
  end

  test "prepared stream wiring keeps lifecycle ownership in request and byte delivery in response" do
    response_sources =
      "lib/image_plug/response/**/*.ex"
      |> Path.wildcard()
      |> Map.new(fn file -> {file, File.read!(file)} end)

    violations =
      for {file, source} <- response_sources,
          term <- ["SourceSession", "SourceSessionSupervisor"],
          String.contains?(source, term) do
        "#{file} must not reference #{term}; response delivery uses PreparedStream callbacks"
      end

    assert violations == []

    request = boundary_declaration(ImagePlug.Request)

    forbidden_exports = [
      ImagePlug.Request.SourceSession,
      ImagePlug.Request.SourceSession.Prepared,
      ImagePlug.Request.SourceSession.Request
    ]

    assert Enum.filter(request.exports, &(&1 in forbidden_exports)) == []
  end

  test "telemetry boundary remains a dependency-free facade" do
    telemetry = boundary_declaration(ImagePlug.Telemetry)

    assert_boundary_deps(telemetry, [])
    assert_boundary_exports(telemetry, [])
  end

  test "format boundary remains dependency-free" do
    format = boundary_declaration(ImagePlug.Format)

    assert_boundary_deps(format, [])
    assert_boundary_exports(format, [])
  end

  test "output boundary depends only on format and plan data" do
    output = boundary_declaration(ImagePlug.Output)

    assert_boundary_deps(output, [ImagePlug.Format, ImagePlug.Plan])

    refute_boundary_deps(output, [
      ImagePlug.Source,
      ImagePlug.Parser,
      ImagePlug.Request,
      ImagePlug.Response,
      ImagePlug.Cache,
      ImagePlug.Transform
    ])
  end

  test "request, source, and response code does not depend on concrete transform modules" do
    violations =
      for file <- request_source_response_files(),
          violation <- concrete_transform_references(file) do
        "#{file}:#{violation.line} must not name #{violation.module}; use ImagePlug.Transform dispatch instead"
      end

    assert violations == []
  end

  test "request, source, and response code does not depend on concrete plan operation modules" do
    violations =
      for file <- request_source_response_files(),
          violation <- concrete_plan_references(file) do
        "#{file}:#{violation.line} must not name #{violation.module}; use generic Plan/Transform facades instead"
      end

    assert violations == []
  end

  test "request, source, and response code does not inspect plan operation semantic staging" do
    violations =
      for file <- request_source_response_files(),
          violation <- plan_operation_semantic_references(file) do
        "#{file}:#{violation.line} must not call #{violation.module}.semantic?/1; use ImagePlug.Transform executable planning instead"
      end

    assert violations == []
  end

  test "request, source, and response code does not call removed or internal transform execution APIs" do
    violations =
      for file <- request_source_response_files(),
          violation <- runtime_forbidden_transform_execution_references(file) do
        "#{file}:#{violation.line} must not use #{violation.module}; execute canonical plans through ImagePlug.Transform.execute_plan/3"
      end

    assert violations == []
  end

  test "request, source, response, cache, and output code does not depend on imgproxy parser structs" do
    violations =
      for file <- parser_forbidden_files(),
          violation <- imgproxy_parser_references(file) do
        "#{file}:#{violation.line} must not name #{violation.module}; keep Imgproxy parser dependencies out of request, source, response, cache, and output code"
      end

    assert violations == []
  end

  test "cache boundary declaration avoids post-fetch transform state dependencies" do
    cache = boundary_declaration(ImagePlug.Cache)

    assert_boundary_deps(cache, [
      ImagePlug.Format,
      ImagePlug.Plan,
      ImagePlug.Output,
      ImagePlug.Transform,
      ImagePlug.Telemetry
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
      ImagePlug.Request.Runner,
      ImagePlug.Request,
      ImagePlug.Source,
      ImagePlug.Response,
      ImagePlug.Cache,
      ImagePlug.Output
    ])

    assert_boundary_exports_include(transform, [
      ImagePlug.Transform.State,
      ImagePlug.Transform.Chain,
      ImagePlug.Transform.DecodePlanner,
      ImagePlug.Transform.Materializer,
      ImagePlug.Transform.KeyData,
      ImagePlug.Transform.Operation.Resize,
      ImagePlug.Transform.Operation.ExtendCanvas,
      ImagePlug.Transform.Operation.Padding,
      ImagePlug.Transform.Operation.Background,
      ImagePlug.Transform.Operation.AutoOrient,
      ImagePlug.Transform.Operation.Rotate,
      ImagePlug.Transform.Operation.Flip,
      ImagePlug.Transform.Operation.Crop
    ])
  end

  test "plan boundary exports canonical composition modules and depends only on formats" do
    plan = boundary_declaration(ImagePlug.Plan)

    assert_boundary_deps(plan, [ImagePlug.Format])

    assert_boundary_exports_include(plan, [
      ImagePlug.Plan.Color,
      ImagePlug.Plan.Operation.Padding,
      ImagePlug.Plan.Operation.Background
    ])
  end

  test "external color dependency stays behind the Plan color module" do
    allowed_files = MapSet.new(["lib/image_plug/plan/color.ex"])

    violations =
      for file <- Path.wildcard("lib/**/*.ex"),
          not MapSet.member?(allowed_files, file),
          line <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          external_color_reference?(line) do
        {text, number} = line
        "#{file}:#{number} must not call or name external Color dependency APIs: #{text}"
      end

    assert violations == []
  end

  test "cache key construction does not depend on post-fetch transform execution state" do
    violations =
      for file <- @cache_key_files,
          violation <- cache_prefetch_unsafe_transform_references(file) do
        "#{file}:#{violation.line} must not name #{violation.module}; final cache keys are prefetch-safe"
      end

    assert violations == []
  end

  test "imgproxy parser does not depend on executable transform operation modules" do
    violations =
      for file <- imgproxy_parser_files(),
          violation <- concrete_transform_references(file),
          violation.module not in @orientation_transform_modules do
        "#{file}:#{violation.line} must not name #{violation.module}; parser output is semantic Plan operations"
      end

    assert violations == []
  end

  defp request_source_response_files do
    @request_source_response_globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.sort()
  end

  defp parser_forbidden_files do
    @parser_forbidden_globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
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

  defp external_color_reference?({line, _number}) do
    direct_external_color_module?(line) or
      external_color_call?(line)
  end

  defp direct_external_color_module?(line) do
    Regex.match?(~r/\balias\s+Color\b/, line) or
      Regex.match?(~r/%Color\./, line) or
      Regex.match?(~r/\bColor\.(SRGB|HSL|HSV|Lab|LCH|XYZ|new|parse|convert)\b/, line)
  end

  defp external_color_call?(line) do
    case Regex.run(~r/\bColor\.([a-zA-Z_][a-zA-Z0-9_]*[?!]?)/, line) do
      [_match, function] ->
        function not in [
          "alpha",
          "t",
          "rgb",
          "rgb_hex",
          "rgba",
          "with_alpha",
          "valid?",
          "key_data",
          "to_rgb_list",
          "to_rgba_list"
        ]

      nil ->
        false
    end
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

  defp concrete_plan_references(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {tag, meta,
         [
           {{:., _dot_meta, [grouped_alias_prefix, :{}]}, _call_meta, grouped_aliases}
         ]} = node,
        violations
        when tag in [:alias, :import] ->
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

  defp runtime_forbidden_transform_execution_references(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {tag, meta,
         [
           {{:., _dot_meta, [{:__aliases__, _module_meta, [:ImagePlug, :Transform]}, :{}]},
            _call_meta, grouped_aliases}
         ]} = node,
        violations
        when tag in [:alias, :import] ->
          grouped_aliases
          |> Enum.map(&runtime_forbidden_transform_execution_alias/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&violation(meta, &1))
          |> then(&{node, &1 ++ violations})

        {{:., meta,
          [{:__aliases__, _alias_meta, [:ImagePlug, :Transform, :PlanExecutor]}, :execute]},
         _call_meta, _args} = node,
        violations ->
          {node, [violation(meta, "ImagePlug.Transform.PlanExecutor.execute") | violations]}

        {{:., meta, [{:__aliases__, _alias_meta, [:Transform, :PlanExecutor]}, :execute]},
         _call_meta, _args} = node,
        violations ->
          {node, [violation(meta, "Transform.PlanExecutor.execute") | violations]}

        {{:., meta, [{:__aliases__, _alias_meta, [:PlanExecutor]}, :execute]}, _call_meta, _args} =
            node,
        violations ->
          {node, [violation(meta, "PlanExecutor.execute") | violations]}

        {:__aliases__, meta, [:ImagePlug, :Transform, module | _rest]} = node, violations
        when module in @runtime_forbidden_transform_execution_names ->
          {node, [violation(meta, "ImagePlug.Transform.#{module}") | violations]}

        {:__aliases__, meta, [:Transform, module | _rest]} = node, violations
        when module in @runtime_forbidden_transform_execution_names ->
          {node, [violation(meta, "Transform.#{module}") | violations]}

        {:__aliases__, meta, [module | _rest]} = node, violations
        when module in @runtime_forbidden_transform_execution_names ->
          {node, [violation(meta, "#{module}") | violations]}

        node, violations ->
          {node, violations}
      end)

    violations
    |> Enum.reverse()
    |> Enum.uniq()
    |> reject_runtime_forbidden_transform_execution_child_duplicates()
  end

  defp concrete_transform_references(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {tag, meta,
         [
           {{:., _dot_meta, [grouped_alias_prefix, :{}]}, _call_meta, grouped_aliases}
         ]} = node,
        violations
        when tag in [:alias, :import] ->
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

  defp cache_prefetch_unsafe_transform_references(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {tag, meta,
         [
           {{:., _dot_meta, [{:__aliases__, _module_meta, [:ImagePlug, :Transform]}, :{}]},
            _call_meta, grouped_aliases}
         ]} = node,
        violations
        when tag in [:alias, :import] ->
          grouped_aliases
          |> Enum.map(&cache_prefetch_unsafe_transform_alias/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&violation(meta, &1))
          |> then(&{node, &1 ++ violations})

        {:__aliases__, meta, [:ImagePlug, :Transform, module | _rest]} = node, violations
        when module in @cache_prefetch_forbidden_transform_state_names ->
          {node, [violation(meta, "ImagePlug.Transform.#{module}") | violations]}

        {:__aliases__, meta, [:Transform, module | _rest]} = node, violations
        when module in @cache_prefetch_forbidden_transform_state_names ->
          {node, [violation(meta, "Transform.#{module}") | violations]}

        {{:., meta, [{:__aliases__, _alias_meta, [:ImagePlug, :Transform]}, function]},
         _call_meta, _args} = node,
        violations
        when function in @cache_prefetch_forbidden_transform_functions ->
          {node, [violation(meta, "ImagePlug.Transform.#{function}") | violations]}

        {{:., meta, [{:__aliases__, _alias_meta, [:Transform]}, function]}, _call_meta, _args} =
            node,
        violations
        when function in @cache_prefetch_forbidden_transform_functions ->
          {node, [violation(meta, "Transform.#{function}") | violations]}

        {{:., meta,
          [{:__aliases__, _alias_meta, [:ImagePlug, :Transform, :PlanExecutor]}, :execute]},
         _call_meta, _args} = node,
        violations ->
          {node, [violation(meta, "ImagePlug.Transform.PlanExecutor.execute") | violations]}

        {{:., meta, [{:__aliases__, _alias_meta, [:Transform, :PlanExecutor]}, :execute]},
         _call_meta, _args} = node,
        violations ->
          {node, [violation(meta, "Transform.PlanExecutor.execute") | violations]}

        {{:., meta, [{:__aliases__, _alias_meta, [:PlanExecutor]}, :execute]}, _call_meta, _args} =
            node,
        violations ->
          {node, [violation(meta, "PlanExecutor.execute") | violations]}

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

  defp reject_runtime_forbidden_transform_execution_child_duplicates(violations) do
    grouped_alias_lines =
      violations
      |> Enum.filter(
        &(&1.module in [
            "ImagePlug.Transform.PlanExecutor"
          ])
      )
      |> MapSet.new(& &1.line)

    resolver_call_lines =
      violations
      |> Enum.filter(
        &(&1.module in [
            "PlanExecutor.execute",
            "Transform.PlanExecutor.execute"
          ])
      )
      |> MapSet.new(& &1.line)

    Enum.reject(violations, fn
      %{module: module, line: line}
      when module in ["PlanExecutor"] ->
        MapSet.member?(grouped_alias_lines, line) or MapSet.member?(resolver_call_lines, line)

      _violation ->
        false
    end)
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

  defp cache_prefetch_unsafe_transform_alias({:__aliases__, _meta, [module]})
       when module in @cache_prefetch_forbidden_transform_state_names,
       do: "ImagePlug.Transform.#{module}"

  defp cache_prefetch_unsafe_transform_alias({:__aliases__, _meta, [module | _rest]})
       when module in @cache_prefetch_forbidden_transform_state_names,
       do: "ImagePlug.Transform.#{module}"

  defp cache_prefetch_unsafe_transform_alias(_alias), do: nil

  defp runtime_forbidden_transform_execution_alias({:__aliases__, _meta, [module]})
       when module in @runtime_forbidden_transform_execution_names,
       do: "ImagePlug.Transform.#{module}"

  defp runtime_forbidden_transform_execution_alias({:__aliases__, _meta, [module | _rest]})
       when module in @runtime_forbidden_transform_execution_names,
       do: "ImagePlug.Transform.#{module}"

  defp runtime_forbidden_transform_execution_alias(_alias), do: nil

  defp violation(meta, module) do
    %{line: Keyword.fetch!(meta, :line), module: module}
  end
end
