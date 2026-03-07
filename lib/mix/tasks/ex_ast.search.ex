defmodule Mix.Tasks.ExAst.Search do
  @shortdoc "Search Elixir code by AST pattern"
  @moduledoc """
  Searches for AST patterns in Elixir source files.

  ## Usage

      mix ex_ast.search 'IO.inspect(_)' [path ...]

  ## Options

    * `--count` — only print the number of matches

  ## Pattern syntax

  Patterns are valid Elixir expressions:

    * Variables (`name`, `expr`) — capture any node
    * `_` or `_name` — wildcard (match, don't capture)
    * Structs/maps — partial match (only listed keys must be present)
    * Everything else — literal match

  ## Examples

      mix ex_ast.search 'IO.inspect(_)'
      mix ex_ast.search '%Step{id: "subject"}' lib/documents/
      mix ex_ast.search '{:error, reason}' lib/ test/
      mix ex_ast.search --count 'dbg(_)'
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: [count: :boolean])

    case positional do
      [pattern | paths] ->
        paths = if paths == [], do: ["lib/"], else: paths
        results = ExAst.search(paths, pattern)

        if opts[:count] do
          IO.puts(length(results))
        else
          for {file, line, source} <- results do
            IO.puts("#{file}:#{line}:  #{source}")
          end

          if results == [] do
            IO.puts("No matches found.")
          end
        end

      _ ->
        Mix.raise("Usage: mix ex_ast.search 'pattern' [path ...]")
    end
  end
end
