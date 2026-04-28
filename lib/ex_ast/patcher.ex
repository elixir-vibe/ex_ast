defmodule ExAST.Patcher do
  @moduledoc """
  Finds and replaces AST patterns in source code.

  Accepts source strings, AST nodes, or Sourceror zippers as input.
  Patterns and replacements can be strings or quoted expressions.

  Source-string input preserves formatting via `Sourceror.patch_string/2`.
  AST/zipper input returns modified AST trees.

      # All equivalent
      Patcher.find_all(source, "IO.inspect(_)")
      Patcher.find_all(ast, quote(do: IO.inspect(_)))
      Patcher.find_all(zipper, quote(do: IO.inspect(_)))

      import ExAST.Selector

      Patcher.find_all(source, pattern("defmodule _ do ... end") |> descendant("IO.inspect(_)"))
  """

  alias ExAST.Pattern
  alias ExAST.Selector
  alias ExAST.Selector.Predicate
  alias Sourceror.Zipper

  @type match :: %{
          node: Macro.t(),
          range: Sourceror.Range.t() | nil,
          captures: Pattern.captures()
        }

  @doc """
  Finds all occurrences of `pattern`.

  The first argument can be a source string, a `Sourceror.Zipper`, or a raw AST.
  The pattern can be a string or a quoted expression.

  ## Options

    * `:inside` — only match nodes nested within an ancestor matching this pattern
    * `:not_inside` — reject nodes nested within an ancestor matching this pattern
  """
  @spec find_all(String.t() | Zipper.t() | Macro.t(), Pattern.pattern() | Selector.t(), keyword()) ::
          [
            match()
          ]
  def find_all(input, pattern, opts \\ [])

  def find_all(source, %Selector{} = selector, opts) when is_binary(source) do
    source |> Sourceror.parse_string!() |> do_find_all(selector, opts)
  end

  def find_all(source, pattern, opts) when is_binary(source) do
    source |> Sourceror.parse_string!() |> do_find_all(pattern, opts)
  end

  def find_all(%Zipper{} = zipper, %Selector{} = selector, opts) do
    zipper |> Zipper.topmost_root() |> do_find_all(selector, opts)
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

  Pattern and replacement can be strings or quoted expressions.
  Captures from the pattern are substituted into the replacement template.
  Accepts the same `:inside` / `:not_inside` options as `find_all/3`.
  """
  @spec replace_all(String.t(), Pattern.pattern() | Selector.t(), Pattern.pattern(), keyword()) ::
          String.t()
  @spec replace_all(
          Zipper.t() | Macro.t(),
          Pattern.pattern() | Selector.t(),
          Pattern.pattern(),
          keyword()
        ) ::
          Macro.t()
  def replace_all(input, pattern, replacement, opts \\ [])

  def replace_all(source, pattern, replacement, opts) when is_binary(source) do
    replacement_ast = to_quoted(replacement)
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

  defp do_find_all(ast, %Selector{} = selector, opts) do
    alias_env = Pattern.collect_aliases(ast)

    ast
    |> collect_selector_matches(selector, alias_env)
    |> apply_where(opts, alias_env)
  end

  defp do_find_all(ast, pattern, opts) do
    alias_env = Pattern.collect_aliases(ast)

    matches =
      if Pattern.multi_node?(pattern) do
        collect_sequence_matches(ast, pattern, alias_env)
      else
        ast |> Zipper.zip() |> collect_matches(pattern, alias_env, [])
      end

    apply_where(matches, opts, alias_env)
  end

  # --- Core replace logic (AST → AST) ---

  defp do_replace_all_ast(ast, pattern, replacement, opts) do
    replacement_ast = to_quoted(replacement)

    matched_captures =
      ast
      |> do_find_all(pattern, opts)
      |> Map.new(&{&1.node, &1.captures})

    Macro.prewalk(ast, fn node ->
      maybe_replace_node(node, matched_captures, replacement_ast)
    end)
  end

  defp maybe_replace_node(node, matched_captures, replacement_ast) do
    case Map.fetch(matched_captures, node) do
      {:ok, captures} ->
        captures
        |> strip_sourceror_meta()
        |> then(&Pattern.substitute(replacement_ast, &1))
        |> restore_meta()

      :error ->
        node
    end
  end

  # --- Single-node matching ---

  defp collect_matches(nil, _pattern, _alias_env, acc), do: Enum.reverse(acc)

  defp collect_matches(zipper, pattern, alias_env, acc) do
    node = Zipper.node(zipper)

    case Pattern.match(node, pattern, alias_env) do
      {:ok, captures} ->
        range = safe_range(node)
        ancestors = collect_ancestors(zipper)
        match = %{node: node, range: range, captures: captures, ancestors: ancestors}
        zipper |> Zipper.skip() |> collect_matches(pattern, alias_env, [match | acc])

      :error ->
        zipper |> Zipper.next() |> collect_matches(pattern, alias_env, acc)
    end
  end

  # --- Multi-node (sequence) matching ---

  defp collect_sequence_matches(ast, pattern, alias_env) do
    pattern_asts = Pattern.pattern_nodes(pattern)

    {_, matches} =
      Macro.prewalk(ast, [], fn node, acc ->
        case extract_block_children(node) do
          nil -> {node, acc}
          children -> {node, find_in_block(children, pattern_asts, ast, alias_env) ++ acc}
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

  defp find_in_block(children, pattern_asts, root_ast, alias_env) do
    Pattern.match_sequences(children, pattern_asts, alias_env)
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

  # --- Selector matching ---

  defp collect_selector_matches(
         root_ast,
         %Selector{
           steps: [{:self, pattern} | steps],
           filters: filters
         },
         alias_env
       ) do
    root_ast
    |> selector_descendant_entries(include_self: true)
    |> Enum.flat_map(&selector_match(&1, pattern, root_ast, %{}, alias_env))
    |> follow_selector_steps(steps, root_ast, alias_env)
    |> apply_selector_filters(filters, root_ast, alias_env)
    |> Enum.map(&selector_result/1)
  end

  defp follow_selector_steps(matches, [], _root_ast, _alias_env), do: matches

  defp follow_selector_steps(matches, [{relation, pattern} | steps], root_ast, alias_env) do
    matches
    |> Enum.flat_map(fn %{node: node, ancestors: ancestors, captures: captures} ->
      node
      |> selector_candidate_entries(ancestors, relation)
      |> Enum.flat_map(&selector_match(&1, pattern, root_ast, captures, alias_env))
    end)
    |> follow_selector_steps(steps, root_ast, alias_env)
  end

  defp selector_candidate_entries(node, ancestors, :child) do
    node
    |> semantic_children()
    |> Enum.map(&{&1, [node | ancestors]})
  end

  defp selector_candidate_entries(node, ancestors, :descendant),
    do: selector_descendant_entries(node, ancestors, include_self: false)

  defp selector_match({node, _ancestors}, pattern, root_ast, captures, alias_env) do
    case pattern_match(node, pattern, alias_env) do
      {:ok, new_captures} ->
        case merge_captures(captures, new_captures) do
          {:ok, captures} ->
            [
              %{
                node: node,
                range: safe_range(node),
                captures: captures,
                ancestors: semantic_ancestors(root_ast, node)
              }
            ]

          :error ->
            []
        end

      :error ->
        []
    end
  end

  defp apply_selector_filters(matches, filters, root_ast, alias_env) do
    Enum.filter(matches, fn match ->
      Enum.all?(filters, &selector_filter?(match, &1, root_ast, alias_env))
    end)
  end

  defp selector_filter?(
         match,
         %Predicate{relation: relation, pattern: pattern, negated?: negated?},
         root_ast,
         alias_env
       ) do
    result = selector_filter?(match, relation, pattern, root_ast, alias_env)

    if negated? do
      not result
    else
      result
    end
  end

  defp selector_filter?(match, :any, predicates, root_ast, alias_env),
    do: Enum.any?(predicates, &selector_filter?(match, &1, root_ast, alias_env))

  defp selector_filter?(match, :all, predicates, root_ast, alias_env),
    do: Enum.all?(predicates, &selector_filter?(match, &1, root_ast, alias_env))

  defp selector_filter?(%{ancestors: [parent | _]}, :parent, pattern, _root_ast, alias_env),
    do: pattern_match(parent, pattern, alias_env) != :error

  defp selector_filter?(%{ancestors: []}, :parent, _pattern, _root_ast, _alias_env), do: false

  defp selector_filter?(%{ancestors: ancestors}, :ancestor, pattern, _root_ast, alias_env),
    do: Enum.any?(ancestors, &(pattern_match(&1, pattern, alias_env) != :error))

  defp selector_filter?(%{node: node}, :has_child, pattern, _root_ast, alias_env),
    do: Enum.any?(semantic_children(node), &(pattern_match(&1, pattern, alias_env) != :error))

  defp selector_filter?(%{node: node}, :has_descendant, pattern, _root_ast, alias_env),
    do:
      node
      |> selector_descendants(include_self: false)
      |> Enum.any?(&(pattern_match(&1, pattern, alias_env) != :error))

  defp selector_filter?(match, :follows, pattern, _root_ast, alias_env) do
    match
    |> siblings_before()
    |> Enum.any?(&(pattern_match(&1, pattern, alias_env) != :error))
  end

  defp selector_filter?(match, :precedes, pattern, _root_ast, alias_env) do
    match
    |> siblings_after()
    |> Enum.any?(&(pattern_match(&1, pattern, alias_env) != :error))
  end

  defp selector_filter?(match, :immediately_follows, pattern, _root_ast, alias_env) do
    case List.last(siblings_before(match)) do
      nil -> false
      node -> pattern_match(node, pattern, alias_env) != :error
    end
  end

  defp selector_filter?(match, :immediately_precedes, pattern, _root_ast, alias_env) do
    case List.first(siblings_after(match)) do
      nil -> false
      node -> pattern_match(node, pattern, alias_env) != :error
    end
  end

  defp selector_filter?(match, :first, _pattern, _root_ast, _alias_env),
    do: sibling_position(match) == 0

  defp selector_filter?(match, :last, _pattern, _root_ast, _alias_env) do
    case sibling_context(match) do
      {_siblings, nil} -> false
      {siblings, index} -> index == length(siblings) - 1
    end
  end

  defp selector_filter?(match, :nth, index, _root_ast, _alias_env),
    do: sibling_position(match) == index - 1

  defp pattern_match(node, {:__ex_ast_any_patterns__, patterns}, alias_env) do
    Enum.reduce_while(patterns, :error, fn pattern, :error ->
      case Pattern.match(node, pattern, alias_env) do
        {:ok, captures} -> {:halt, {:ok, captures}}
        :error -> {:cont, :error}
      end
    end)
  end

  defp pattern_match(node, pattern, alias_env), do: Pattern.match(node, pattern, alias_env)

  defp siblings_before(match) do
    case sibling_context(match) do
      {siblings, index} when is_integer(index) -> Enum.take(siblings, index)
      _ -> []
    end
  end

  defp siblings_after(match) do
    case sibling_context(match) do
      {siblings, index} when is_integer(index) -> Enum.drop(siblings, index + 1)
      _ -> []
    end
  end

  defp sibling_position(match) do
    case sibling_context(match) do
      {_siblings, index} when is_integer(index) -> index
      _ -> nil
    end
  end

  defp sibling_context(%{node: node, ancestors: [parent | _]}) do
    siblings = semantic_children(parent)
    {siblings, Enum.find_index(siblings, &(&1 == node))}
  end

  defp sibling_context(_match), do: {[], nil}

  defp selector_result(%{node: node, range: range, captures: captures, ancestors: ancestors}) do
    %{node: node, range: range, captures: captures, ancestors: ancestors}
  end

  defp selector_descendants(node, opts) do
    node
    |> selector_descendant_entries(opts)
    |> Enum.map(&elem(&1, 0))
  end

  defp selector_descendant_entries(node, opts),
    do: selector_descendant_entries(node, [], opts)

  defp selector_descendant_entries(node, ancestors, opts) do
    semantic_children = semantic_children(node)

    descendants =
      node
      |> ast_children()
      |> Enum.flat_map(fn child ->
        child_ancestors =
          if Enum.member?(semantic_children, child), do: [node | ancestors], else: ancestors

        selector_descendant_entries(child, child_ancestors, include_self: true)
      end)

    if Keyword.fetch!(opts, :include_self) do
      [{node, ancestors} | descendants]
    else
      descendants
    end
  end

  defp semantic_ancestors(root_ast, target_node) do
    case find_semantic_ancestors(root_ast, target_node, []) do
      {:ok, ancestors} -> ancestors
      nil -> []
    end
  end

  defp find_semantic_ancestors(node, target_node, ancestors) do
    if node == target_node do
      {:ok, ancestors}
    else
      Enum.find_value(semantic_children(node), fn child ->
        find_semantic_ancestors(child, target_node, [node | ancestors])
      end)
    end
  end

  defp merge_captures(left, right) do
    Enum.reduce_while(right, {:ok, left}, fn {key, value}, {:ok, acc} ->
      case Map.fetch(acc, key) do
        {:ok, ^value} -> {:cont, {:ok, acc}}
        {:ok, _other} -> {:halt, :error}
        :error -> {:cont, {:ok, Map.put(acc, key, value)}}
      end
    end)
  end

  defp ast_children({:__block__, _meta, children}) when is_list(children),
    do: Enum.filter(children, &ast_node?/1)

  defp ast_children({form, _meta, args}) when is_list(args) do
    [form, args]
    |> Enum.filter(&ast_node?/1)
  end

  defp ast_children({left, right}), do: Enum.filter([left, right], &ast_node?/1)
  defp ast_children(list) when is_list(list), do: Enum.filter(list, &ast_node?/1)
  defp ast_children(_), do: []

  defp semantic_children({:__block__, _meta, children}) when is_list(children), do: children

  defp semantic_children({_form, _meta, args}) when is_list(args) do
    children = do_block_children(args) || Enum.filter(args, &ast_node?/1)

    Enum.flat_map(children, fn
      {:__block__, _meta, [child]} -> [child]
      child -> [child]
    end)
  end

  defp semantic_children({left, right}), do: Enum.filter([left, right], &ast_node?/1)
  defp semantic_children(list) when is_list(list), do: Enum.filter(list, &ast_node?/1)
  defp semantic_children(_), do: []

  defp do_block_children(args) do
    Enum.find_value(args, fn
      [{_, {:__block__, _, children}}] when is_list(children) -> children
      [{_, child}] when is_tuple(child) or is_list(child) -> List.wrap(child)
      {_, {:__block__, _, children}} when is_list(children) -> children
      {_, child} when is_tuple(child) or is_list(child) -> List.wrap(child)
      _ -> nil
    end)
  end

  defp ast_node?({_form, _meta, _args}), do: true
  defp ast_node?({_, _}), do: true
  defp ast_node?(list) when is_list(list), do: true
  defp ast_node?(_), do: false

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

  defp apply_where(matches, opts, alias_env) do
    inside = Keyword.get(opts, :inside)
    not_inside = Keyword.get(opts, :not_inside)

    matches
    |> maybe_filter_inside(inside, alias_env)
    |> maybe_filter_not_inside(not_inside, alias_env)
    |> Enum.map(&Map.delete(&1, :ancestors))
  end

  defp maybe_filter_inside(matches, nil, _alias_env), do: matches

  defp maybe_filter_inside(matches, pattern, alias_env) do
    Enum.filter(matches, fn %{ancestors: ancestors} ->
      Enum.any?(ancestors, &(Pattern.match(&1, pattern, alias_env) != :error))
    end)
  end

  defp maybe_filter_not_inside(matches, nil, _alias_env), do: matches

  defp maybe_filter_not_inside(matches, pattern, alias_env) do
    Enum.reject(matches, fn %{ancestors: ancestors} ->
      Enum.any?(ancestors, &(Pattern.match(&1, pattern, alias_env) != :error))
    end)
  end

  defp to_quoted(pattern) when is_binary(pattern), do: Code.string_to_quoted!(pattern)
  defp to_quoted(pattern), do: pattern

  defp restore_meta(ast) do
    Macro.prewalk(ast, fn
      {form, nil, args} -> {form, [], args}
      other -> other
    end)
  end

  defp strip_sourceror_meta(captures) do
    Map.new(captures, fn {key, value} -> {key, do_strip_sourceror_meta(value)} end)
  end

  defp do_strip_sourceror_meta({form, _meta, args}) when is_atom(form),
    do: {form, [], do_strip_sourceror_meta(args)}

  defp do_strip_sourceror_meta({form, _meta, args}),
    do: {do_strip_sourceror_meta(form), [], do_strip_sourceror_meta(args)}

  defp do_strip_sourceror_meta({left, right}),
    do: {do_strip_sourceror_meta(left), do_strip_sourceror_meta(right)}

  defp do_strip_sourceror_meta(list) when is_list(list),
    do: Enum.map(list, &do_strip_sourceror_meta/1)

  defp do_strip_sourceror_meta(other), do: other

  defp safe_range(node) do
    Sourceror.get_range(node)
  rescue
    _ -> nil
  end
end
