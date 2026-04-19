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

  ## Examples

      mix ex_ast.replace 'IO.inspect(expr, _)' 'expr' lib/
      mix ex_ast.replace 'dbg(expr)' 'expr'
      mix ex_ast.replace --dry-run '%Step{id: "subject"}' 'SharedSteps.subject_step(@opts)'
      mix ex_ast.replace --not-inside 'test _ do _ end' 'IO.inspect(expr)' 'expr'
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [dry_run: :boolean, inside: :string, not_inside: :string]
      )

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

    where_opts = Keyword.take(opts, [:inside, :not_inside])
    Enum.each(where_opts, fn {_key, p} -> validate_syntax!(p, "filter pattern") end)

    replace_opts = [{:dry_run, opts[:dry_run] || false} | where_opts]
    results = ExAST.replace(paths, pattern, replacement, replace_opts)

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

  defp validate_syntax!(code, label) do
    Code.string_to_quoted!(code)
  rescue
    e in [SyntaxError, TokenMissingError, MismatchedDelimiterError] ->
      Mix.raise("Invalid #{label}: #{Exception.message(e)}")
  end
end
