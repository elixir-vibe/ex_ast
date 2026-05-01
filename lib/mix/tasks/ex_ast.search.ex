defmodule Mix.Tasks.ExAst.Search do
  @shortdoc "Search Elixir code by AST pattern"
  @moduledoc """
  Searches for AST patterns in Elixir source files.

  ## Usage

      mix ex_ast.search 'IO.inspect(_)' [path ...]

  ## Options

    * `--count` — only print the number of matches
    * `--limit n` — stop after returning this many matches
    * `--allow-broad` — allow unbounded broad searches like `_`
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
  """

  use Mix.Task

  alias ExAST.CLI.Output
  alias ExAST.CLI.SelectorOptions

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict:
          [count: :boolean, limit: :integer, allow_broad: :boolean] ++ SelectorOptions.switches()
      )

    case positional do
      [pattern | paths] ->
        paths = if paths == [], do: ["lib/"], else: paths
        do_search(paths, pattern, opts)

      _ ->
        Mix.raise("Usage: mix ex_ast.search 'pattern' [path ...]")
    end
  end

  defp do_search(paths, pattern, opts) do
    validate_pattern!(pattern)

    search_pattern =
      SelectorOptions.pattern(pattern, opts, &validate_pattern!/1, [
        :count,
        :limit,
        :allow_broad
      ])

    search_opts =
      opts
      |> SelectorOptions.where_opts([:count, :limit, :allow_broad])
      |> Keyword.merge(Keyword.take(opts, [:limit, :allow_broad]))

    results = ExAST.search(paths, search_pattern, search_opts)

    Output.with_stdout(fn ->
      if opts[:count] do
        Output.puts(length(results))
      else
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
