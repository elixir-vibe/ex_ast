defmodule Mix.Tasks.ExAst.Search do
  @shortdoc "Search Elixir code by AST pattern"
  @moduledoc """
  Searches for AST patterns in Elixir source files.

  ## Usage

      mix ex_ast.search 'IO.inspect(_)' [path ...]

  ## Options

    * `--count` — only print the number of matches
    * `--inside 'pattern'` — only match inside ancestors matching this pattern
    * `--not-inside 'pattern'` — reject matches inside ancestors matching this pattern

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
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: [count: :boolean, inside: :string, not_inside: :string])

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

    where_opts = Keyword.take(opts, [:inside, :not_inside])
    Enum.each(where_opts, fn {_key, p} -> validate_pattern!(p) end)
    results = ExAST.search(paths, pattern, where_opts)

    if opts[:count] do
      IO.puts(length(results))
    else
      Enum.each(results, &print_match/1)
      IO.puts("\n#{length(results)} match(es)")
    end
  end

  defp validate_pattern!(pattern) do
    Code.string_to_quoted!(pattern)
  rescue
    e in [SyntaxError, TokenMissingError, MismatchedDelimiterError] ->
      Mix.raise("Invalid pattern: #{Exception.message(e)}")
  end

  defp print_match(%{file: file, line: line, source: source, captures: captures}) do
    IO.puts("#{file}:#{line}")
    source |> String.split("\n") |> Enum.each(&IO.puts("  #{&1}"))
    print_captures(captures)
    IO.puts("")
  end

  defp print_captures(captures) when map_size(captures) == 0, do: :ok

  defp print_captures(captures) do
    for {name, value} <- captures do
      rendered = value |> restore_meta() |> Macro.to_string()
      IO.puts("  #{name}: #{rendered}")
    end
  end

  defp restore_meta(ast) do
    Macro.prewalk(ast, fn
      {form, nil, args} -> {form, [], args}
      other -> other
    end)
  end
end
