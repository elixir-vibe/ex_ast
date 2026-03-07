defmodule ExAst do
  @moduledoc """
  Search and replace Elixir code by AST pattern.

  Patterns are valid Elixir syntax:
  - Variables (`name`, `expr`) capture matched nodes
  - `_` and `_name` are wildcards
  - Structs/maps match partially
  - Everything else matches literally

  ## Examples

      # Find all IO.inspect calls
      ExAst.search("lib/**/*.ex", "IO.inspect(_)")

      # Replace dbg with the expression itself
      ExAst.replace("lib/**/*.ex", "dbg(expr)", "expr")
  """

  alias ExAst.Patcher

  @doc """
  Searches files for AST pattern matches.

  Returns a list of `{file, line, matched_source}` tuples.
  """
  @spec search(String.t() | [String.t()], String.t()) :: [
          {String.t(), pos_integer(), String.t()}
        ]
  def search(paths, pattern) do
    paths
    |> resolve_paths()
    |> Enum.flat_map(fn file ->
      source = File.read!(file)

      Patcher.find_all(source, pattern)
      |> Enum.map(fn %{range: range, node: node} ->
        {file, range.start[:line], node |> Sourceror.to_string() |> first_line()}
      end)
    end)
  end

  @doc """
  Replaces AST pattern matches in files.

  Options:
  - `:dry_run` — print changes without writing (default: `false`)

  Returns a list of modified file paths.
  """
  @spec replace(String.t() | [String.t()], String.t(), String.t(), keyword()) :: [String.t()]
  def replace(paths, pattern, replacement, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)

    paths
    |> resolve_paths()
    |> Enum.filter(fn file ->
      source = File.read!(file)
      result = Patcher.replace_all(source, pattern, replacement)

      if result != source do
        if dry_run do
          IO.puts("--- #{file}")
          IO.puts(result)
        else
          File.write!(file, result)
        end

        true
      else
        false
      end
    end)
  end

  defp resolve_paths(paths) when is_list(paths), do: Enum.flat_map(paths, &resolve_paths/1)

  defp resolve_paths(glob) when is_binary(glob) do
    if String.contains?(glob, "*") do
      Path.wildcard(glob)
    else
      if File.dir?(glob) do
        Path.wildcard(Path.join(glob, "**/*.ex"))
      else
        [glob]
      end
    end
    |> Enum.filter(&String.ends_with?(&1, ".ex"))
  end

  defp first_line(string) do
    string |> String.split("\n") |> hd()
  end
end
