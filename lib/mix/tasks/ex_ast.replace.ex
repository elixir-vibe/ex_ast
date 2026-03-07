defmodule Mix.Tasks.ExAst.Replace do
  @shortdoc "Replace Elixir code by AST pattern"
  @moduledoc """
  Replaces AST pattern matches in Elixir source files.

  ## Usage

      mix ex_ast.replace 'pattern' 'replacement' [path ...]

  ## Options

    * `--dry-run` — show changes without writing files

  ## Examples

      mix ex_ast.replace 'IO.inspect(expr, _)' 'expr' lib/
      mix ex_ast.replace 'dbg(expr)' 'expr'
      mix ex_ast.replace --dry-run '%Step{id: "subject"}' 'SharedSteps.subject_step(@opts)'
  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: [dry_run: :boolean])

    case positional do
      [pattern, replacement | paths] ->
        paths = if paths == [], do: ["lib/"], else: paths
        modified = ExAst.replace(paths, pattern, replacement, dry_run: opts[:dry_run] || false)

        unless opts[:dry_run] do
          case modified do
            [] -> IO.puts("No matches found.")
            files -> Enum.each(files, &IO.puts("Updated #{&1}"))
          end
        end

      _ ->
        Mix.raise("Usage: mix ex_ast.replace 'pattern' 'replacement' [path ...]")
    end
  end
end
