defmodule Mix.Tasks.ExAst.Replace do
  @shortdoc "Replace Elixir code by AST pattern"
  @moduledoc """
  Replaces AST pattern matches in Elixir source files.

  ## Usage

      mix ex_ast.replace 'pattern' 'replacement' [path ...]

  ## Options

    * `--dry-run` — show changes without writing files
    * `--inside 'pattern'` — only replace inside ancestors matching this pattern
    * `--not-inside 'pattern'` — skip replacements inside ancestors matching this pattern
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

  ## Examples

      mix ex_ast.replace 'IO.inspect(expr, _)' 'expr' lib/
      mix ex_ast.replace 'dbg(expr)' 'expr'
      mix ex_ast.replace --dry-run '%Step{id: "subject"}' 'SharedSteps.subject_step(@opts)'
      mix ex_ast.replace --not-inside 'test _ do _ end' 'IO.inspect(expr)' 'expr'
      mix ex_ast.replace 'IO.inspect(expr)' 'Logger.debug(inspect(expr))' lib/ --parent 'def _ do ... end'
      mix ex_ast.replace 'Repo.get!(schema, id)' 'Repo.fetch!(schema, id)' lib/ --contains 'Repo.transaction(_)' --not-contains 'IO.inspect(...)'
      mix ex_ast.replace 'Logger.debug(record)' 'Logger.info(record)' lib/ --immediately-precedes 'Repo.delete(record)'
  """

  use Mix.Task

  alias ExAST.CLI.SelectorOptions

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args, strict: [dry_run: :boolean] ++ SelectorOptions.switches())

    case positional do
      [pattern, replacement | paths] ->
        paths = if paths == [], do: ["lib/"], else: paths
        do_replace(paths, pattern, replacement, opts)

      _ ->
        Mix.raise("Usage: mix ex_ast.replace 'pattern' 'replacement' [path ...]")
    end
  end

  defp do_replace(paths, pattern, replacement, opts) do
    validate_syntax!(pattern, "pattern")
    validate_syntax!(replacement, "replacement")

    replace_pattern =
      SelectorOptions.pattern(pattern, opts, &validate_filter_pattern!/1, [:dry_run])

    replace_opts = [
      {:dry_run, opts[:dry_run] || false} | SelectorOptions.where_opts(opts, [:dry_run])
    ]

    results = ExAST.replace(paths, replace_pattern, replacement, replace_opts)

    case results do
      [] ->
        IO.puts("No matches found.")

      files ->
        total = files |> Enum.map(&elem(&1, 1)) |> Enum.sum()
        verb = if opts[:dry_run], do: "Would update", else: "Updated"

        for {file, count} <- files do
          IO.puts("#{verb} #{file} (#{count} replacement(s))")
        end

        IO.puts("\n#{total} replacement(s) in #{length(files)} file(s)")
    end
  end

  defp validate_filter_pattern!(code), do: validate_syntax!(code, "filter pattern")

  defp validate_syntax!(code, label) do
    Code.string_to_quoted!(code)
  rescue
    e in [SyntaxError, TokenMissingError, MismatchedDelimiterError] ->
      Mix.raise("Invalid #{label}: #{Exception.message(e)}")
  end
end
