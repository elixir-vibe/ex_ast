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
  alias ExAST.Selector.CommentMatcher
  alias ExAST.Selector.Predicate
  alias Sourceror.Zipper

  @type match :: %{
          node: Macro.t(),
          range: Sourceror.Range.t() | nil,
          captures: Pattern.captures(),
          source: String.t() | nil
        }

  @type pattern_name :: term()
  @type named_pattern :: {pattern_name(), Pattern.pattern() | Selector.t()}
  @type tagged_match :: %{required(:pattern) => pattern_name(), optional(atom()) => term()}

  @doc """
  Finds all occurrences of `pattern`.

  The first argument can be a source string, a `Sourceror.Zipper`, or a raw AST.
  The pattern can be a string or a quoted expression.

  Returns a list of match maps with:

    * `:node` — the matched AST node
    * `:range` — a `Sourceror.Range.t()` with line/column positions, or `nil`
    * `:captures` — a map of captured names to AST nodes
    * `:source` — the matched source text, or `nil` for AST/zipper input

  Range fields are accessed as keyword lists:

      match.range.start[:line]   #=> line number (1-based)
      match.range.start[:column] #=> column number (1-based)
      match.range.end[:line]
      match.range.end[:column]

  ## Options

    * `:inside` — only match nodes nested within an ancestor matching this pattern
    * `:not_inside` — reject nodes nested within an ancestor matching this pattern
    * `:expand_imports` — when `true`, resolve `import Mod` (including `except:`
      and `only: :functions` / `:macros`) to `Mod`'s real exports, scoped to the
      enclosing module, so `map(a, b)` matches `Mod.map(_, _)`. Defaults to
      `false`; requires `Mod` to be loadable.
  """
  @spec find_all(String.t() | Zipper.t() | Macro.t(), Pattern.pattern() | Selector.t(), keyword()) ::
          [
            match()
          ]
  def find_all(input, pattern, opts \\ [])

  def find_all(source, %Selector{} = selector, opts) when is_binary(source) do
    source
    |> Sourceror.parse_string!()
    |> do_find_all(selector, opts, source_comments(source), source_lines(source))
  end

  def find_all(source, pattern, opts) when is_binary(source) do
    source
    |> Sourceror.parse_string!()
    |> do_find_all(pattern, opts, nil, source_lines(source))
  end

  def find_all(%Zipper{} = zipper, %Selector{} = selector, opts) do
    zipper |> Zipper.topmost_root() |> do_find_all(selector, opts, nil, nil)
  end

  def find_all(%Zipper{} = zipper, pattern, opts) do
    zipper |> Zipper.topmost_root() |> do_find_all(pattern, opts, nil, nil)
  end

  def find_all(ast, pattern, opts) do
    do_find_all(ast, pattern, opts, nil, nil)
  end

  @doc """
  Finds matches for multiple named patterns in a single pass where possible.

  `patterns` may be a keyword list or a map. Returned matches include a
  `:pattern` field with the matching pattern name:

      Patcher.find_many(source,
        inspect_call: "IO.inspect(expr)",
        debug_call: "dbg(expr)"
      )

  This is useful for analyzers that run many independent pattern checks over
  the same source tree. Single-node patterns are compiled once and scanned
  together; selectors and multi-node sequence patterns fall back to the regular
  matcher while keeping the same tagged result shape.
  """
  @spec find_many(
          String.t() | Zipper.t() | Macro.t(),
          [named_pattern()] | %{pattern_name() => Pattern.pattern() | Selector.t()},
          keyword()
        ) :: [tagged_match()]
  def find_many(input, patterns, opts \\ [])

  def find_many(source, patterns, opts) when is_binary(source) do
    source
    |> Sourceror.parse_string!()
    |> do_find_many(
      named_patterns!(patterns),
      opts,
      source_comments(source),
      source_lines(source)
    )
  end

  def find_many(%Zipper{} = zipper, patterns, opts) do
    zipper |> Zipper.topmost_root() |> do_find_many(named_patterns!(patterns), opts, nil, nil)
  end

  def find_many(ast, patterns, opts) do
    do_find_many(ast, named_patterns!(patterns), opts, nil, nil)
  end

  @doc false
  @spec named_patterns!([named_pattern()] | %{pattern_name() => Pattern.pattern() | Selector.t()}) ::
          [named_pattern()]
  def named_patterns!(patterns) when is_map(patterns), do: Map.to_list(patterns)

  def named_patterns!(patterns) when is_list(patterns) do
    if Keyword.keyword?(patterns) do
      patterns
    else
      raise ArgumentError, "expected a keyword list or map of named patterns"
    end
  end

  def named_patterns!(_patterns) do
    raise ArgumentError, "expected a keyword list or map of named patterns"
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

  defp source_comments(source) do
    case Code.string_to_quoted_with_comments(source, columns: true) do
      {:ok, _ast, comments} -> comments
      _ -> []
    end
  rescue
    _ -> []
  end

  defp source_lines(source) do
    String.split(source, "\n", trim: false)
  end

  defp do_find_all(ast, pattern, opts, comments, source_lines)

  defp do_find_all(ast, %Selector{} = selector, opts, comments, source_lines) do
    alias_env = Pattern.collect_aliases(ast, opts)

    ast
    |> collect_selector_matches(selector, alias_env)
    |> apply_selector_filters(selector.filters, ast, alias_env, comments)
    |> Enum.map(&selector_result/1)
    |> apply_where(opts, alias_env, source_lines)
  end

  defp do_find_all(ast, pattern, opts, _comments, source_lines) do
    alias_env = Pattern.collect_aliases(ast, opts)

    matches =
      if Pattern.multi_node?(pattern) do
        collect_sequence_matches(ast, pattern, alias_env)
      else
        compiled_pattern = Pattern.compile(pattern)
        signature = Pattern.candidate_signature(compiled_pattern)
        ast |> Zipper.zip() |> collect_matches(compiled_pattern, signature, alias_env, [])
      end

    apply_where(matches, opts, alias_env, source_lines)
  end

  defp do_find_many(ast, patterns, opts, comments, source_lines) do
    alias_env = Pattern.collect_aliases(ast, opts)
    {compiled, fallback} = split_many_patterns(patterns)

    compiled_matches =
      case compiled do
        [] ->
          []

        patterns ->
          ast |> Zipper.zip() |> collect_many_matches(patterns, ast, alias_env, comments, %{}, [])
      end

    compiled_matches = apply_where(compiled_matches, opts, alias_env, source_lines)

    fallback_matches =
      Enum.flat_map(fallback, fn {name, pattern} ->
        ast
        |> do_find_all(pattern, opts, comments, source_lines)
        |> Enum.map(&Map.put(&1, :pattern, name))
      end)

    compiled_matches ++ fallback_matches
  end

  # --- Core replace logic (AST → AST) ---

  defp do_replace_all_ast(ast, pattern, replacement, opts) do
    replacement_ast = to_quoted(replacement)

    matched_captures =
      ast
      |> do_find_all(pattern, opts, nil, nil)
      |> Map.new(&{&1.node, &1.captures})

    Macro.prewalk(ast, fn node ->
      maybe_replace_node(node, matched_captures, replacement_ast)
    end)
  end

  defp maybe_replace_node(node, matched_captures, replacement_ast) do
    case Map.fetch(matched_captures, node) do
      {:ok, captures} ->
        captures
        |> ExAST.AST.strip_sourceror_meta()
        |> then(&Pattern.substitute(replacement_ast, &1))
        |> restore_meta()

      :error ->
        node
    end
  end

  # --- Single-node matching ---

  defp collect_matches(nil, _pattern, _signature, _alias_env, acc), do: Enum.reverse(acc)

  defp collect_matches(zipper, compiled_pattern, signature, alias_env, acc) do
    node = Zipper.node(zipper)

    if Pattern.candidate?(node, signature) do
      collect_match(zipper, node, compiled_pattern, signature, alias_env, acc)
    else
      zipper |> Zipper.next() |> collect_matches(compiled_pattern, signature, alias_env, acc)
    end
  end

  defp collect_match(zipper, node, compiled_pattern, signature, alias_env, acc) do
    {env, scoped_ancestors} = scope_env(alias_env, zipper)

    case Pattern.match_compiled(node, compiled_pattern, env) do
      {:ok, captures} ->
        range = safe_range(node)
        ancestors = scoped_ancestors || collect_ancestors(zipper)
        match = %{node: node, range: range, captures: captures, ancestors: ancestors}

        zipper
        |> Zipper.next()
        |> collect_matches(compiled_pattern, signature, alias_env, [match | acc])

      :error ->
        zipper |> Zipper.next() |> collect_matches(compiled_pattern, signature, alias_env, acc)
    end
  end

  defp collect_many_matches(nil, _patterns, _root_ast, _alias_env, _comments, _blocked, acc),
    do: Enum.reverse(acc)

  defp collect_many_matches(zipper, patterns, root_ast, alias_env, comments, blocked, acc) do
    node = Zipper.node(zipper)

    candidates =
      Enum.filter(patterns, fn entry ->
        Pattern.candidate?(node, many_entry_signature(entry))
      end)

    if candidates == [] do
      zipper
      |> Zipper.next()
      |> collect_many_matches(patterns, root_ast, alias_env, comments, blocked, acc)
    else
      collect_many_candidate_matches(
        zipper,
        candidates,
        patterns,
        root_ast,
        alias_env,
        comments,
        blocked,
        acc
      )
    end
  end

  defp collect_many_candidate_matches(
         zipper,
         candidates,
         patterns,
         root_ast,
         alias_env,
         comments,
         blocked,
         acc
       ) do
    node = Zipper.node(zipper)
    {env, scoped_ancestors} = scope_env(alias_env, zipper)
    normalized_node = Pattern.normalize_node(node, env)

    ancestors =
      cond do
        scoped_ancestors -> scoped_ancestors
        map_size(blocked) == 0 -> nil
        true -> collect_ancestors(zipper)
      end

    context = %{
      ancestors: ancestors,
      get_ancestors: fn -> collect_ancestors(zipper) end,
      node: node,
      normalized_node: normalized_node,
      root_ast: root_ast,
      alias_env: alias_env,
      comments: comments
    }

    {blocked, matches} = match_many_patterns(candidates, context, blocked)

    zipper
    |> Zipper.next()
    |> collect_many_matches(patterns, root_ast, alias_env, comments, blocked, matches ++ acc)
  end

  defp match_many_patterns(patterns, context, blocked) do
    Enum.reduce(patterns, {blocked, []}, fn entry, {blocked, matches} ->
      id = many_entry_id(entry)

      if blocked_by_ancestor?(context.ancestors, Map.get(blocked, id, [])) do
        {blocked, matches}
      else
        match_many_pattern(entry, context.node, context, blocked, matches)
      end
    end)
  end

  defp many_entry_id({:pattern, id, _name, _pattern, _signature}), do: id
  defp many_entry_id({:selector, id, _name, _selector, _pattern, _signature, _filters}), do: id

  defp many_entry_signature({:pattern, _id, _name, _pattern, signature}), do: signature

  defp many_entry_signature({:selector, _id, _name, _selector, _pattern, signature, _filters}),
    do: signature

  defp match_many_pattern(
         {:pattern, id, name, %ExAST.CompiledPattern{ast: ast}, _signature},
         node,
         context,
         blocked,
         matches
       ) do
    case Pattern.match_normalized(context.normalized_node, ast) do
      {:ok, captures} ->
        match = %{
          pattern: name,
          node: node,
          range: safe_range(node),
          captures: captures,
          ancestors: context.ancestors || context.get_ancestors.()
        }

        {Map.update(blocked, id, [node], &[node | &1]), [match | matches]}

      :error ->
        {blocked, matches}
    end
  end

  defp match_many_pattern(
         {:selector, _id, name, _selector, %ExAST.CompiledPattern{ast: ast}, _signature, filters},
         node,
         context,
         blocked,
         matches
       ) do
    case Pattern.match_normalized(context.normalized_node, ast) do
      {:ok, captures} ->
        match = %{
          pattern: name,
          node: node,
          range: safe_range(node),
          captures: captures,
          ancestors: context.ancestors || context.get_ancestors.()
        }

        if apply_selector_filters(
             [match],
             filters,
             context.root_ast,
             context.alias_env,
             context.comments
           ) == [] do
          {blocked, matches}
        else
          {blocked, [match | matches]}
        end

      :error ->
        {blocked, matches}
    end
  end

  defp blocked_by_ancestor?(_ancestors, []), do: false
  defp blocked_by_ancestor?(nil, _blocked_nodes), do: false

  defp blocked_by_ancestor?(ancestors, blocked_nodes) do
    Enum.any?(blocked_nodes, fn blocked -> Enum.any?(ancestors, &(&1 == blocked)) end)
  end

  # --- Multi-node (sequence) matching ---

  defp collect_sequence_matches(ast, pattern, alias_env) do
    pattern_asts = Pattern.pattern_nodes(pattern)

    {_, matches} =
      Macro.prewalk(ast, [], fn node, acc ->
        case extract_block_children(node) do
          nil -> {node, acc}
          children -> {node, find_in_block(node, children, pattern_asts, ast, alias_env) ++ acc}
        end
      end)

    matches
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.range)
  end

  defp extract_block_children({:__block__, _meta, [_, _ | _] = children}), do: children

  defp extract_block_children({_form, _meta, args}) when is_list(args) do
    Enum.find_value(args, fn
      [{_, {:__block__, _, [_, _ | _] = children}}] ->
        children

      _ ->
        nil
    end)
  end

  defp extract_block_children(_), do: nil

  defp find_in_block(container, children, pattern_asts, root_ast, alias_env) do
    env = scope_block_env(alias_env, container, root_ast)

    Pattern.match_sequences(children, pattern_asts, env)
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
           steps: [{:self, pattern} | steps]
         },
         alias_env
       ) do
    root_ast
    |> selector_descendant_entries(include_self: true)
    |> Enum.flat_map(&selector_match(&1, pattern, root_ast, %{}, alias_env))
    |> follow_selector_steps(steps, root_ast, alias_env)
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

  defp apply_selector_filters(matches, filters, root_ast, alias_env, comments) do
    Enum.filter(matches, fn match ->
      Enum.all?(filters, &selector_filter?(match, &1, root_ast, alias_env, comments))
    end)
  end

  defp selector_filter?(
         match,
         %Predicate{relation: relation, pattern: pattern, negated?: negated?},
         root_ast,
         alias_env,
         comments
       ) do
    result = selector_filter?(match, relation, pattern, root_ast, alias_env, comments)

    if negated? do
      not result
    else
      result
    end
  end

  defp selector_filter?(match, :any, predicates, root_ast, alias_env, comments),
    do: Enum.any?(predicates, &selector_filter?(match, &1, root_ast, alias_env, comments))

  defp selector_filter?(match, :all, predicates, root_ast, alias_env, comments),
    do: Enum.all?(predicates, &selector_filter?(match, &1, root_ast, alias_env, comments))

  defp selector_filter?(
         %{ancestors: [parent | _]},
         :parent,
         pattern,
         _root_ast,
         alias_env,
         _comments
       ),
       do: pattern_match(parent, pattern, alias_env) != :error

  defp selector_filter?(%{ancestors: []}, :parent, _pattern, _root_ast, _alias_env, _comments),
    do: false

  defp selector_filter?(
         %{ancestors: ancestors},
         :ancestor,
         pattern,
         _root_ast,
         alias_env,
         _comments
       ),
       do: Enum.any?(ancestors, &(pattern_match(&1, pattern, alias_env) != :error))

  defp selector_filter?(%{node: node}, :has_child, pattern, _root_ast, alias_env, _comments),
    do: Enum.any?(semantic_children(node), &(pattern_match(&1, pattern, alias_env) != :error))

  defp selector_filter?(%{node: node}, :has_descendant, pattern, _root_ast, alias_env, _comments),
    do:
      node
      |> selector_descendants(include_self: false)
      |> Enum.any?(&(pattern_match(&1, pattern, alias_env) != :error))

  defp selector_filter?(match, :follows, pattern, _root_ast, alias_env, _comments) do
    match
    |> siblings_before()
    |> Enum.any?(&(pattern_match(&1, pattern, alias_env) != :error))
  end

  defp selector_filter?(match, :precedes, pattern, _root_ast, alias_env, _comments) do
    match
    |> siblings_after()
    |> Enum.any?(&(pattern_match(&1, pattern, alias_env) != :error))
  end

  defp selector_filter?(match, :immediately_follows, pattern, _root_ast, alias_env, _comments) do
    case List.last(siblings_before(match)) do
      nil -> false
      node -> pattern_match(node, pattern, alias_env) != :error
    end
  end

  defp selector_filter?(match, :immediately_precedes, pattern, _root_ast, alias_env, _comments) do
    case List.first(siblings_after(match)) do
      nil -> false
      node -> pattern_match(node, pattern, alias_env) != :error
    end
  end

  defp selector_filter?(%{node: {:|>, _, _}}, :piped, _pattern, _root_ast, _alias_env, _comments),
    do: true

  defp selector_filter?(_match, :piped, _pattern, _root_ast, _alias_env, _comments),
    do: false

  defp selector_filter?(match, :first, _pattern, _root_ast, _alias_env, _comments),
    do: sibling_position(match) == 0

  defp selector_filter?(match, :last, _pattern, _root_ast, _alias_env, _comments) do
    case sibling_context(match) do
      {_siblings, nil} -> false
      {siblings, index} -> index == length(siblings) - 1
    end
  end

  defp selector_filter?(match, :nth, index, _root_ast, _alias_env, _comments),
    do: sibling_position(match) == index - 1

  defp selector_filter?(
         %{captures: captures},
         :captures,
         pattern,
         _root_ast,
         _alias_env,
         _comments
       ) do
    fun = compile_guard_function(pattern)
    fun.(captures)
  end

  defp selector_filter?(match, relation, matcher, _root_ast, _alias_env, comments)
       when relation in [
              :comment,
              :comment_before,
              :comment_after,
              :comment_inside,
              :comment_inline
            ] do
    comments
    |> comments_for(match, relation)
    |> Enum.any?(&comment_matches?(&1, matcher))
  end

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

  defp comments_for(nil, _match, _relation), do: []

  defp comments_for(comments, %{range: %{start: start, end: end_}}, relation)
       when is_list(start) and is_list(end_) do
    start_line = start[:line]
    start_column = start[:column] || 1
    end_line = end_[:line]
    end_column = end_[:column] || start_column

    Enum.filter(comments, fn comment ->
      comment_in_relation?(comment, relation, start_line, start_column, end_line, end_column)
    end)
  end

  defp comments_for(_comments, _match, _relation), do: []

  defp comment_in_relation?(comment, :comment, start_line, start_column, end_line, end_column) do
    comment_in_relation?(comment, :comment_before, start_line, start_column, end_line, end_column) or
      comment_in_relation?(
        comment,
        :comment_inside,
        start_line,
        start_column,
        end_line,
        end_column
      ) or
      comment_in_relation?(
        comment,
        :comment_inline,
        start_line,
        start_column,
        end_line,
        end_column
      )
  end

  defp comment_in_relation?(
         comment,
         :comment_before,
         start_line,
         _start_column,
         _end_line,
         _end_column
       ),
       do: comment.line < start_line and comment.line + comment.next_eol_count == start_line

  defp comment_in_relation?(
         comment,
         :comment_after,
         _start_line,
         _start_column,
         end_line,
         _end_column
       ),
       do: comment.line > end_line and comment.line - comment.previous_eol_count == end_line

  defp comment_in_relation?(
         comment,
         :comment_inside,
         start_line,
         _start_column,
         end_line,
         _end_column
       ),
       do: comment.line >= start_line and comment.line <= end_line

  defp comment_in_relation?(
         comment,
         :comment_inline,
         start_line,
         _start_column,
         end_line,
         end_column
       ),
       do: start_line == end_line and comment.line == start_line and comment.column >= end_column

  defp comment_matches?(comment, matcher), do: do_comment_matches?(comment_text(comment), matcher)

  defp do_comment_matches?(text, %Regex{} = regex), do: Regex.match?(regex, text)

  defp do_comment_matches?(text, %CommentMatcher{kind: kind, value: value, case_sensitive?: case?}) do
    {text, value} = normalize_comment_case(text, value, case?)

    case kind do
      :text -> String.contains?(text, value)
      :exact -> text == value
      :prefix -> String.starts_with?(text, value)
      :suffix -> String.ends_with?(text, value)
    end
  end

  defp normalize_comment_case(text, value, true), do: {text, value}

  defp normalize_comment_case(text, value, false),
    do: {String.downcase(text), String.downcase(value)}

  defp comment_text(%{text: "#" <> text}), do: String.trim_leading(text)
  defp comment_text(%{text: text}), do: text

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

  # Scope imports to the matched node's module so they don't leak into siblings.
  # Returns the (maybe scoped) env plus the ancestors it computed, for reuse.
  defp scope_env(alias_env, zipper) do
    if Pattern.imports?(alias_env) do
      ancestors = collect_ancestors(zipper)
      {Pattern.scope_alias_env(alias_env, Pattern.module_path(ancestors)), ancestors}
    else
      {alias_env, nil}
    end
  end

  # Same, for sequence matching, where the module comes from the block container.
  defp scope_block_env(alias_env, container, root_ast) do
    if Pattern.imports?(alias_env) do
      ancestors = [container | collect_ancestors_for_node(container, root_ast)]
      Pattern.scope_alias_env(alias_env, Pattern.module_path(ancestors))
    else
      alias_env
    end
  end

  defp apply_where(matches, opts, alias_env, source_lines) do
    inside = Keyword.get(opts, :inside)
    not_inside = Keyword.get(opts, :not_inside)

    matches
    |> maybe_filter_inside(inside, alias_env)
    |> maybe_filter_not_inside(not_inside, alias_env)
    |> Enum.map(fn match ->
      match
      |> Map.delete(:ancestors)
      |> put_source(source_lines)
    end)
  end

  defp put_source(match, nil), do: Map.put(match, :source, nil)

  defp put_source(match, lines) do
    Map.put(match, :source, extract_fragment(lines, match.range))
  end

  defp extract_fragment(_lines, nil), do: nil

  defp extract_fragment(lines, %{start: start, end: end_})
       when is_list(start) and is_list(end_) do
    with start_line when is_integer(start_line) <- start[:line],
         start_column when is_integer(start_column) <- start[:column],
         end_line when is_integer(end_line) <- end_[:line],
         end_column when is_integer(end_column) <- end_[:column] do
      slice_lines(lines, start_line, start_column, end_line, end_column)
    else
      _ -> nil
    end
  end

  defp extract_fragment(_lines, _range), do: nil

  defp slice_lines(lines, line, start_column, line, end_column) do
    lines
    |> Enum.at(line - 1, "")
    |> String.slice((start_column - 1)..(end_column - 2)//1)
  end

  defp slice_lines(lines, start_line, start_column, end_line, end_column) do
    lines
    |> Enum.slice((start_line - 1)..(end_line - 1)//1)
    |> slice_first_last(start_column, end_column)
    |> Enum.join("\n")
  end

  defp slice_first_last([], _start_column, _end_column), do: []

  defp slice_first_last([first | rest], start_column, end_column) do
    {middle, [last]} = Enum.split(rest, max(length(rest) - 1, 0))

    [String.slice(first, (start_column - 1)..-1//1)] ++
      middle ++ [String.slice(last, 0..(end_column - 2)//1)]
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

  defp split_many_patterns(patterns) do
    patterns
    |> Stream.with_index()
    |> Enum.reduce({[], []}, fn {{name, pattern}, idx}, {compiled, fallback} ->
      case many_compiled_entry(idx, name, pattern) do
        {:ok, entry} -> {[entry | compiled], fallback}
        :error -> {compiled, [{name, pattern} | fallback]}
      end
    end)
    |> then(fn {compiled, fallback} -> {Enum.reverse(compiled), Enum.reverse(fallback)} end)
  end

  defp many_compiled_entry(
         idx,
         name,
         %Selector{steps: [{:self, pattern}], filters: filters} = selector
       ) do
    if single_node_pattern?(pattern) do
      compiled_pattern = Pattern.compile(pattern)

      {:ok,
       {:selector, idx, name, selector, compiled_pattern,
        Pattern.candidate_signature(compiled_pattern), filters}}
    else
      :error
    end
  end

  defp many_compiled_entry(idx, name, pattern) do
    if single_node_pattern?(pattern) do
      compiled_pattern = Pattern.compile(pattern)

      {:ok,
       {:pattern, idx, name, compiled_pattern, Pattern.candidate_signature(compiled_pattern)}}
    else
      :error
    end
  end

  defp single_node_pattern?(%Selector{}), do: false
  defp single_node_pattern?(pattern), do: not Pattern.multi_node?(pattern)

  defp to_quoted(pattern) when is_binary(pattern), do: Code.string_to_quoted!(pattern)
  defp to_quoted(pattern), do: pattern

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

  defp compile_guard_function({:fn, _, _} = ast), do: Code.eval_quoted(ast) |> elem(0)
  defp compile_guard_function(fun) when is_function(fun, 1), do: fun
end
