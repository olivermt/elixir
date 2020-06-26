defmodule Mix.Tasks.Xref do
  use Mix.Task

  import Mix.Compilers.Elixir,
    only: [read_manifest: 1, source: 0, source: 1, source: 2, module: 1]

  @shortdoc "Prints cross reference information"
  @recursive true
  @manifest "compile.elixir"

  @moduledoc """
  Prints cross reference information between modules.

  This task is automatically reenabled, so you can print information
  multiple times in the same Mix invocation.

  ## Xref modes

  The `xref` task expects a mode as first argument:

      mix xref MODE

  All available modes are discussed below.

  ### callers CALLEE

  Prints all callers of the given `MODULE`. Example:

      mix xref callers MyMod

  ### graph

  Prints a file dependency graph where an edge from `A` to `B` indicates
  that `A` (source) depends on `B` (sink).

      mix xref graph --format stats

  The following options are accepted:

    * `--exclude` - paths to exclude

    * `--label` - only shows relationships with the given label.
      By default, it keeps all labels that are transitive.
      The labels are "compile", "export" and "runtime". See
      "Dependencies types" section below

    * `--only-nodes` - only shows the node names (no edges)

    * `--only-direct` - the `--label` option will restrict itself
      to only direct dependencies instead of transitive ones

    * `--source` - displays all files that the given source file
      references (directly or indirectly)

    * `--sink` - displays all files that reference the given file
      (directly or indirectly)

    * `--format` - can be set to one of:

      * `pretty` - prints the graph to the terminal using Unicode characters.
        Each prints each file followed by the files it depends on. This is the
        default except on Windows;

      * `plain` - the same as pretty except ASCII characters are used instead of
        Unicode characters. This is the default on Windows;

      * `stats` - prints general statistics about the graph;

      * `dot` - produces a DOT graph description in `xref_graph.dot` in the
        current directory. Warning: this will override any previously generated file

  The `--source` and `--sink` options are particularly useful when trying to understand
  how the modules in a particular file interact with the whole system. You can combine
  those options with `--label` and `--only-nodes` to get all files that exhibit a certain
  property, for example:

      # To get the tree that depend on lib/foo.ex at compile time
      mix xref graph --label compile --sink lib/foo.ex

      # To get all files that depend on lib/foo.ex at compile time
      mix xref graph --label compile --sink lib/foo.ex --only-nodes

      # To show general statistics about the graph
      mix xref graph --format stats

      # To limit statistics only to certain labels
      mix xref graph --format stats --label compile

  ### Dependencies types

  ELixir tracks three types of dependencies between modules: compile,
  exports, and runtime. If a module has a compile time dependency on
  another module, the caller module has to be recompiled whenever the
  callee changes. Compile-time dependencies are typically added when
  using macros or when invoking functions in the module body (outside
  of functions).

  Exports dependencies are compile-time dependencies on the module API,
  namely structs and its public definitions. For example, if you import
  a module but only use its functions, it is an export dependency. If
  you use a struct, it is an export dependency too. Export dependencies
  are only recompiled if the module API changes. Note however compile
  time dependencies have higher precedence than exports. Therefore if
  you import a module and use its macros, it is a compile-time dependency.

  Runtime dependencies are added whenever you invoke another module
  inside a function. Modules with runtime dependencies do not have
  to be compiled when the callee changes, unless there is a transitive
  compile or export time dependency between them.

  ## Shared options

  Those options are shared across all modes:

    * `--include-siblings` - includes dependencies that have `:in_umbrella` set
      to true in the current project in the reports. This can be used to find
      callers or to analyze graphs between projects

    * `--no-compile` - does not compile even if files require compilation

    * `--no-deps-check` - does not check dependencies

    * `--no-archives-check` - does not check archives

    * `--no-elixir-version-check` - does not check the Elixir version from mix.exs

  """

  @switches [
    abort_if_any: :boolean,
    archives_check: :boolean,
    compile: :boolean,
    deps_check: :boolean,
    elixir_version_check: :boolean,
    exclude: :keep,
    format: :string,
    include_siblings: :boolean,
    label: :string,
    only_nodes: :boolean,
    only_direct: :boolean,
    sink: :string,
    source: :string
  ]

  @impl true
  def run(args) do
    {opts, args} = OptionParser.parse!(args, strict: @switches)
    Mix.Task.run("compile", args)
    Mix.Task.reenable("xref")

    case args do
      ["callers", callee] ->
        callers(callee, opts)

      ["graph"] ->
        graph(opts)

      # TODO: Remove on v2.0
      ["deprecated"] ->
        Mix.shell().error(
          "The deprecated check has been moved to the compiler and has no effect now"
        )

      # TODO: Remove on v2.0
      ["unreachable"] ->
        Mix.shell().error(
          "The unreachable check has been moved to the compiler and has no effect now"
        )

      _ ->
        Mix.raise("xref doesn't support this command. For more information run \"mix help xref\"")
    end
  end

  @doc """
  Returns a list of information of all the runtime function calls in the project.

  Each item in the list is a map with the following keys:

    * `:callee` - a tuple containing the module, function, and arity of the call
    * `:line` - an integer representing the line where the function is called
    * `:file` - a binary representing the file where the function is called
    * `:caller_module` - the module where the function is called

  This function returns an empty list when used at the root of an umbrella
  project because there is no compile manifest to extract the function call
  information from. To get the function calls of each child in an umbrella,
  execute the function at the root of each individual application.
  """
  # TODO: Remove on v2.0
  @doc deprecated: "Use compilation tracers described in the Code module"
  @spec calls(keyword()) :: [
          %{
            callee: {module(), atom(), arity()},
            line: integer(),
            file: String.t()
          }
        ]
  def calls(opts \\ []) do
    for manifest <- manifests(opts),
        source(source: source, modules: modules) <- read_manifest(manifest) |> elem(1),
        module <- modules,
        call <- collect_calls(source, module),
        do: call
  end

  defp collect_calls(source, module) do
    with [_ | _] = path <- :code.which(module),
         {:ok, {_, [debug_info: debug_info]}} <- :beam_lib.chunks(path, [:debug_info]),
         {:debug_info_v1, backend, data} <- debug_info,
         {:ok, %{definitions: defs}} <- backend.debug_info(:elixir_v1, module, data, []),
         do: walk_definitions(module, source, defs)
  end

  defp walk_definitions(module, file, definitions) do
    state = %{
      file: file,
      module: module,
      calls: []
    }

    state = Enum.reduce(definitions, state, &walk_definition/2)
    state.calls
  end

  defp walk_definition({_function, _kind, meta, clauses}, state) do
    with_file_meta(state, meta, fn state ->
      Enum.reduce(clauses, state, &walk_clause/2)
    end)
  end

  defp with_file_meta(%{file: original_file} = state, meta, fun) do
    case Keyword.fetch(meta, :file) do
      {:ok, {meta_file, _}} ->
        state = fun.(%{state | file: meta_file})
        %{state | file: original_file}

      :error ->
        fun.(state)
    end
  end

  defp walk_clause({_meta, args, _guards, body}, state) do
    state = walk_expr(args, state)
    walk_expr(body, state)
  end

  # &Mod.fun/arity
  defp walk_expr({:&, meta, [{:/, _, [{{:., _, [module, fun]}, _, []}, arity]}]}, state)
       when is_atom(module) and is_atom(fun) do
    add_call(module, fun, arity, meta, state)
  end

  # Mod.fun(...)
  defp walk_expr({{:., _, [module, fun]}, meta, args}, state)
       when is_atom(module) and is_atom(fun) do
    state = add_call(module, fun, length(args), meta, state)
    walk_expr(args, state)
  end

  # %Module{...}
  defp walk_expr({:%, meta, [module, {:%{}, _meta, args}]}, state)
       when is_atom(module) and is_list(args) do
    state = add_call(module, :__struct__, 0, meta, state)
    walk_expr(args, state)
  end

  # Function call
  defp walk_expr({left, _meta, right}, state) when is_list(right) do
    state = walk_expr(right, state)
    walk_expr(left, state)
  end

  # {x, y}
  defp walk_expr({left, right}, state) do
    state = walk_expr(right, state)
    walk_expr(left, state)
  end

  # [...]
  defp walk_expr(list, state) when is_list(list) do
    Enum.reduce(list, state, &walk_expr/2)
  end

  defp walk_expr(_other, state) do
    state
  end

  defp add_call(module, fun, arity, meta, state) do
    call = %{
      callee: {module, fun, arity},
      caller_module: state.module,
      file: state.file,
      line: meta[:line]
    }

    %{state | calls: [call | state.calls]}
  end

  ## Modes

  defp callers(callee, opts) do
    module = parse_callee(callee)

    file_callers =
      for source <- sources(opts),
          reference = reference(module, source),
          do: {source(source, :source), reference}

    for {file, type} <- Enum.sort(file_callers) do
      Mix.shell().info([file, " (", type, ")"])
    end

    :ok
  end

  defp graph(opts) do
    filter = label_filter(opts[:label])

    {direct_filter, transitive_filter} =
      if opts[:only_direct], do: {filter, :all}, else: {:all, filter}

    write_graph(file_references(direct_filter, opts), transitive_filter, opts)
    :ok
  end

  ## Callers

  defp parse_callee(callee) do
    case Mix.Utils.parse_mfa(callee) do
      {:ok, [module]} -> module
      _ -> Mix.raise("xref callers MODULE expects a MODULE, got: " <> callee)
    end
  end

  defp reference(module, source) do
    cond do
      module in source(source, :compile_references) -> "compile"
      module in source(source, :export_references) -> "export"
      module in source(source, :runtime_references) -> "runtime"
      true -> nil
    end
  end

  ## Graph

  defp excluded(opts) do
    opts
    |> Keyword.get_values(:exclude)
    |> Enum.flat_map(&[{&1, nil}, {&1, :compile}, {&1, :export}])
  end

  defp label_filter(nil), do: :all
  defp label_filter("compile"), do: :compile
  defp label_filter("export"), do: :export
  defp label_filter("runtime"), do: nil
  defp label_filter(other), do: Mix.raise("unknown --label #{other}")

  defp file_references(filter, opts) do
    module_sources =
      for manifest_path <- manifests(opts),
          {manifest_modules, manifest_sources} = read_manifest(manifest_path),
          module(module: module, sources: sources) <- manifest_modules,
          source <- sources,
          source = Enum.find(manifest_sources, &match?(source(source: ^source), &1)),
          do: {module, source}

    all_modules = MapSet.new(module_sources, &elem(&1, 0))

    Map.new(module_sources, fn {current, source} ->
      source(
        runtime_references: runtime,
        export_references: exports,
        compile_references: compile,
        source: file
      ) = source

      compile_references =
        modules_to_nodes(compile, :compile, current, source, module_sources, all_modules, filter)

      export_references =
        modules_to_nodes(exports, :export, current, source, module_sources, all_modules, filter)

      runtime_references =
        modules_to_nodes(runtime, nil, current, source, module_sources, all_modules, filter)

      references =
        runtime_references
        |> Map.merge(export_references)
        |> Map.merge(compile_references)
        |> Enum.to_list()

      {file, references}
    end)
  end

  defp modules_to_nodes(_, label, _, _, _, _, filter) when filter != :all and label != filter do
    %{}
  end

  defp modules_to_nodes(modules, label, current, source, module_sources, all_modules, _filter) do
    for module <- modules,
        module != current,
        module in all_modules,
        module_sources[module] != source,
        do: {source(module_sources[module], :source), label},
        into: %{}
  end

  defp write_graph(file_references, filter, opts) do
    excluded = excluded(opts)

    {roots, file_references} =
      case {opts[:source], opts[:sink]} do
        {nil, nil} ->
          roots =
            file_references |> Enum.map(&{elem(&1, 0), nil}) |> Kernel.--(excluded) |> Map.new()

          {roots, file_references}

        {source, nil} ->
          if file_references[source] do
            file_references = filter_for_source(file_references, filter)
            {%{source => nil}, file_references}
          else
            Mix.raise("Source could not be found: #{source}")
          end

        {nil, sink} ->
          if file_references[sink] do
            file_references = filter_for_sink(file_references, sink, filter)

            roots =
              file_references
              |> Map.delete(sink)
              |> Enum.map(&{elem(&1, 0), nil})
              |> Kernel.--(excluded)
              |> Map.new()

            {roots, file_references}
          else
            Mix.raise("Sink could not be found: #{sink}")
          end

        {_, _} ->
          Mix.raise("mix xref graph expects only one of --source and --sink")
      end

    callback = fn {file, type} ->
      children = if opts[:only_nodes], do: [], else: Map.get(file_references, file, [])
      type = type && "(#{type})"
      {{file, type}, Enum.sort(children -- excluded)}
    end

    case opts[:format] do
      "dot" ->
        Mix.Utils.write_dot_graph!(
          "xref_graph.dot",
          "xref graph",
          Enum.sort(roots),
          callback,
          opts
        )

        """
        Generated "xref_graph.dot" in the current directory. To generate a PNG:

           dot -Tpng xref_graph.dot -o xref_graph.png

        For more options see http://www.graphviz.org/.
        """
        |> String.trim_trailing()
        |> Mix.shell().info()

      "stats" ->
        stats(file_references)

      _ ->
        Mix.Utils.print_tree(Enum.sort(roots), callback, opts)
    end
  end

  defp filter_for_source(file_references, :all), do: file_references

  defp filter_for_source(file_references, filter) do
    Enum.reduce(file_references, %{}, fn {key, _}, acc ->
      {children, _} = filter_for_source(file_references, key, %{}, %{}, filter)
      Map.put(acc, key, Map.to_list(children))
    end)
  end

  defp filter_for_source(references, key, acc, seen, filter) do
    nodes = references[key]

    if is_nil(nodes) || seen[key] do
      {acc, seen}
    else
      seen = Map.put(seen, key, true)

      Enum.reduce(nodes, {acc, seen}, fn {child_key, type}, {acc, seen} ->
        if type == filter do
          {Map.put(acc, child_key, type), Map.put(seen, child_key, true)}
        else
          filter_for_source(references, child_key, acc, seen, filter)
        end
      end)
    end
  end

  defp filter_for_sink(file_references, sink, filter) do
    fun = if filter == :all, do: fn _ -> true end, else: fn type -> type == filter end

    file_references
    |> invert_references(fn _ -> true end)
    |> depends_on_sink([{sink, nil}], %{})
    |> invert_references(fun)
  end

  defp depends_on_sink(file_references, new_nodes, acc) do
    Enum.reduce(new_nodes, acc, fn {new_node_name, _type}, acc ->
      new_nodes = file_references[new_node_name]

      if acc[new_node_name] || !new_nodes do
        acc
      else
        depends_on_sink(file_references, new_nodes, Map.put(acc, new_node_name, new_nodes))
      end
    end)
  end

  defp invert_references(file_references, fun) do
    Enum.reduce(file_references, %{}, fn {file, references}, acc ->
      Enum.reduce(references, acc, fn {reference, type}, acc ->
        if fun.(type) do
          Map.update(acc, reference, [{file, type}], &[{file, type} | &1])
        else
          acc
        end
      end)
    end)
  end

  defp stats(references) do
    shell = Mix.shell()

    counters =
      Enum.reduce(references, %{compile: 0, export: 0, nil: 0}, fn {_, deps}, acc ->
        Enum.reduce(deps, acc, fn {_, value}, acc ->
          Map.update!(acc, value, &(&1 + 1))
        end)
      end)

    shell.info("Tracked files: #{map_size(references)} (nodes)")
    shell.info("Compile dependencies: #{counters.compile} (edges)")
    shell.info("Exports dependencies: #{counters.export} (edges)")
    shell.info("Runtime dependencies: #{counters.nil} (edges)")

    outgoing =
      references
      |> Enum.map(fn {file, deps} -> {length(deps), file} end)
      |> Enum.sort()
      |> Enum.take(-10)
      |> Enum.reverse()

    shell.info("\nTop #{length(outgoing)} files with most outgoing dependencies:")
    for {count, file} <- outgoing, do: shell.info("  * #{file} (#{count})")

    incoming =
      references
      |> Enum.reduce(%{}, fn {_, deps}, acc ->
        Enum.reduce(deps, acc, fn {file, _}, acc ->
          Map.update(acc, file, 1, &(&1 + 1))
        end)
      end)
      |> Enum.map(fn {file, count} -> {count, file} end)
      |> Enum.sort()
      |> Enum.take(-10)
      |> Enum.reverse()

    shell.info("\nTop #{length(incoming)} files with most incoming dependencies:")
    for {count, file} <- incoming, do: shell.info("  * #{file} (#{count})")
  end

  ## Helpers

  defp sources(opts) do
    for manifest <- manifests(opts),
        source() = source <- read_manifest(manifest) |> elem(1),
        do: source
  end

  defp manifests(opts) do
    siblings =
      if opts[:include_siblings] do
        for %{scm: Mix.SCM.Path, opts: opts} <- Mix.Dep.cached(),
            opts[:in_umbrella],
            do: Path.join([opts[:build], ".mix", @manifest])
      else
        []
      end

    [Path.join(Mix.Project.manifest_path(), @manifest) | siblings]
  end
end
