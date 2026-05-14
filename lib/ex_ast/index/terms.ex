defmodule ExAST.Index.Terms do
  @moduledoc """
  Conservative structural terms extracted from Elixir AST and ExAST patterns.

  These terms are intended for candidate retrieval. They are not a substitute
  for ExAST verification.
  """

  @type mode :: :source | :pattern
  @type signal :: :high | :normal | :low

  @spec from_source(String.t()) :: MapSet.t(String.t())
  def from_source(source) when is_binary(source) do
    source
    |> Sourceror.parse_string!()
    |> from_ast()
  end

  @spec from_ast(Macro.t()) :: MapSet.t(String.t())
  def from_ast(ast), do: ast |> collect(:source) |> MapSet.new()

  @spec from_pattern(term() | [term()]) :: MapSet.t(String.t())
  def from_pattern({:__ex_ast_any_patterns__, patterns}) when is_list(patterns) do
    patterns
    |> Enum.map(&from_pattern/1)
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
  end

  def from_pattern(patterns) when is_list(patterns) do
    patterns
    |> Enum.map(&from_pattern/1)
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
  end

  def from_pattern(pattern), do: pattern |> to_quoted() |> collect(:pattern) |> MapSet.new()

  @spec signal(String.t()) :: signal()
  def signal("atom:" <> atom) when atom in ["do", "nil", "true", "false", "ok", "error"],
    do: :low

  def signal("node:call"), do: :low
  def signal("node:local_call"), do: :low
  def signal("node:remote_call"), do: :low
  def signal("call.arity:" <> _), do: :low
  def signal("call.local:./2"), do: :low
  def signal("call.function:."), do: :low
  def signal("atom:" <> _), do: :high
  def signal("call.local.same_args:" <> _), do: :high
  def signal("call.remote:" <> _), do: :high
  def signal("call.local:" <> _), do: :high
  def signal("def:" <> _), do: :high
  def signal("def.name:" <> _), do: :high
  def signal("attribute:" <> _), do: :high
  def signal("struct:" <> _), do: :high
  def signal("struct.field:" <> _), do: :high
  def signal("map.key:" <> _), do: :high
  def signal("alias:" <> _), do: :high
  def signal("module:" <> _), do: :high
  def signal(_term), do: :normal

  @spec high_signal?(String.t()) :: boolean()
  def high_signal?(term), do: signal(term) == :high

  @spec low_signal?(String.t()) :: boolean()
  def low_signal?(term), do: signal(term) == :low

  defp collect(ast, mode) do
    {_ast, terms} = Macro.prewalk(ast, [], &visit(&1, &2, mode))
    Enum.uniq(terms)
  end

  defp visit({:defmodule, _meta, [module_ast, body]} = node, terms, mode) do
    terms = ["node:defmodule" | terms]

    terms =
      if literal_alias?(module_ast) do
        ["module:#{alias_name(module_ast)}" | terms]
      else
        terms
      end

    {node, collect_into(body, terms, mode)}
  end

  defp visit({form, _meta, [head | _rest]} = node, terms, mode)
       when form in [:def, :defp, :defmacro, :defmacrop] do
    terms = ["node:#{form}", "node:def_like", "def.visibility:#{visibility(form)}" | terms]

    terms =
      case function_head(head, mode) do
        {:ok, name, arity} ->
          ["def.name:#{name}", "def.arity:#{arity}", "def:#{name}/#{arity}" | terms]

        :unknown ->
          terms
      end

    {node, terms}
  end

  defp visit({:@, _meta, [{name, _, args}]} = node, terms, _mode) when is_atom(name) do
    arity = if is_list(args), do: length(args), else: 0
    {node, ["node:attribute", "attribute:#{name}", "attribute.arity:#{arity}" | terms]}
  end

  defp visit({:%, _meta, [struct_ast, {:%{}, _, fields}]} = node, terms, _mode)
       when is_list(fields) do
    terms = ["node:struct" | terms]

    terms =
      if literal_alias?(struct_ast) do
        ["struct:#{alias_name(struct_ast)}" | terms]
      else
        terms
      end

    field_terms =
      Enum.flat_map(fields, fn
        {key, _value} when is_atom(key) -> ["struct.field:#{key}"]
        _ -> []
      end)

    {node, field_terms ++ terms}
  end

  defp visit({:%{}, _meta, fields} = node, terms, _mode) when is_list(fields) do
    key_terms =
      Enum.flat_map(fields, fn
        {key, _value} when is_atom(key) -> ["map.key:#{key}"]
        _ -> []
      end)

    {node, ["node:map" | key_terms] ++ terms}
  end

  defp visit({:__aliases__, _meta, parts} = node, terms, _mode) when is_list(parts) do
    if literal_alias?(node),
      do: {node, ["alias:#{Enum.join(parts, ".")}" | terms]},
      else: {node, terms}
  end

  defp visit({{:., _dot_meta, [module_ast, fun]}, _meta, args} = node, terms, _mode)
       when is_atom(fun) and is_list(args) do
    arity = length(args)

    terms = [
      "node:call",
      "node:remote_call",
      "call.function:#{fun}",
      "call.arity:#{arity}" | terms
    ]

    terms =
      if literal_alias?(module_ast) do
        module = alias_name(module_ast)
        ["call.module:#{module}", "call.remote:#{module}.#{fun}/#{arity}" | terms]
      else
        terms
      end

    {node, terms}
  end

  defp visit({name, _meta, args} = node, terms, mode) when is_atom(name) and is_list(args) do
    if synthetic_call?(name) or pattern_capture_call?(node, mode) do
      {node, terms}
    else
      arity = length(args)

      {node,
       [
         "node:call",
         "node:local_call",
         "call.local:#{name}/#{arity}",
         "call.function:#{name}",
         "call.arity:#{arity}" | same_arg_terms(name, args, terms)
       ]}
    end
  end

  defp visit(atom, terms, _mode) when is_atom(atom) and atom not in [nil, true, false] do
    {atom, ["atom:#{atom}" | terms]}
  end

  defp visit(node, terms, _mode), do: {node, terms}

  defp same_arg_terms(name, [left, right], terms) do
    if normalized(left) == normalized(right) do
      ["call.local.same_args:#{name}/2" | terms]
    else
      terms
    end
  end

  defp same_arg_terms(_name, _args, terms), do: terms

  defp normalized(ast) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_atom(form) and is_list(meta) -> {form, [], args}
      node -> node
    end)
  end

  defp collect_into(ast, terms, mode) do
    {_ast, nested} = Macro.prewalk(ast, terms, &visit(&1, &2, mode))
    nested
  end

  defp function_head({:when, _, [head | _guards]}, mode), do: function_head(head, mode)

  defp function_head({name, _, nil}, mode) when is_atom(name) do
    if pattern_capture_call?({name, [], nil}, mode), do: :unknown, else: {:ok, name, 0}
  end

  defp function_head({name, _, args}, mode) when is_atom(name) and is_list(args) do
    if pattern_capture_call?({name, [], args}, mode),
      do: :unknown,
      else: {:ok, name, length(args)}
  end

  defp function_head(_head, _mode), do: :unknown

  defp pattern_capture_call?({name, _meta, nil}, :pattern) when is_atom(name),
    do: capture_name?(name)

  defp pattern_capture_call?({_name, _meta, args}, :pattern), do: args == nil
  defp pattern_capture_call?(_node, _mode), do: false

  defp literal_alias?({:__aliases__, _, parts}), do: Enum.all?(parts, &is_atom/1)
  defp literal_alias?(_ast), do: false

  defp alias_name({:__aliases__, _, parts}), do: Enum.join(parts, ".")

  defp visibility(:defp), do: :private
  defp visibility(:defmacrop), do: :private
  defp visibility(_form), do: :public

  defp synthetic_call?(name), do: name in [:__aliases__, :..., :_]

  defp capture_name?(:_), do: true

  defp capture_name?(name) do
    name
    |> Atom.to_string()
    |> String.starts_with?("_")
  end

  defp to_quoted(pattern) when is_binary(pattern), do: Code.string_to_quoted!(pattern)
  defp to_quoted(pattern), do: pattern
end
