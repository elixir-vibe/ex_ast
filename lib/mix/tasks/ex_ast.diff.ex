defmodule Mix.Tasks.ExAst.Diff do
  @shortdoc "Diff two Elixir files by AST"
  @moduledoc """
  Computes a syntax-aware diff between two Elixir files.

  ## Usage

      mix ex_ast.diff path/to/old.ex path/to/new.ex

  ## Options

    * `--json` — print edits as Elixir terms
    * `--no-moves` — disable move detection
    * `--no-color` — disable colored output
    * `--summary` — print only summary lines

  ## Examples

      mix ex_ast.diff lib/a.ex lib/b.ex
      mix ex_ast.diff --summary lib/a.ex lib/b.ex
      mix ex_ast.diff --no-moves lib/a.ex lib/b.ex
      mix ex_ast.diff --no-color lib/a.ex lib/b.ex
  """

  use Mix.Task

  alias ExAST.CLI.Output

  @switches [json: :boolean, no_moves: :boolean, no_color: :boolean, summary: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: @switches)

    case positional do
      [left_path, right_path] ->
        do_diff(left_path, right_path, opts)

      _ ->
        Mix.raise("Usage: mix ex_ast.diff [options] old.ex new.ex")
    end
  end

  defp do_diff(left_path, right_path, opts) do
    color? = !opts[:no_color] and IO.ANSI.enabled?()
    result = ExAST.diff_files(left_path, right_path, include_moves: !opts[:no_moves])

    Output.with_stdout(fn ->
      cond do
        opts[:json] -> print_json(result.edits)
        opts[:summary] -> print_summary(result.summary)
        true -> print_diff(left_path, right_path, result, color?)
      end
    end)
  end

  defp print_json(edits), do: Output.inspect(edits, pretty: true, limit: :infinity)

  defp print_summary([]), do: Output.puts("No syntax-aware changes detected.")
  defp print_summary(lines), do: Enum.each(lines, &Output.puts/1)

  defp print_diff(left_path, right_path, %{edits: []}, color?) do
    Output.puts(bold("#{left_path} ↔ #{right_path}", color?))
    Output.puts(faint("No syntax-aware changes detected.", color?))
  end

  defp print_diff(left_path, right_path, %{edits: edits}, color?) do
    Output.puts(bold("#{left_path} ↔ #{right_path}", color?))
    Output.puts("")
    Enum.each(edits, &print_edit(&1, color?))
    Output.puts(faint("#{length(edits)} edit(s)", color?))
  end

  defp print_edit(edit, color?) do
    location = format_location(edit.old_range || edit.new_range)
    Output.puts("#{faint(location, color?)} #{op_tag(edit.op, color?)} #{edit.summary}")
    print_body(edit, color?)
    Output.puts("")
  end

  defp print_body(%{op: :update, meta: %{old: old, new: new}}, color?) do
    inline_diff(String.split(old, "\n"), String.split(new, "\n"), color?)
  end

  defp print_body(%{op: :delete, meta: %{old: old}}, color?) do
    old |> String.split("\n") |> Enum.each(&Output.puts(red("  - #{&1}", color?)))
  end

  defp print_body(%{op: :insert, meta: %{new: new}}, color?) do
    new |> String.split("\n") |> Enum.each(&Output.puts(green("  + #{&1}", color?)))
  end

  defp print_body(_, _), do: :ok

  defp inline_diff(old_lines, new_lines, color?) do
    Enum.each(List.myers_difference(old_lines, new_lines), fn
      {:eq, lines} -> Enum.each(lines, &Output.puts(faint("    #{&1}", color?)))
      {:del, lines} -> Enum.each(lines, &Output.puts(red("  - #{&1}", color?)))
      {:ins, lines} -> Enum.each(lines, &Output.puts(green("  + #{&1}", color?)))
    end)
  end

  defp op_tag(:insert, c), do: green("INSERT", c)
  defp op_tag(:delete, c), do: red("DELETE", c)
  defp op_tag(:update, c), do: yellow("UPDATE", c)
  defp op_tag(:move, c), do: cyan("MOVE", c)

  defp red(t, true), do: IO.ANSI.red() <> t <> IO.ANSI.reset()
  defp red(t, _), do: t
  defp green(t, true), do: IO.ANSI.green() <> t <> IO.ANSI.reset()
  defp green(t, _), do: t
  defp yellow(t, true), do: IO.ANSI.yellow() <> t <> IO.ANSI.reset()
  defp yellow(t, _), do: t
  defp cyan(t, true), do: IO.ANSI.cyan() <> t <> IO.ANSI.reset()
  defp cyan(t, _), do: t
  defp bold(t, true), do: IO.ANSI.bright() <> t <> IO.ANSI.reset()
  defp bold(t, _), do: t
  defp faint(t, true), do: IO.ANSI.faint() <> t <> IO.ANSI.reset()
  defp faint(t, _), do: t

  defp format_location(nil), do: "-"
  defp format_location(%{start: s}), do: "L#{s[:line]}"
end
