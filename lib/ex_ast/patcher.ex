defmodule ExAST.Patcher do
  @moduledoc """
  Finds and replaces AST patterns in source code.

  Uses Sourceror for parsing, traversal, and source-level patching
  to preserve formatting of unchanged code.
  """

  alias ExAST.Pattern

  @type match :: %{
          node: Macro.t(),
          range: Sourceror.Range.t(),
          captures: Pattern.captures()
        }

  @doc """
  Finds all occurrences of `pattern` in `source`.

  ## Options

    * `:inside` — only match nodes nested within an ancestor matching this pattern
    * `:not_inside` — reject nodes nested within an ancestor matching this pattern

  Returns a list of matches with the matched node, its source range,
  and any captured values.
  """
  @spec find_all(String.t(), String.t(), keyword()) :: [match()]
  def find_all(source, pattern, opts \\ []) do
    ast = Sourceror.parse_string!(source)

    matches =
      if Pattern.multi_node?(pattern) do
        collect_sequence_matches(ast, pattern)
      else
        zipper = Sourceror.Zipper.zip(ast)
        collect_matches(zipper, pattern, [])
      end

    apply_where(matches, opts)
  end

  @doc """
  Replaces all occurrences of `pattern` with `replacement` in `source`.

  Captures from the pattern are substituted into the replacement template.
  Accepts the same `:inside` / `:not_inside` options as `find_all/3`.
  Returns the modified source string.
  """
  @spec replace_all(String.t(), String.t(), String.t(), keyword()) :: String.t()
  def replace_all(source, pattern, replacement, opts \\ []) do
    replacement_ast = Code.string_to_quoted!(replacement)
    matches = find_all(source, pattern, opts)

    patches =
      Enum.map(matches, fn %{range: range, captures: captures} ->
        substituted = Pattern.substitute(replacement_ast, captures)
        %{range: range, change: substituted |> restore_meta() |> Macro.to_string()}
      end)

    Sourceror.patch_string(source, patches)
  end

  defp restore_meta(ast) do
    Macro.prewalk(ast, fn
      {form, nil, args} -> {form, [], args}
      other -> other
    end)
  end

  # --- Single-node matching ---

  defp collect_matches(nil, _pattern, acc), do: Enum.reverse(acc)

  defp collect_matches(zipper, pattern, acc) do
    node = Sourceror.Zipper.node(zipper)

    case Pattern.match(node, pattern) do
      {:ok, captures} ->
        range = Sourceror.get_range(node)
        ancestors = collect_ancestors(zipper)

        match = %{node: node, range: range, captures: captures, ancestors: ancestors}
        zipper |> Sourceror.Zipper.skip() |> collect_matches(pattern, [match | acc])

      :error ->
        zipper |> Sourceror.Zipper.next() |> collect_matches(pattern, acc)
    end
  end

  # --- Multi-node (sequence) matching ---

  defp collect_sequence_matches(ast, pattern) do
    pattern_asts = Pattern.pattern_nodes(pattern)

    {_, matches} =
      Macro.prewalk(ast, [], fn node, acc ->
        case extract_block_children(node) do
          nil -> {node, acc}
          children -> {node, find_in_block(children, pattern_asts, ast) ++ acc}
        end
      end)

    matches
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.range)
  end

  defp extract_block_children({:__block__, _meta, children})
       when is_list(children) and length(children) > 1 do
    children
  end

  defp extract_block_children({_form, _meta, args}) when is_list(args) do
    Enum.find_value(args, fn
      [{_, {:__block__, _, children}}] when is_list(children) and length(children) > 1 ->
        children

      _ ->
        nil
    end)
  end

  defp extract_block_children(_), do: nil

  defp find_in_block(children, pattern_asts, root_ast) do
    Pattern.match_sequences(children, pattern_asts)
    |> Enum.map(fn {captures, range} ->
      matched_nodes = Enum.slice(children, range)
      first = List.first(matched_nodes)
      last = List.last(matched_nodes)

      combined_range = %Sourceror.Range{
        start: Sourceror.get_range(first).start,
        end: Sourceror.get_range(last).end
      }

      ancestors = collect_ancestors_for_node(first, root_ast)

      %{
        node: {:__block__, [], matched_nodes},
        range: combined_range,
        captures: captures,
        ancestors: ancestors
      }
    end)
  end

  defp collect_ancestors_for_node(target_node, root_ast) do
    zipper = Sourceror.Zipper.zip(root_ast)
    find_node_ancestors(zipper, target_node)
  end

  defp find_node_ancestors(nil, _target), do: []

  defp find_node_ancestors(zipper, target) do
    node = Sourceror.Zipper.node(zipper)

    if node == target do
      collect_ancestors(zipper)
    else
      find_node_ancestors(Sourceror.Zipper.next(zipper), target)
    end
  end

  # --- Shared helpers ---

  defp collect_ancestors(zipper) do
    case Sourceror.Zipper.up(zipper) do
      nil -> []
      parent -> [Sourceror.Zipper.node(parent) | collect_ancestors(parent)]
    end
  end

  defp apply_where(matches, opts) do
    inside = Keyword.get(opts, :inside)
    not_inside = Keyword.get(opts, :not_inside)

    matches
    |> maybe_filter_inside(inside)
    |> maybe_filter_not_inside(not_inside)
    |> Enum.map(&Map.delete(&1, :ancestors))
  end

  defp maybe_filter_inside(matches, nil), do: matches

  defp maybe_filter_inside(matches, pattern) do
    Enum.filter(matches, fn %{ancestors: ancestors} ->
      Enum.any?(ancestors, &(Pattern.match(&1, pattern) != :error))
    end)
  end

  defp maybe_filter_not_inside(matches, nil), do: matches

  defp maybe_filter_not_inside(matches, pattern) do
    Enum.reject(matches, fn %{ancestors: ancestors} ->
      Enum.any?(ancestors, &(Pattern.match(&1, pattern) != :error))
    end)
  end
end
