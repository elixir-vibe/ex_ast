defmodule ExAST.Pattern do
  @moduledoc """
  AST pattern matching with captures.

  Patterns are valid Elixir syntax where:
  - `name`, `expr` — capture the matched AST node
  - `_` or `_name` — wildcard, matches anything, not captured
  - `...` — matches zero or more nodes (args, list items, block statements)
  - Structs and maps match partially (only specified keys must be present)
  - Pipes are normalized (`data |> Enum.map(f)` matches `Enum.map(data, f)`)
  - Multi-statement patterns match contiguous sequences in blocks

  Repeated variable names require the same value at every position.

  Patterns can be given as strings or as quoted expressions:

      Pattern.match(node, "IO.inspect(_)")
      Pattern.match(node, quote(do: IO.inspect(_)))

  Use `...` for variable-arity matching:

      Pattern.match(node, "IO.inspect(...)")       # any arity
      Pattern.match(node, "foo(first, ...)")        # 1+ args, capture first
      Pattern.match(node, "def foo(_) do ... end")  # any body
  """

  @type captures :: %{atom() => term()}
  @type pattern :: String.t() | Macro.t()

  @doc """
  Returns `true` if the pattern contains multiple statements
  (separated by `;` or newlines), enabling sequential matching.
  """
  @spec multi_node?(pattern()) :: boolean()
  def multi_node?(pattern) do
    case to_quoted(pattern) do
      {:__block__, _, [_ | _] = children} when length(children) > 1 -> true
      _ -> false
    end
  end

  @doc """
  Returns the individual pattern ASTs from a (possibly multi-node) pattern.
  """
  @spec pattern_nodes(pattern()) :: [Macro.t()]
  def pattern_nodes(pattern) do
    case to_quoted(pattern) do
      {:__block__, _, children} when is_list(children) -> children
      single -> [single]
    end
  end

  @doc """
  Matches an AST node against a pattern.

  The pattern can be a string or a quoted expression.
  Returns `{:ok, captures}` on match, `:error` otherwise.

  Alias directives found in the surrounding AST can be expanded before matching,
  so `alias AshPhoenix.Form` followed by `Form.for_update(...)` matches
  `AshPhoenix.Form.for_update(...)`.
  """
  @spec match(Macro.t(), pattern()) :: {:ok, captures()} | :error
  def match(node, pattern) do
    match(node, pattern, %{})
  end

  @spec match(Macro.t(), pattern(), %{optional(atom()) => [atom()]}) :: {:ok, captures()} | :error
  def match(node, pattern, alias_env) do
    do_match(
      normalize(expand_aliases(node, alias_env)),
      pattern |> to_quoted() |> normalize(),
      %{}
    )
  end

  @doc """
  Matches an AST node against an already-parsed pattern AST.

  Equivalent to `match/2` with a quoted pattern, kept for
  backward compatibility.
  """
  @spec match_ast(Macro.t(), Macro.t()) :: {:ok, captures()} | :error
  def match_ast(node, pattern_ast) do
    match_ast(node, pattern_ast, %{})
  end

  @spec match_ast(Macro.t(), Macro.t(), %{optional(atom()) => [atom()]}) ::
          {:ok, captures()} | :error
  def match_ast(node, pattern_ast, alias_env) do
    do_match(normalize(expand_aliases(node, alias_env)), normalize(pattern_ast), %{})
  end

  @doc """
  Finds all contiguous subsequences of `nodes` matching `pattern_asts`.

  Returns a list of `{captures, start_index..end_index}` tuples.
  Captures are accumulated across all matched nodes and must be consistent.
  """
  @spec match_sequences([Macro.t()], [Macro.t()]) :: [{captures(), Range.t()}]
  def match_sequences(nodes, pattern_asts) when is_list(nodes) and is_list(pattern_asts) do
    match_sequences(nodes, pattern_asts, %{})
  end

  @spec match_sequences([Macro.t()], [Macro.t()], %{optional(atom()) => [atom()]}) ::
          [{captures(), Range.t()}]
  def match_sequences(nodes, pattern_asts, alias_env)
      when is_list(nodes) and is_list(pattern_asts) do
    pattern_count = length(pattern_asts)
    normalized_nodes = Enum.map(nodes, &normalize(expand_aliases(&1, alias_env)))
    normalized_patterns = Enum.map(pattern_asts, &normalize/1)
    do_match_sequences(normalized_nodes, normalized_patterns, pattern_count, 0, [])
  end

  defp do_match_sequences(nodes, _patterns, pattern_count, _offset, acc)
       when length(nodes) < pattern_count,
       do: Enum.reverse(acc)

  defp do_match_sequences(nodes, patterns, pattern_count, offset, acc) do
    window = Enum.take(nodes, pattern_count)

    case match_all(window, patterns, %{}) do
      {:ok, caps} ->
        range = offset..(offset + pattern_count - 1)
        do_match_sequences(tl(nodes), patterns, pattern_count, offset + 1, [{caps, range} | acc])

      :error ->
        do_match_sequences(tl(nodes), patterns, pattern_count, offset + 1, acc)
    end
  end

  defp match_all([], [], caps), do: {:ok, caps}

  defp match_all([node | nodes], [pattern | patterns], caps) do
    case do_match(normalize(node), pattern, caps) do
      {:ok, caps} -> match_all(nodes, patterns, caps)
      :error -> :error
    end
  end

  @doc """
  Substitutes captured values into a replacement template AST.

  Variables in the template that match capture names are replaced
  with the captured AST nodes.
  """
  @spec substitute(Macro.t(), captures()) :: Macro.t()
  def substitute(template_ast, captures) do
    do_substitute(template_ast, captures)
  end

  # --- Pattern coercion ---

  defp to_quoted(pattern) when is_binary(pattern), do: Code.string_to_quoted!(pattern)
  defp to_quoted(pattern), do: pattern

  # --- Normalization ---

  defp normalize({:__block__, _meta, [inner]}), do: normalize(inner)

  defp normalize({:|>, _meta, [left, {form, meta2, args}]}) when is_list(args),
    do: normalize({form, meta2, [left | args]})

  defp normalize({:|>, _meta, [left, {form, meta2, nil}]}),
    do: normalize({form, meta2, [left]})

  defp normalize({form, _meta, context}) when is_atom(form) and is_atom(context),
    do: {form, nil, nil}

  defp normalize({form, _meta, args}) when is_atom(form),
    do: {form, nil, normalize(args)}

  defp normalize({form, _meta, args}),
    do: {normalize(form), nil, normalize(args)}

  defp normalize({left, right}),
    do: {normalize(left), normalize(right)}

  defp normalize(list) when is_list(list),
    do: Enum.map(list, &normalize/1)

  defp normalize(other), do: other

  @doc false
  def collect_aliases(ast) do
    {_ast, aliases} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _, args} = node, acc when is_list(args) ->
          {node, collect_alias_directive(args, acc)}

        node, acc ->
          {node, acc}
      end)

    aliases
  end

  defp collect_alias_directive([target], acc), do: register_alias_target(acc, target)

  defp collect_alias_directive([target, opts], acc) when is_list(opts) do
    case Keyword.get(opts, :as) do
      nil -> register_alias_target(acc, target)
      as_alias -> put_alias(acc, as_alias, target)
    end
  end

  defp collect_alias_directive(args, acc) when is_list(args) do
    Enum.reduce(args, acc, fn target, aliases ->
      register_alias_target(aliases, target)
    end)
  end

  defp register_alias_target(acc, {:__aliases__, _, _} = target),
    do: put_alias(acc, target, target)

  defp register_alias_target(acc, {{:., _, [{:__aliases__, _, prefix}, :{}]}, _, suffixes})
       when is_list(prefix) and is_list(suffixes) do
    Enum.reduce(suffixes, acc, fn
      atom, aliases when is_atom(atom) ->
        put_alias(aliases, {:__aliases__, [], [atom]}, {:__aliases__, [], prefix ++ [atom]})

      {:__aliases__, _, parts}, aliases ->
        full = {:__aliases__, [], prefix ++ parts}
        put_alias(aliases, {:__aliases__, [], parts}, full)

      _other, aliases ->
        aliases
    end)
  end

  defp register_alias_target(acc, _target), do: acc

  defp put_alias(acc, {:__aliases__, _, parts}, {:__aliases__, _, target_parts}) do
    short = List.last(parts)
    Map.put(acc, short, target_parts)
  end

  defp put_alias(acc, _alias_ast, _target_ast), do: acc

  defp expand_aliases(ast, alias_env) do
    Macro.prewalk(ast, fn
      {:alias, _, _} = node -> node
      {:defmodule, meta, [name, body]} -> {:defmodule, meta, [name, body]}
      {:__aliases__, meta, [name]} = node -> expand_alias_node(node, meta, name, alias_env)
      node -> node
    end)
  end

  defp expand_alias_node(node, meta, name, alias_env) do
    case Map.fetch(alias_env, name) do
      {:ok, parts} -> {:__aliases__, meta, parts}
      :error -> node
    end
  end

  # --- Matching ---

  # Wildcard: _ or _name
  defp do_match(_node, {:_, nil, nil}, caps), do: {:ok, caps}

  # Ellipsis as single-node wildcard (matches any node in non-list position)
  defp do_match(_node, {:..., nil, _}, caps), do: {:ok, caps}

  # Named capture or underscore-prefixed non-capture
  defp do_match(node, {name, nil, nil}, caps) when is_atom(name) do
    case Atom.to_string(name) do
      "_" <> _ -> {:ok, caps}
      _ -> bind(name, node, caps)
    end
  end

  # Struct: partial key match
  defp do_match(
         {:%, nil, [sname, {:%{}, nil, skvs}]},
         {:%, nil, [pname, {:%{}, nil, pkvs}]},
         caps
       ) do
    with {:ok, caps} <- do_match(sname, pname, caps) do
      match_subset(skvs, pkvs, caps)
    end
  end

  # Map: partial key match
  defp do_match({:%{}, nil, skvs}, {:%{}, nil, pkvs}, caps) do
    match_subset(skvs, pkvs, caps)
  end

  # Dot-call: Module.function(args)
  defp do_match(
         {{:., nil, sdot}, nil, sargs},
         {{:., nil, pdot}, nil, pargs},
         caps
       ) do
    with {:ok, caps} <- do_match(sdot, pdot, caps) do
      do_match(sargs, pargs, caps)
    end
  end

  # 3-tuple with same atom head (operators, special forms)
  defp do_match({head, nil, schild}, {head, nil, pchild}, caps) when is_atom(head) do
    do_match(schild, pchild, caps)
  end

  # 3-tuple with different heads
  defp do_match({shead, nil, schild}, {phead, nil, pchild}, caps) do
    with {:ok, caps} <- do_match(shead, phead, caps) do
      do_match(schild, pchild, caps)
    end
  end

  # 2-tuple (keyword pair, two-element tuple)
  defp do_match({sa, sb}, {pa, pb}, caps) do
    with {:ok, caps} <- do_match(sa, pa, caps) do
      do_match(sb, pb, caps)
    end
  end

  # Lists with `...` (ellipsis) — variable-length matching
  defp do_match(source, pattern, caps)
       when is_list(source) and is_list(pattern) do
    if has_ellipsis?(pattern) do
      match_list_with_ellipsis(source, pattern, caps)
    else
      match_list_exact(source, pattern, caps)
    end
  end

  # Literal equality
  defp do_match(same, same, caps), do: {:ok, caps}

  defp do_match(_source, _pattern, _caps), do: :error

  # --- Ellipsis matching ---

  defp has_ellipsis?(pattern) do
    Enum.any?(pattern, &ellipsis?/1)
  end

  defp ellipsis?({:..., _, _}), do: true
  defp ellipsis?(_), do: false

  defp match_list_with_ellipsis(source, pattern, caps) do
    {before_ellipsis, after_ellipsis} = split_on_ellipsis(pattern)
    before_count = length(before_ellipsis)
    after_count = length(after_ellipsis)

    if length(source) < before_count + after_count do
      :error
    else
      source_before = Enum.take(source, before_count)
      source_after = Enum.take(source, -after_count)
      match_before_and_after(source_before, before_ellipsis, source_after, after_ellipsis, caps)
    end
  end

  defp match_before_and_after(source_before, before, source_after, after_, caps) do
    with {:ok, caps} <- match_list_exact(source_before, before, caps) do
      match_list_exact(source_after, after_, caps)
    end
  end

  defp split_on_ellipsis(pattern) do
    idx = Enum.find_index(pattern, &ellipsis?/1)
    before = Enum.take(pattern, idx)
    after_ = Enum.drop(pattern, idx + 1)
    {before, after_}
  end

  defp match_list_exact(source, pattern, caps) when length(source) == length(pattern) do
    Enum.zip(source, pattern)
    |> Enum.reduce_while({:ok, caps}, fn {s, p}, {:ok, caps} ->
      case do_match(s, p, caps) do
        {:ok, caps} -> {:cont, {:ok, caps}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp match_list_exact(_source, _pattern, _caps), do: :error

  # --- Captures ---

  defp bind(name, node, captures) do
    case Map.fetch(captures, name) do
      {:ok, ^node} -> {:ok, captures}
      {:ok, _different} -> :error
      :error -> {:ok, Map.put(captures, name, node)}
    end
  end

  # --- Subset matching for structs/maps ---

  defp match_subset(source_kvs, pattern_kvs, caps) do
    Enum.reduce_while(pattern_kvs, {:ok, caps}, fn {pkey, pval}, {:ok, caps} ->
      source_kvs
      |> find_value_by_key(pkey)
      |> match_kv_value(pval, caps)
    end)
  end

  defp find_value_by_key(kvs, key) do
    Enum.find_value(kvs, :error, fn
      {k, v} when k == key -> {:ok, v}
      _ -> nil
    end)
  end

  defp match_kv_value({:ok, sval}, pval, caps) do
    case do_match(sval, pval, caps) do
      {:ok, caps} -> {:cont, {:ok, caps}}
      :error -> {:halt, :error}
    end
  end

  defp match_kv_value(:error, _pval, _caps), do: {:halt, :error}

  # --- Substitution ---

  defp do_substitute({name, meta, context}, captures) when is_atom(name) and is_atom(context) do
    s = Atom.to_string(name)

    if not String.starts_with?(s, "_") and Map.has_key?(captures, name) do
      Map.fetch!(captures, name)
    else
      {name, meta, context}
    end
  end

  defp do_substitute({form, meta, args}, captures) when is_atom(form) do
    {form, meta, do_substitute(args, captures)}
  end

  defp do_substitute({form, meta, args}, captures) do
    {do_substitute(form, captures), meta, do_substitute(args, captures)}
  end

  defp do_substitute({left, right}, captures) do
    {do_substitute(left, captures), do_substitute(right, captures)}
  end

  defp do_substitute(list, captures) when is_list(list) do
    Enum.map(list, &do_substitute(&1, captures))
  end

  defp do_substitute(other, _captures), do: other
end
