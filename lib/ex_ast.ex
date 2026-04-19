defmodule ExAST do
  @moduledoc """
  Search and replace Elixir code by AST pattern.

  Patterns are valid Elixir syntax:
  - Variables (`name`, `expr`) capture matched nodes
  - `_` and `_name` are wildcards
  - Structs/maps match partially
  - Pipes are normalized (`data |> Enum.map(f)` matches `Enum.map(data, f)`)
  - Everything else matches literally

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
  """

  alias ExAST.Patcher

  @type match :: %{
          file: String.t(),
          line: pos_integer(),
          source: String.t(),
          captures: ExAST.Pattern.captures()
        }

  @doc """
  Searches files for AST pattern matches.

  Returns a list of match maps with `:file`, `:line`, `:source`, and `:captures`.
  Accepts `:inside` and `:not_inside` options to filter by context.
  """
  @spec search(String.t() | [String.t()], String.t(), keyword()) :: [match()]
  def search(paths, pattern, opts \\ []) do
    paths
    |> resolve_paths()
    |> Enum.flat_map(&search_file(&1, pattern, opts))
  end

  @doc """
  Replaces AST pattern matches in files.

  Options:
  - `:dry_run` — return changes without writing (default: `false`)
  - `:inside` — only replace inside ancestors matching this pattern
  - `:not_inside` — skip replacements inside ancestors matching this pattern

  Returns a list of `{file, count}` tuples for modified files.
  """
  @spec replace(String.t() | [String.t()], String.t(), String.t(), keyword()) :: [
          {String.t(), pos_integer()}
        ]
  def replace(paths, pattern, replacement, opts \\ []) do
    {dry_run, where_opts} = Keyword.pop(opts, :dry_run, false)

    paths
    |> resolve_paths()
    |> Enum.flat_map(&replace_file(&1, pattern, replacement, dry_run, where_opts))
  end

  defp search_file(file, pattern, opts) do
    source = File.read!(file)

    Patcher.find_all(source, pattern, opts)
    |> Enum.map(fn %{range: range, node: node, captures: captures} ->
      %{
        file: file,
        line: range.start[:line],
        source: Sourceror.to_string(node),
        captures: captures
      }
    end)
  end

  defp replace_file(file, pattern, replacement, dry_run, where_opts) do
    source = File.read!(file)
    matches = Patcher.find_all(source, pattern, where_opts)

    if matches == [] do
      []
    else
      result = Patcher.replace_all(source, pattern, replacement, where_opts)
      unless dry_run, do: File.write!(file, result)
      [{file, length(matches)}]
    end
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
