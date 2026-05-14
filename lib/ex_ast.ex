defmodule ExAST do
  @moduledoc """
  Search, replace, and diff Elixir code by AST pattern.

  Patterns are valid Elixir syntax:
  - Variables (`name`, `expr`) capture matched nodes
  - `_` and `_name` are wildcards
  - Structs/maps match partially
  - Pipes are normalized (`data |> Enum.map(f)` matches `Enum.map(data, f)`)
  - Everything else matches literally
  - CSS-like selectors can be built with `ExAST.Selector`

  ## Options

    * `:inside` — only match nodes inside an ancestor matching this pattern
    * `:not_inside` — reject nodes inside an ancestor matching this pattern

  ## Examples

      # Find all IO.inspect calls
      ExAST.search("lib/**/*.ex", "IO.inspect(_)")

      # Find IO.inspect only inside test blocks
      ExAST.search("test/", "IO.inspect(_)", inside: "test _ do _ end")

      # Replace dbg with the expression itself
      ExAST.replace("lib/**/*.ex", "dbg(expr)", "expr")

      # Match piped and direct calls interchangeably
      ExAST.search("lib/", "Enum.map(_, _)")  # also finds `data |> Enum.map(f)`

      # Relationship-aware queries
      import ExAST.Query

      query =
        from("def _ do ... end")
        |> where(contains("Repo.transaction(_)"))
        |> where(not contains("IO.inspect(...)"))

      ExAST.search("lib/", query)

      # Capture guards — filter on captured values with ^pin
      import ExAST.Query

      query =
        from("Enum.take(_, count)")
        |> where(match?({:-, _, [_]}, ^count))

      ExAST.search("lib/", query)

      # Syntax-aware diff
      result = ExAST.diff(old_source, new_source)
      result.edits  #=> [%ExAST.Diff.Edit{op: :update, kind: :function, ...}]
      ExAST.diff_files("lib/old.ex", "lib/new.ex")
  """

  alias ExAST.Diff
  alias ExAST.Patcher
  alias ExAST.Rewriter

  @type match :: %{
          file: String.t(),
          line: pos_integer(),
          range: Sourceror.Range.t() | nil,
          source: String.t(),
          captures: ExAST.Pattern.captures()
        }

  @type pattern_name :: ExAST.Patcher.pattern_name()
  @type named_pattern :: ExAST.Patcher.named_pattern()
  @type tagged_match :: %{required(:pattern) => pattern_name(), optional(atom()) => term()}

  @type diff_result :: ExAST.Diff.Result.t()

  @doc """
  Searches files for AST pattern matches.

  Returns a list of match maps with `:file`, `:line`, `:source`, and `:captures`.
  Accepts `:inside` and `:not_inside` options to filter by context.

  Options:
    * `:limit` — stop after returning this many matches
    * `:allow_broad` — allow unbounded broad searches like `from("_")`
    * `:concurrency` — file-level search concurrency for unbounded searches
  """
  @spec search(String.t() | [String.t()], String.t() | ExAST.Selector.t(), keyword()) :: [match()]
  def search(paths, pattern, opts \\ []) do
    files = resolve_paths(paths)
    validate_broad_search!(pattern, opts)
    search_opts = Keyword.drop(opts, [:allow_broad, :limit])

    case Keyword.get(opts, :limit) do
      nil ->
        parallel_flat_map(files, opts, &search_file(&1, pattern, search_opts))

      limit when is_integer(limit) and limit >= 0 ->
        search_files_limited(files, pattern, search_opts, limit)
    end
  end

  @doc """
  Searches files for multiple named AST patterns.

  `patterns` may be a keyword list or a map. Returned matches include a
  `:pattern` field with the matching pattern name. This is more efficient than
  calling `search/3` repeatedly for analyzers that run many checks over the same
  files.

  Options are the same as `search/3`.
  """
  @spec search_many(String.t() | [String.t()], [named_pattern()] | map(), keyword()) ::
          [tagged_match()]
  def search_many(paths, patterns, opts \\ []) do
    files = resolve_paths(paths)
    pattern_entries = Patcher.named_patterns!(patterns)
    Enum.each(pattern_entries, fn {_name, pattern} -> validate_broad_search!(pattern, opts) end)
    search_opts = Keyword.drop(opts, [:allow_broad, :limit])

    case Keyword.get(opts, :limit) do
      nil ->
        parallel_flat_map(files, opts, &search_file_many(&1, pattern_entries, search_opts))

      limit when is_integer(limit) and limit >= 0 ->
        search_files_many_limited(files, pattern_entries, search_opts, limit)
    end
  end

  @doc """
  Replaces AST pattern matches in files.

  Options:
  - `:dry_run` — return changes without writing (default: `false`)
  - `:inside` — only replace inside ancestors matching this pattern
  - `:not_inside` — skip replacements inside ancestors matching this pattern
  - `:format` — format modified files with `Code.format_string!/1`

  Returns a list of `{file, count}` tuples for modified files.
  """
  @spec replace(String.t() | [String.t()], String.t() | ExAST.Selector.t(), String.t(), keyword()) ::
          [
            {String.t(), pos_integer()}
          ]
  def replace(paths, pattern, replacement, opts \\ []) do
    {dry_run, opts} = Keyword.pop(opts, :dry_run, false)
    {format?, where_opts} = Keyword.pop(opts, :format, false)

    paths
    |> resolve_paths()
    |> Enum.flat_map(&replace_file(&1, pattern, replacement, dry_run, format?, where_opts))
  end

  @doc """
  Computes a syntax-aware diff between two Elixir source strings.
  """
  @spec diff(String.t(), String.t(), keyword()) :: diff_result()
  def diff(left_source, right_source, opts \\ []) do
    Diff.diff(left_source, right_source, opts)
  end

  @doc """
  Computes a syntax-aware diff between two Elixir files.
  """
  @spec diff_files(String.t(), String.t(), keyword()) :: diff_result()
  def diff_files(left_path, right_path, opts \\ []) do
    Diff.diff_files(left_path, right_path, opts)
  end

  @doc """
  Applies a diff result to produce the patched source.
  """
  @spec apply_diff(diff_result()) :: String.t()
  def apply_diff(result) do
    Diff.apply(result)
  end

  defp search_files_limited(_files, _pattern, _opts, 0), do: []

  defp search_files_limited(files, pattern, opts, limit) do
    files
    |> Enum.reduce_while({[], 0}, fn file, {acc, count} ->
      remaining = limit - count
      matches = search_file(file, pattern, opts, remaining)
      next_count = count + length(matches)
      next_acc = prepend_reversed(matches, acc)

      if next_count >= limit do
        {:halt, {next_acc, next_count}}
      else
        {:cont, {next_acc, next_count}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp search_files_many_limited(_files, _patterns, _opts, 0), do: []

  defp search_files_many_limited(files, patterns, opts, limit) do
    files
    |> Enum.reduce_while({[], 0}, fn file, {acc, count} ->
      remaining = limit - count
      matches = search_file_many(file, patterns, opts, remaining)
      next_count = count + length(matches)
      next_acc = prepend_reversed(matches, acc)

      if next_count >= limit do
        {:halt, {next_acc, next_count}}
      else
        {:cont, {next_acc, next_count}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp prepend_reversed(items, acc), do: Enum.reduce(items, acc, &[&1 | &2])

  defp search_file(file, pattern, opts, limit \\ nil) do
    source = File.read!(file)

    if ExAST.Prefilter.may_match?(source, pattern) do
      lines = String.split(source, "\n", trim: false)

      source
      |> Patcher.find_all(pattern, opts)
      |> maybe_take(limit)
      |> Enum.map(fn %{range: range, node: node, captures: captures} ->
        search_match(file, lines, range, node, captures)
      end)
    else
      []
    end
  end

  defp search_file_many(file, patterns, opts, limit \\ nil) do
    source = File.read!(file)

    if Enum.any?(patterns, fn {_name, pattern} -> ExAST.Prefilter.may_match?(source, pattern) end) do
      lines = String.split(source, "\n", trim: false)

      source
      |> Patcher.find_many(patterns, opts)
      |> maybe_take(limit)
      |> Enum.map(fn %{pattern: pattern, range: range, node: node, captures: captures} ->
        file
        |> search_match(lines, range, node, captures)
        |> Map.put(:pattern, pattern)
      end)
    else
      []
    end
  end

  defp search_match(file, lines, range, node, captures) do
    %{
      file: file,
      line: match_line(range),
      range: range,
      source: source_fragment(lines, range) || node_to_string(node),
      captures: captures
    }
  end

  defp maybe_take(matches, nil), do: matches
  defp maybe_take(matches, limit), do: Enum.take(matches, limit)

  defp validate_broad_search!(pattern, opts) do
    if broad_pattern?(pattern) and is_nil(opts[:limit]) and opts[:allow_broad] != true do
      raise ArgumentError, """
      refusing broad query without a limit

      from("_") matches every AST node and can be very expensive across files.
      Use a narrower pattern, pass limit: 100, or pass allow_broad: true.
      """
    end
  end

  defp broad_pattern?("_"), do: true
  defp broad_pattern?({:_, _meta, nil}), do: true

  defp broad_pattern?(%ExAST.Selector{steps: [{:self, pattern} | _]}),
    do: broad_pattern?(pattern)

  defp broad_pattern?({:__ex_ast_any_patterns__, patterns}),
    do: Enum.any?(patterns, &broad_pattern?/1)

  defp broad_pattern?(patterns) when is_list(patterns), do: Enum.any?(patterns, &broad_pattern?/1)
  defp broad_pattern?(_pattern), do: false

  @doc """
  Builds a rewrite plan for source without applying it.
  """
  @spec rewrite_plan(String.t(), String.t() | ExAST.Selector.t(), String.t(), keyword()) ::
          ExAST.Rewriter.Plan.t()
  def rewrite_plan(source, pattern, replacement, opts \\ []) do
    Rewriter.plan(source, pattern, replacement, opts)
  end

  defp replace_file(file, pattern, replacement, dry_run, format?, where_opts) do
    source = File.read!(file)

    if ExAST.Prefilter.may_match?(source, pattern) do
      source
      |> Rewriter.plan(pattern, replacement, where_opts)
      |> apply_rewrite_plan(file, source, dry_run, format?)
    else
      []
    end
  end

  defp apply_rewrite_plan(%Rewriter.Plan{replacements: []}, _file, _source, _dry_run, _format?),
    do: []

  defp apply_rewrite_plan(
         %Rewriter.Plan{replacements: replacements} = plan,
         file,
         source,
         dry_run,
         format?
       ) do
    result = source |> Rewriter.apply(plan, on_conflict: :raise) |> maybe_format(format?)
    unless dry_run, do: File.write!(file, result)
    [{file, length(replacements)}]
  end

  defp maybe_format(source, false), do: source

  defp maybe_format(source, true) do
    source |> Code.format_string!() |> IO.iodata_to_binary()
  rescue
    _ -> source
  end

  defp match_line(%{start: start}) when is_list(start), do: start[:line] || 1
  defp match_line(_range), do: 1

  defp source_fragment(lines, %{start: start, end: end_}) when is_list(start) and is_list(end_) do
    with start_line when is_integer(start_line) <- start[:line],
         start_column when is_integer(start_column) <- start[:column],
         end_line when is_integer(end_line) <- end_[:line],
         end_column when is_integer(end_column) <- end_[:column] do
      fragment_lines(lines, start_line, start_column, end_line, end_column)
    else
      _ -> nil
    end
  end

  defp source_fragment(_source, _range), do: nil

  defp fragment_lines(lines, line, start_column, line, end_column) do
    lines
    |> Enum.at(line - 1, "")
    |> String.slice((start_column - 1)..(end_column - 2)//1)
  end

  defp fragment_lines(lines, start_line, start_column, end_line, end_column) do
    lines
    |> Enum.slice((start_line - 1)..(end_line - 1)//1)
    |> trim_fragment_lines(start_column, end_column)
    |> Enum.join("\n")
  end

  defp trim_fragment_lines([], _start_column, _end_column), do: nil

  defp trim_fragment_lines([first | rest], start_column, end_column) do
    {middle, [last]} = Enum.split(rest, max(length(rest) - 1, 0))

    [String.slice(first, (start_column - 1)..-1//1)] ++
      middle ++ [String.slice(last, 0..(end_column - 2)//1)]
  end

  defp node_to_string(node) do
    Sourceror.to_string(node, locals_without_parens: [])
  rescue
    _ -> macro_or_inspect(node)
  end

  defp macro_or_inspect(node) do
    Macro.to_string(node)
  rescue
    _ -> inspect(node)
  end

  defp parallel_flat_map(files, opts, fun) do
    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())

    files
    |> Task.async_stream(fun, ordered: true, max_concurrency: concurrency)
    |> Enum.flat_map(fn {:ok, matches} -> matches end)
  end

  defp resolve_paths(paths) when is_list(paths), do: Enum.flat_map(paths, &resolve_paths/1)

  defp resolve_paths(glob) when is_binary(glob) do
    cond do
      String.contains?(glob, "*") -> Path.wildcard(glob)
      File.dir?(glob) -> Path.wildcard(Path.join(glob, "**/*.ex"))
      true -> [glob]
    end
    |> Enum.filter(&String.ends_with?(&1, ".ex"))
  end
end
