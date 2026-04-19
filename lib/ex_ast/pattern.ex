defmodule ExAST.Pattern do
  @moduledoc """
  AST pattern matching with captures.

  Patterns are valid Elixir syntax where:
  - Bare variables (`name`, `expr`) capture the matched AST node
  - `_` and `_name` are wildcards (match anything, don't capture)
  - Structs and maps match partially (only specified keys must be present)
  - Pipes are normalized (`data |> Enum.map(f)` matches `Enum.map(data, f)`)
  - Multi-statement patterns match contiguous sequences in blocks

  Repeated variable names require the same value at every position.
  """

  @type captures :: %{atom() => term()}

  @doc """
  Returns `true` if the pattern string contains multiple statements
  (separated by `;` or newlines), enabling sequential matching.
  """
  @spec multi_node?(String.t()) :: boolean()
  def multi_node?(pattern_string) do
    case Code.string_to_quoted!(pattern_string) do
      {:__block__, _, [_ | _] = children} when length(children) > 1 -> true
      _ -> false
    end
  end

  @doc """
  Returns the individual pattern ASTs from a multi-node pattern string.
  """
  @spec pattern_nodes(String.t()) :: [Macro.t()]
  def pattern_nodes(pattern_string) do
    case Code.string_to_quoted!(pattern_string) do
      {:__block__, _, children} when is_list(children) -> children
      single -> [single]
    end
  end

  @doc """
  Matches a Sourceror AST node against a pattern string.

  Returns `{:ok, captures}` on match, `:error` otherwise.
  """
  @spec match(Macro.t(), String.t()) :: {:ok, captures()} | :error
  def match(node, pattern_string) when is_binary(pattern_string) do
    pattern_ast = Code.string_to_quoted!(pattern_string)
    do_match(normalize(node), normalize(pattern_ast), %{})
  end

  @doc """
  Matches a Sourceror AST node against an already-parsed pattern AST.
  """
  @spec match_ast(Macro.t(), Macro.t()) :: {:ok, captures()} | :error
  def match_ast(node, pattern_ast) do
    do_match(normalize(node), normalize(pattern_ast), %{})
  end

  @doc """
  Finds all contiguous subsequences of `nodes` matching `pattern_asts`.

  Returns a list of `{captures, start_index..end_index}` tuples.
  Captures are accumulated across all matched nodes and must be consistent.
  """
  @spec match_sequences([Macro.t()], [Macro.t()]) :: [{captures(), Range.t()}]
  def match_sequences(nodes, pattern_asts) when is_list(nodes) and is_list(pattern_asts) do
    pattern_count = length(pattern_asts)
    normalized_patterns = Enum.map(pattern_asts, &normalize/1)
    do_match_sequences(nodes, normalized_patterns, pattern_count, 0, [])
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

  # --- Normalization ---

  # Strips metadata, unwraps __block__ wrappers, and desugars pipes
  # so both pattern and source ASTs have the same shape.
  defp normalize({:__block__, _meta, [inner]}), do: normalize(inner)

  # Desugar pipe: `a |> f(b, c)` → `f(a, b, c)`
  defp normalize({:|>, _meta, [left, {form, meta2, args}]}) when is_list(args),
    do: normalize({form, meta2, [left | args]})

  defp normalize({:|>, _meta, [left, {form, meta2, nil}]}),
    do: normalize({form, meta2, [left]})

  defp normalize({form, _meta, args}) when is_atom(form),
    do: {form, nil, normalize(args)}

  defp normalize({form, _meta, args}),
    do: {normalize(form), nil, normalize(args)}

  defp normalize({left, right}),
    do: {normalize(left), normalize(right)}

  defp normalize(list) when is_list(list),
    do: Enum.map(list, &normalize/1)

  defp normalize(other), do: other

  # --- Matching ---

  # Wildcard: _ or _name
  defp do_match(_node, {:_, nil, nil}, caps), do: {:ok, caps}

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

  # Lists (exact length)
  defp do_match(source, pattern, caps)
       when is_list(source) and is_list(pattern) and length(source) == length(pattern) do
    Enum.zip(source, pattern)
    |> Enum.reduce_while({:ok, caps}, fn {s, p}, {:ok, caps} ->
      case do_match(s, p, caps) do
        {:ok, caps} -> {:cont, {:ok, caps}}
        :error -> {:halt, :error}
      end
    end)
  end

  # Literal equality
  defp do_match(same, same, caps), do: {:ok, caps}

  defp do_match(_source, _pattern, _caps), do: :error

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

  defp do_substitute({name, meta, nil}, captures) when is_atom(name) do
    s = Atom.to_string(name)

    if not String.starts_with?(s, "_") and Map.has_key?(captures, name) do
      Map.fetch!(captures, name)
    else
      {name, meta, nil}
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
