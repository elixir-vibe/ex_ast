defmodule ExAST.Index.Terms do
  @moduledoc """
  Conservative structural terms extracted from Elixir AST and ExAST patterns.

  These terms are intended for candidate retrieval. They are not a substitute
  for ExAST verification.
  """

  alias ExAST.Ident

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
  def signal("atom:" <> atom) when atom in ["do", "ok", "error"],
    do: :low

  def signal("atom:" <> atom) when atom in ["nil", "true", "false"], do: :normal
  def signal("integer:" <> _integer), do: :normal
  def signal("call.arg:" <> _argument_literal), do: :normal

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
    Enum.uniq(literal_terms(ast) ++ terms)
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

  defp visit({:@, _meta, [{name, _, args}]} = node, terms, _mode) do
    if identifier?(name) do
      name = identifier_name(name)
      arity = if is_list(args), do: length(args), else: 0
      {node, ["node:attribute", "attribute:#{name}", "attribute.arity:#{arity}" | terms]}
    else
      {node, terms}
    end
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
        {key, _value} ->
          if identifier?(key), do: ["struct.field:#{identifier_name(key)}"], else: []

        _other ->
          []
      end)

    {node, field_terms ++ terms}
  end

  defp visit({:%{}, _meta, fields} = node, terms, _mode) when is_list(fields) do
    key_terms =
      Enum.flat_map(fields, fn
        {key, _value} -> if identifier?(key), do: ["map.key:#{identifier_name(key)}"], else: []
        _other -> []
      end)

    {node, ["node:map" | key_terms] ++ terms}
  end

  defp visit({:__aliases__, _meta, _parts} = node, terms, _mode) do
    if literal_alias?(node),
      do: {node, ["alias:#{alias_name(node)}" | terms]},
      else: {node, terms}
  end

  defp visit({:|>, _meta, [_left, right]} = node, terms, :source) do
    {node,
     [
       "node:call",
       "node:local_call",
       "call.local:|>/2",
       "call.function:|>",
       "call.arity:2"
       | pipe_rhs_equivalent_terms(right) ++ terms
     ]}
  end

  defp visit({{:., _dot_meta, [module_ast, fun]}, _meta, args} = node, terms, mode)
       when is_list(args) do
    if identifier?(fun) do
      fun = identifier_name(fun)
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
          remote = "#{module}.#{fun}/#{arity}"

          [
            "call.module:#{module}",
            "call.remote:#{remote}"
            | source_pipe_equivalent_remote_terms(mode, module, fun, arity) ++
                arg_literal_terms(remote, args, terms)
          ]
        else
          terms
        end

      {node, terms}
    else
      {node, terms}
    end
  end

  defp visit({name, _meta, args} = node, terms, mode) when is_list(args) do
    if not identifier?(name) or synthetic_call?(name) or pattern_capture_call?(node, mode) do
      {node, terms}
    else
      name = identifier_name(name)
      arity = length(args)

      local = "#{name}/#{arity}"

      {node,
       [
         "node:call",
         "node:local_call",
         "call.local:#{local}",
         "call.function:#{name}",
         "call.arity:#{arity}"
         | source_pipe_equivalent_local_terms(mode, name, arity) ++
             arg_literal_terms(local, args, same_arg_terms(name, args, terms))
       ]}
    end
  end

  defp visit(atom, terms, _mode) when is_atom(atom) and not is_nil(atom) do
    {atom, ["atom:#{atom}" | terms]}
  end

  defp visit({:__exograph_ident__, name} = ident, terms, _mode) when is_binary(name) do
    {ident, ["atom:#{name}" | terms]}
  end

  defp visit(node, terms, _mode), do: {node, terms}

  defp literal_terms(nil), do: ["atom:nil"]
  defp literal_terms(true), do: ["atom:true"]
  defp literal_terms(false), do: ["atom:false"]

  defp literal_terms({:__block__, _meta, [literal]}), do: literal_terms(literal)

  defp literal_terms(integer) when is_integer(integer) and integer in -10..10,
    do: ["integer:#{integer}"]

  defp literal_terms(integer) when is_integer(integer), do: []

  defp literal_terms({:__exograph_ident__, name}) when is_binary(name), do: ["atom:#{name}"]

  defp literal_terms({:-, _meta, [literal]}) do
    case literal_integer(literal) do
      integer when integer in 1..10 -> ["integer:-#{integer}"]
      _other -> []
    end
  end

  defp literal_terms({name, meta, context})
       when is_atom(name) and is_list(meta) and (is_atom(context) or is_nil(context)),
       do: []

  defp literal_terms({{:., _dot_meta, [module_ast, _fun]}, _meta, args}) when is_list(args) do
    literal_terms(module_ast) ++ literal_terms(args)
  end

  defp literal_terms({:%, _meta, [struct_ast, map_ast]}) do
    literal_terms(struct_ast) ++ literal_terms(map_ast)
  end

  defp literal_terms({:%{}, _meta, fields}) when is_list(fields), do: literal_terms(fields)
  defp literal_terms({:__aliases__, _meta, _parts}), do: []

  defp literal_terms({_form, meta, args}) when is_list(meta) and is_list(args),
    do: literal_terms(args)

  defp literal_terms({left, right}), do: literal_terms(left) ++ literal_terms(right)
  defp literal_terms(list) when is_list(list), do: Enum.flat_map(list, &literal_terms/1)
  defp literal_terms(_node), do: []

  defp arg_literal_terms(call, args, terms) do
    args
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {arg, position} ->
      arg
      |> direct_literal_terms()
      |> Enum.flat_map(&argument_literal_terms(call, position, &1))
    end)
    |> Kernel.++(terms)
  end

  defp direct_literal_terms(nil), do: ["atom:nil"]
  defp direct_literal_terms(true), do: ["atom:true"]
  defp direct_literal_terms(false), do: ["atom:false"]

  defp direct_literal_terms({:__block__, _meta, [literal]}), do: direct_literal_terms(literal)

  defp direct_literal_terms(integer) when is_integer(integer) and integer in -10..10,
    do: ["integer:#{integer}"]

  defp direct_literal_terms({:-, _meta, [literal]}) do
    case literal_integer(literal) do
      integer when integer in 1..10 -> ["integer:-#{integer}"]
      _other -> []
    end
  end

  defp direct_literal_terms({:__exograph_ident__, name}) when is_binary(name),
    do: ["atom:#{name}"]

  defp direct_literal_terms(_node), do: []

  defp argument_literal_terms(call, position, "atom:true") do
    ["call.arg:#{call}:#{position}:atom:true", "call.arg:#{call}:#{position}:atom:boolean"]
  end

  defp argument_literal_terms(call, position, "atom:false") do
    ["call.arg:#{call}:#{position}:atom:false", "call.arg:#{call}:#{position}:atom:boolean"]
  end

  defp argument_literal_terms(call, position, term), do: ["call.arg:#{call}:#{position}:#{term}"]

  defp pipe_rhs_equivalent_terms({{:., _dot_meta, [module_ast, fun]}, _meta, args})
       when is_list(args) do
    if literal_alias?(module_ast) and identifier?(fun) do
      module = alias_name(module_ast)
      fun = identifier_name(fun)
      arity = length(args) + 1

      ["call.remote:#{module}.#{fun}/#{arity}", "call.arity:#{arity}"]
    else
      []
    end
  end

  defp pipe_rhs_equivalent_terms({name, _meta, args}) when is_list(args) do
    if identifier?(name) and not synthetic_call?(name) do
      name = identifier_name(name)
      arity = length(args) + 1

      ["call.local:#{name}/#{arity}", "call.arity:#{arity}"]
    else
      []
    end
  end

  defp pipe_rhs_equivalent_terms({name, _meta, nil}) do
    if identifier?(name) and not synthetic_call?(name) do
      name = identifier_name(name)
      ["call.local:#{name}/1", "call.arity:1"]
    else
      []
    end
  end

  defp pipe_rhs_equivalent_terms(_right), do: []

  defp source_pipe_equivalent_remote_terms(:source, module, fun, arity) when arity > 0,
    do: ["call.remote:#{module}.#{fun}/#{arity - 1}", "call.arity:#{arity - 1}"]

  defp source_pipe_equivalent_remote_terms(_mode, _module, _fun, _arity), do: []

  defp source_pipe_equivalent_local_terms(:source, name, arity) when arity > 0,
    do: ["call.local:#{name}/#{arity - 1}", "call.arity:#{arity - 1}"]

  defp source_pipe_equivalent_local_terms(_mode, _name, _arity), do: []

  defp same_arg_terms("|>", _args, terms), do: terms

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

  defp function_head({name, _, nil}, mode) do
    if identifier?(name) and not pattern_capture_call?({name, [], nil}, mode),
      do: {:ok, identifier_name(name), 0},
      else: :unknown
  end

  defp function_head({name, _, args}, mode) when is_list(args) do
    if identifier?(name) and not pattern_capture_call?({name, [], args}, mode),
      do: {:ok, identifier_name(name), length(args)},
      else: :unknown
  end

  defp function_head(_head, _mode), do: :unknown

  defp pattern_capture_call?({name, _meta, nil}, :pattern),
    do: capture_identifier?(name)

  defp pattern_capture_call?({name, _meta, args}, :pattern) when is_list(args),
    do: capture_identifier?(name)

  defp pattern_capture_call?({_name, _meta, _args}, :pattern), do: false
  defp pattern_capture_call?(_node, _mode), do: false

  defp literal_alias?({:__aliases__, _, parts}), do: Enum.all?(parts, &identifier?/1)
  defp literal_alias?(_ast), do: false

  defp alias_name({:__aliases__, _, parts}),
    do: parts |> Enum.map(&identifier_name/1) |> Enum.join(".")

  defp identifier?(name), do: is_atom(name) or Ident.ident?(name)

  defp identifier_name(name) when is_atom(name), do: Atom.to_string(name)
  defp identifier_name(name), do: Ident.name(name)

  defp visibility(:defp), do: :private
  defp visibility(:defmacrop), do: :private
  defp visibility(_form), do: :public

  defp literal_integer({:__block__, _meta, [integer]}) when is_integer(integer), do: integer
  defp literal_integer(integer) when is_integer(integer), do: integer
  defp literal_integer(_other), do: nil

  defp synthetic_call?(name) when is_atom(name), do: name in [:__aliases__, :__block__, :..., :_]
  defp synthetic_call?(_name), do: false

  defp capture_identifier?(name) when is_atom(name), do: capture_name?(name)
  defp capture_identifier?(name), do: Ident.ident?(name) and capture_name?(Ident.name(name))

  defp capture_name?(:_), do: true
  defp capture_name?("_"), do: true

  defp capture_name?(name) when is_atom(name) do
    name
    |> Atom.to_string()
    |> String.starts_with?("_")
  end

  defp capture_name?(name) when is_binary(name), do: String.starts_with?(name, "_")

  defp to_quoted(pattern) when is_binary(pattern), do: Code.string_to_quoted!(pattern)
  defp to_quoted(pattern), do: pattern
end
