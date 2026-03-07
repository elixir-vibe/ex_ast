defmodule ExAst.Pattern do
  @moduledoc """
  AST pattern matching with captures.

  Patterns are valid Elixir syntax where:
  - Bare variables (`name`, `expr`) capture the matched AST node
  - `_` and `_name` are wildcards (match anything, don't capture)
  - Structs and maps match partially (only specified keys must be present)
  - Everything else matches literally

  Repeated variable names require the same value at every position.
  """

  @type captures :: %{atom() => term()}

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
  Substitutes captured values into a replacement template AST.

  Variables in the template that match capture names are replaced
  with the captured AST nodes.
  """
  @spec substitute(Macro.t(), captures()) :: Macro.t()
  def substitute(template_ast, captures) do
    do_substitute(template_ast, captures)
  end

  # --- Normalization ---

  # Strips metadata and unwraps Sourceror's __block__ wrappers
  # so both pattern and source ASTs have the same shape.
  defp normalize({:__block__, _meta, [inner]}), do: normalize(inner)

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
      case Enum.find(source_kvs, fn {skey, _} -> skey == pkey end) do
        {_, sval} ->
          case do_match(sval, pval, caps) do
            {:ok, caps} -> {:cont, {:ok, caps}}
            :error -> {:halt, :error}
          end

        nil ->
          {:halt, :error}
      end
    end)
  end

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
