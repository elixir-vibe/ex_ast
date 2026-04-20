defmodule ExAST.Patcher do
  @moduledoc """
  Finds and replaces AST patterns in source code.

  Accepts source strings, AST nodes, or Sourceror zippers as input.
  Source-string functions preserve formatting via `Sourceror.patch_string/2`.
  AST/zipper functions return modified AST trees.
  """

  alias ExAST.Pattern
  alias Sourceror.Zipper

  @type match :: %{
          node: Macro.t(),
          range: Sourceror.Range.t() | nil,
          captures: Pattern.captures()
        }

  @doc """
  Finds all occurrences of `pattern`.

  The first argument can be a source string, a `Sourceror.Zipper`, or a raw AST.

  ## Options

    * `:inside` — only match nodes nested within an ancestor matching this pattern
    * `:not_inside` — reject nodes nested within an ancestor matching this pattern

  Returns a list of matches with the matched node, its source range,
  and any captured values.
  """
  @spec find_all(String.t() | Zipper.t() | Macro.t(), String.t(), keyword()) :: [match()]
  def find_all(input, pattern, opts \\ [])

  def find_all(source, pattern, opts) when is_binary(source) do
    source |> Sourceror.parse_string!() |> do_find_all(pattern, opts)
  end

  def find_all(%Zipper{} = zipper, pattern, opts) do
    zipper |> Zipper.topmost_root() |> do_find_all(pattern, opts)
  end

  def find_all(ast, pattern, opts) do
    do_find_all(ast, pattern, opts)
  end

  @doc """
  Replaces all occurrences of `pattern` with `replacement`.

  When given a source string, returns a modified source string with
  formatting preserved. When given a zipper or AST, returns modified AST.

  Captures from the pattern are substituted into the replacement template.
  Accepts the same `:inside` / `:not_inside` options as `find_all/3`.
  """
  @spec replace_all(String.t(), String.t(), String.t(), keyword()) :: String.t()
  @spec replace_all(Zipper.t() | Macro.t(), String.t(), String.t(), keyword()) :: Macro.t()
  def replace_all(input, pattern, replacement, opts \\ [])

  def replace_all(source, pattern, replacement, opts) when is_binary(source) do
    replacement_ast = Code.string_to_quoted!(replacement)
    matches = find_all(source, pattern, opts)

    patches =
      Enum.map(matches, fn %{range: range, captures: captures} ->
        substituted = Pattern.substitute(replacement_ast, captures)
        %{range: range, change: substituted |> restore_meta() |> Macro.to_string()}
      end)

    Sourceror.patch_string(source, patches)
  end

  def replace_all(%Zipper{} = zipper, pattern, replacement, opts) do
    zipper |> Zipper.topmost_root() |> do_replace_all_ast(pattern, replacement, opts)
  end

  def replace_all(ast, pattern, replacement, opts) do
    do_replace_all_ast(ast, pattern, replacement, opts)
  end

  # --- Core find logic ---

  defp do_find_all(ast, pattern, opts) do
    matches =
      if Pattern.multi_node?(pattern) do
        collect_sequence_matches(ast, pattern)
      else
        ast |> Zipper.zip() |> collect_matches(pattern, [])
      end

    apply_where(matches, opts)
  end

  # --- Core replace logic (AST → AST) ---

  defp do_replace_all_ast(ast, pattern, replacement, opts) do
    replacement_ast = Code.string_to_quoted!(replacement)
    matches = do_find_all(ast, pattern, opts)
    matched_nodes = MapSet.new(matches, & &1.node)

    Macro.prewalk(ast, fn node ->
      maybe_replace_node(node, matched_nodes, pattern, replacement_ast)
    end)
  end

  defp maybe_replace_node(node, matched_nodes, pattern, replacement_ast) do
    if MapSet.member?(matched_nodes, node) do
      case Pattern.match(node, pattern) do
        {:ok, captures} ->
          captures
          |> strip_sourceror_meta()
          |> then(&Pattern.substitute(replacement_ast, &1))
          |> restore_meta()

        :error ->
          node
      end
    else
      node
    end
  end

  defp strip_sourceror_meta(captures) do
    Map.new(captures, fn {key, value} -> {key, do_strip_sourceror_meta(value)} end)
  end

  defp do_strip_sourceror_meta({form, _meta, args}) when is_atom(form) do
    {form, [], do_strip_sourceror_meta(args)}
  end

  defp do_strip_sourceror_meta({form, _meta, args}) do
    {do_strip_sourceror_meta(form), [], do_strip_sourceror_meta(args)}
  end

  defp do_strip_sourceror_meta({left, right}) do
    {do_strip_sourceror_meta(left), do_strip_sourceror_meta(right)}
  end

  defp do_strip_sourceror_meta(list) when is_list(list) do
    Enum.map(list, &do_strip_sourceror_meta/1)
  end

  defp do_strip_sourceror_meta(other), do: other

  # --- Single-node matching ---

  defp collect_matches(nil, _pattern, acc), do: Enum.reverse(acc)

  defp collect_matches(zipper, pattern, acc) do
    node = Zipper.node(zipper)

    case Pattern.match(node, pattern) do
      {:ok, captures} ->
        range = safe_range(node)
        ancestors = collect_ancestors(zipper)
        match = %{node: node, range: range, captures: captures, ancestors: ancestors}
        zipper |> Zipper.skip() |> collect_matches(pattern, [match | acc])

      :error ->
        zipper |> Zipper.next() |> collect_matches(pattern, acc)
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
    root_ast |> Zipper.zip() |> find_node_ancestors(target_node)
  end

  defp find_node_ancestors(nil, _target), do: []

  defp find_node_ancestors(zipper, target) do
    if Zipper.node(zipper) == target do
      collect_ancestors(zipper)
    else
      zipper |> Zipper.next() |> find_node_ancestors(target)
    end
  end

  # --- Shared helpers ---

  defp collect_ancestors(zipper) do
    case Zipper.up(zipper) do
      nil -> []
      parent -> [Zipper.node(parent) | collect_ancestors(parent)]
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

  defp restore_meta(ast) do
    Macro.prewalk(ast, fn
      {form, nil, args} -> {form, [], args}
      other -> other
    end)
  end

  defp safe_range(node) do
    Sourceror.get_range(node)
  rescue
    _ -> nil
  end
end
