defmodule Mix.Tasks.ExAst.Search do
  @shortdoc "Search Elixir code by AST pattern"
  @moduledoc """
  Searches for AST patterns in Elixir source files.

  ## Usage

      mix ex_ast.search 'IO.inspect(_)' [path ...]

  ## Options

    * `-e`, `--pattern` — add a pattern to a multi-pattern batch (repeatable)
    * `--count` — only print the number of matches
    * `--count-by-file` — print per-file match counts, most matches first
    * `--limit n` — stop after returning this many matches
    * `--allow-broad` — allow unbounded broad searches like `_`
    * `--expand-imports` — resolve bare `import Mod` (and `import Mod,
      except: [...]`) to the module's real exports, so `map(a, b)` matches
      `Mod.map(_, _)`. Requires `Mod` to be compiled and loadable.
    * `--inside 'pattern'` — only match inside ancestors matching this pattern
    * `--not-inside 'pattern'` — reject matches inside ancestors matching this pattern
    * `--parent 'pattern'` / `--not-parent 'pattern'` — filter by direct semantic parent
    * `--ancestor 'pattern'` / `--not-ancestor 'pattern'` — filter by semantic ancestor
    * `--has-child 'pattern'` / `--not-has-child 'pattern'` — filter by direct semantic child
    * `--contains 'pattern'` / `--not-contains 'pattern'` — filter by semantic descendant
    * `--has-descendant 'pattern'` / `--not-has-descendant 'pattern'` — aliases for contains filters
    * `--has 'pattern'` / `--not-has 'pattern'` — aliases for contains filters
    * `--follows 'pattern'` / `--not-follows 'pattern'` — filter by earlier sibling
    * `--precedes 'pattern'` / `--not-precedes 'pattern'` — filter by later sibling
    * `--immediately-follows 'pattern'` / `--not-immediately-follows 'pattern'` — filter by previous sibling
    * `--immediately-precedes 'pattern'` / `--not-immediately-precedes 'pattern'` — filter by next sibling
    * `--first` / `--not-first`, `--last` / `--not-last`, `--nth n` / `--not-nth n` — filter by sibling position
    * `--comment text` / `--not-comment text` — filter by associated comments
    * `--comment-before text`, `--comment-after text`, `--comment-inside text`, `--comment-inline text` — filter by comment location

    Comment values are substrings by default. Use `/.../` or `~r/.../` for regexes, including flags like `/todo/i`.

  ## Pattern syntax

  Patterns are valid Elixir expressions:

    * Variables (`name`, `expr`) — capture any node
    * `_` or `_name` — wildcard (match, don't capture)
    * Structs/maps — partial match (only listed keys must be present)
    * Pipes are normalized — `data |> Enum.map(f)` matches `Enum.map(data, f)`
    * Everything else — literal match

  ## Multiple patterns in one run

  Pass a repeatable `-e` / `--pattern` flag to search several patterns in a
  single invocation. Each file is read and parsed once for the whole batch,
  avoiding BEAM startup and per-file re-parsing per pattern — useful for
  analyzers that run many checks over the same tree.

      mix ex_ast.search -e 'IO.inspect(_)' -e 'dbg(_)' lib/

  In this mode there is no positional pattern; remaining positional args are
  paths. Combining a positional pattern with `-e` is an error.

  ### Per-pattern selector filters

  Selector-scoping flags (`--inside`, `--not-inside`, `--parent`, `--contains`,
  etc.) are *per-pattern*: a filter binds to the most recent preceding `-e`,
  mirroring `grep -e`. Filters do not bleed across patterns.

      mix ex_ast.search \\
        -e 'App.Repo.get!(_, _)' --inside 'def handle_call(_, _, _) do _ end' \\
        -e 'IO.inspect(_)' --not-inside 'test _ do _ end' \\
        lib/ test/

  Global flags (`--count`, `--json`, `--expand-imports`, `--limit`,
  `--allow-broad`, paths) apply to the whole batch.

  Each pattern is tagged in the output by its raw pattern string. Two `-e` with
  the same pattern string would collide, so duplicate patterns raise an error.

  > #### Per-pattern path scope not expressible {: .warning}
  >
  > Multi-pattern search uses one shared path list for all patterns, so
  > per-pattern path include/exclude cannot be expressed in a single call —
  > group patterns by shared path scope into separate invocations. Per-pattern
  > *selector filters* (above) do work, because they live in each pattern's
  > selector.

  ## Examples

      mix ex_ast.search 'IO.inspect(_)'
      mix ex_ast.search '%Step{id: "subject"}' lib/documents/
      mix ex_ast.search '{:error, reason}' lib/ test/
      mix ex_ast.search --count 'dbg(_)'
      mix ex_ast.search --inside 'def handle_call(_, _, _) do _ end' 'Repo.get!(_)'
      mix ex_ast.search --not-inside 'test _ do _ end' 'IO.inspect(_)'
      mix ex_ast.search 'IO.inspect(_)' --parent 'def _ do ... end'
      mix ex_ast.search 'def name do ... end' --contains 'Repo.transaction(_)' --not-contains 'IO.inspect(...)'
      mix ex_ast.search 'Repo.delete(record)' --follows 'record = Repo.get!(_, _)'
      mix ex_ast.search 'def name do ... end' --comment-inside TODO
      mix ex_ast.search 'def name do ... end' --comment-inside '/TODO|FIXME/'
      mix ex_ast.search '_' lib/ --limit 100
      mix ex_ast.search 'Enum.map(_, _)' lib/ --expand-imports
      mix ex_ast.search -e 'IO.inspect(_)' -e 'dbg(_)' lib/
      mix ex_ast.search -e 'App.Repo.get!(_, _)' --inside 'def _ do ... end' -e 'dbg(_)' lib/
  """

  use Mix.Task

  alias ExAST.CLI.JSON
  alias ExAST.CLI.Output
  alias ExAST.CLI.SelectorOptions

  @global_switches [
    count: :boolean,
    count_by_file: :boolean,
    limit: :integer,
    allow_broad: :boolean,
    format: :string,
    json: :boolean,
    expand_imports: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    if Enum.any?(args, &(&1 in ["-e", "--pattern"])) do
      run_many(args)
    else
      run_single(args)
    end
  end

  defp run_single(args) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: @global_switches ++ SelectorOptions.switches())

    case positional do
      [pattern | paths] ->
        paths = if paths == [], do: ["lib/"], else: paths
        do_search(paths, pattern, opts)

      _ ->
        Mix.raise("Usage: mix ex_ast.search 'pattern' [path ...]")
    end
  end

  defp run_many(args) do
    {head, segments} = segment_argv(args)

    {global_opts, head_positional, _} =
      OptionParser.parse(head, strict: @global_switches ++ SelectorOptions.switches())

    reject_head_selector_flags!(global_opts)

    if head_positional != [] do
      Mix.raise(
        "Cannot mix a positional pattern with -e; pass every pattern via -e " <>
          "(got positional: #{Enum.join(head_positional, " ")})"
      )
    end

    if segments == [] do
      Mix.raise("Usage: mix ex_ast.search -e 'pattern' [-e 'pattern' ...] [path ...]")
    end

    {patterns, seg_global_opts, paths} = compile_segments(segments)
    global_opts = Keyword.merge(global_opts, seg_global_opts)
    reject_multi_unsupported!(global_opts)
    paths = if paths == [], do: ["lib/"], else: paths

    {named_patterns, key_to_str} = build_named_patterns!(patterns)
    pattern_strs = Enum.map(patterns, & &1.pattern)

    search_opts = Keyword.take(global_opts, [:limit, :allow_broad, :expand_imports])

    results = ExAST.search_many(paths, named_patterns, search_opts)

    render_many(results, pattern_strs, key_to_str, global_opts)
  end

  defp reject_head_selector_flags!(global_opts) do
    case Keyword.take(global_opts, Keyword.keys(SelectorOptions.switches())) do
      [] ->
        :ok

      stray ->
        flags = stray |> Keyword.keys() |> Enum.map_join(", ", &flag_name/1)

        Mix.raise(
          "Selector filter #{flags} appears before the first -e; selector filters " <>
            "bind to the preceding -e pattern, so put them after the -e they apply to"
        )
    end
  end

  defp flag_name(key) do
    dashed = String.replace("#{key}", "_", "-")
    "--" <> dashed
  end

  defp segment_argv(args) do
    {head, rest} = Enum.split_while(args, &(&1 not in ["-e", "--pattern"]))
    {head, split_segments(rest, [])}
  end

  defp split_segments([], acc), do: Enum.reverse(acc)

  defp split_segments([flag, pattern | rest], acc) when flag in ["-e", "--pattern"] do
    {segment, tail} = Enum.split_while(rest, &(&1 not in ["-e", "--pattern"]))
    split_segments(tail, [{pattern, segment} | acc])
  end

  defp split_segments([flag], _acc) when flag in ["-e", "--pattern"] do
    Mix.raise("Missing pattern after #{flag}")
  end

  defp compile_segments(segments) do
    selector_keys = Keyword.keys(SelectorOptions.switches())

    {compiled, global_opts, paths} =
      Enum.reduce(segments, {[], [], []}, fn {pattern, segment_args},
                                             {compiled, global_opts, paths} ->
        validate_pattern!(pattern)

        {opts, positional, _} =
          OptionParser.parse(segment_args,
            strict: @global_switches ++ SelectorOptions.switches()
          )

        filter_opts = Keyword.take(opts, selector_keys)
        seg_globals = Keyword.drop(opts, selector_keys)
        selector = SelectorOptions.scoped_pattern(pattern, filter_opts, &validate_pattern!/1)

        {[%{pattern: pattern, selector: selector} | compiled], global_opts ++ seg_globals,
         paths ++ positional}
      end)

    {Enum.reverse(compiled), global_opts, paths}
  end

  defp build_named_patterns!(compiled) do
    {named, key_to_str, _seen} =
      compiled
      |> Enum.with_index()
      |> Enum.reduce({[], %{}, MapSet.new()}, fn {%{pattern: str, selector: selector}, index},
                                                 {named, key_to_str, seen} ->
        if MapSet.member?(seen, str) do
          Mix.raise(
            "Duplicate pattern #{inspect(str)}; each -e must have a distinct pattern string"
          )
        end

        key = :"pattern_#{index}"
        {[{key, selector} | named], Map.put(key_to_str, key, str), MapSet.put(seen, str)}
      end)

    {Enum.reverse(named), key_to_str}
  end

  defp reject_multi_unsupported!(opts) do
    if opts[:count_by_file] do
      Mix.raise("--count-by-file is not supported with -e")
    end
  end

  defp render_many(results, pattern_strs, key_to_str, opts) do
    results = Enum.map(results, &%{&1 | pattern: Map.fetch!(key_to_str, &1.pattern)})

    Output.with_stdout(fn ->
      cond do
        json?(opts) ->
          JSON.print(%{matches: results, count: length(results)})

        opts[:count] ->
          print_many_count(results, pattern_strs)

        true ->
          Enum.each(results, &print_tagged_match/1)
          Output.puts("\n#{length(pattern_strs)} pattern(s), #{length(results)} match(es)")
      end
    end)
  end

  defp print_many_count(results, pattern_strs) do
    counts = Enum.frequencies_by(results, &to_string(&1.pattern))

    Enum.each(pattern_strs, fn str ->
      Output.puts("#{Map.get(counts, str, 0)}\t#{str}")
    end)

    Output.puts("\n#{length(results)} match(es) across #{length(pattern_strs)} pattern(s)")
  end

  defp print_tagged_match(%{pattern: pattern} = match) do
    Output.puts("[#{pattern}] #{match.file}:#{match.line}")
    match.source |> String.split("\n") |> Enum.each(&Output.puts("  #{&1}"))
    print_captures(match.captures)
    Output.puts("")
  end

  defp do_search(paths, pattern, opts) do
    validate_pattern!(pattern)

    search_pattern =
      SelectorOptions.pattern(pattern, opts, &validate_pattern!/1, [
        :count,
        :count_by_file,
        :limit,
        :allow_broad
      ])

    search_opts =
      opts
      |> SelectorOptions.where_opts([
        :count,
        :count_by_file,
        :limit,
        :allow_broad,
        :format,
        :json
      ])
      |> Keyword.merge(Keyword.take(opts, [:limit, :allow_broad, :expand_imports]))

    results = ExAST.search(paths, search_pattern, search_opts)

    Output.with_stdout(fn ->
      cond do
        json?(opts) ->
          JSON.print(%{matches: results, count: length(results)})

        opts[:count_by_file] ->
          print_count_by_file(results)

        opts[:count] ->
          Output.puts(length(results))

        true ->
          Enum.each(results, &print_match/1)
          Output.puts("\n#{length(results)} match(es)")
      end
    end)
  end

  defp validate_pattern!(pattern) do
    Code.string_to_quoted!(pattern)
  rescue
    e in [SyntaxError, TokenMissingError, MismatchedDelimiterError] ->
      Mix.raise("Invalid pattern: #{Exception.message(e)}")
  end

  defp print_count_by_file(results) do
    counts =
      results
      |> Enum.frequencies_by(& &1.file)
      |> Enum.sort_by(fn {_file, count} -> -count end)

    Enum.each(counts, fn {file, count} -> Output.puts("#{count}\t#{file}") end)
    Output.puts("\n#{length(results)} match(es) in #{length(counts)} file(s)")
  end

  defp json?(opts), do: opts[:json] || opts[:format] == "json"

  defp print_match(%{file: file, line: line, source: source, captures: captures}) do
    Output.puts("#{file}:#{line}")
    source |> String.split("\n") |> Enum.each(&Output.puts("  #{&1}"))
    print_captures(captures)
    Output.puts("")
  end

  defp print_captures(captures) when map_size(captures) == 0, do: :ok

  defp print_captures(captures) do
    for {name, value} <- captures do
      rendered = value |> restore_meta() |> Macro.to_string()
      Output.puts("  #{name}: #{rendered}")
    end
  end

  defp restore_meta(ast) do
    Macro.prewalk(ast, fn
      {form, nil, args} -> {form, [], args}
      other -> other
    end)
  end
end
