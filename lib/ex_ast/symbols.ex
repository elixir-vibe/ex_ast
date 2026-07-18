defmodule ExAST.Symbols do
  @moduledoc """
  Extracts lightweight definition and reference facts from Elixir source or AST.
  """

  alias ExAST.Ident
  alias ExAST.Symbol.{Definition, Reference}

  @definition_forms [:def, :defp, :defmacro, :defmacrop]
  @callback_forms [:defcallback, :defmacrocallback]

  @type mfa_tuple :: {module(), atom(), non_neg_integer()}

  @type symbol_target ::
          String.t()
          | mfa_tuple()
          | {String.t() | nil, atom() | String.t(), non_neg_integer()}
          | Definition.t()
          | Reference.t()

  @doc """
  The `def`-family forms treated as function/macro definitions.
  """
  @spec definition_forms() :: [atom()]
  def definition_forms, do: @definition_forms

  @spec definitions(String.t() | Macro.t()) :: [Definition.t()]
  def definitions(source_or_ast) do
    source_or_ast
    |> to_ast()
    |> collect_definitions([])
  end

  @spec references(String.t() | Macro.t()) :: [Reference.t()]
  def references(source_or_ast) do
    {_ast, references} =
      source_or_ast
      |> to_ast()
      |> Macro.prewalk([], fn node, acc ->
        references = references_from_node(node)
        {node, references ++ acc}
      end)

    Enum.reverse(references)
  end

  @doc "Normalizes a symbol, MFA tuple, or qualified-name string to a qualified-name string."
  @spec qualified_name(symbol_target()) :: String.t()
  def qualified_name(%{qualified_name: qualified_name}) when is_binary(qualified_name),
    do: qualified_name

  def qualified_name(name) when is_binary(name), do: name
  def qualified_name({nil, name, arity}), do: qualified_name(nil, name, arity)

  def qualified_name({module, name, arity}) when is_atom(module),
    do: qualified_name(module_name(module), name, arity)

  def qualified_name({module, name, arity}) when is_binary(module),
    do: qualified_name(module, name, arity)

  @doc "Returns an MFA tuple when the target has a resolvable BEAM module."
  @spec mfa(symbol_target()) :: mfa_tuple() | nil
  def mfa(%{mfa: mfa}) when is_tuple(mfa), do: mfa
  def mfa(%{module: module, name: name, arity: arity}), do: mfa(module, name, arity)

  def mfa({module, name, arity})
      when is_atom(module) and not is_nil(module) and is_atom(name) and is_integer(arity),
      do: {module, name, arity}

  def mfa({module, name, arity}), do: mfa(module, name, arity)
  def mfa(name) when is_binary(name), do: name |> parse_qualified_name() |> mfa()
  def mfa(nil), do: nil

  @doc "Returns true when a symbol matches a qualified-name string or MFA tuple."
  @spec matches?(Definition.t() | Reference.t(), symbol_target()) :: boolean()
  def matches?(%{qualified_name: qualified_name}, target),
    do: qualified_name == qualified_name(target)

  defp collect_definitions(list, modules) when is_list(list) do
    Enum.flat_map(list, &collect_definitions(&1, modules))
  end

  defp collect_definitions({:__block__, _meta, expressions}, modules) do
    collect_definitions(expressions, modules)
  end

  defp collect_definitions({:defmodule, _meta, [_module_ast, [do: body]]} = node, modules) do
    case definition_from_node(node, modules) do
      {:module, definition, module_name} ->
        [definition | collect_definitions(body, [module_name | modules])]

      :none ->
        collect_definitions(body, modules)
    end
  end

  defp collect_definitions({:defmodule, _meta, [_module_ast, body]} = node, modules) do
    case definition_from_node(node, modules) do
      {:module, definition, module_name} ->
        [definition | collect_definitions(body, [module_name | modules])]

      :none ->
        collect_definitions(body, modules)
    end
  end

  defp collect_definitions(node, modules) when is_tuple(node) do
    own =
      case definition_from_node(node, modules) do
        {:definition, definition} -> [definition]
        _other -> []
      end

    children = node |> Tuple.to_list() |> collect_definitions(modules)
    own ++ children
  end

  defp collect_definitions(_node, _modules), do: []

  defp definition_from_node({:defmodule, meta, [module_ast, _body]} = node, _modules) do
    case alias_name(module_ast) do
      {:ok, name} ->
        definition = %Definition{
          kind: :module,
          module: name,
          name: name,
          arity: nil,
          qualified_name: name,
          mfa: nil,
          visibility: :public,
          line: meta[:line],
          column: meta[:column],
          node: node
        }

        {:module, definition, name}

      :error ->
        :none
    end
  end

  defp definition_from_node({form, meta, [head | _rest]} = node, modules)
       when form in @definition_forms do
    case function_head(head) do
      {:ok, name, arity} ->
        module = List.first(modules)

        {:definition,
         %Definition{
           kind: form,
           module: module,
           name: identifier_name(name),
           arity: arity,
           qualified_name: qualified_name(module, name, arity),
           mfa: mfa(module, name, arity),
           visibility: visibility(form),
           line: meta[:line],
           column: meta[:column],
           node: node
         }}

      :unknown ->
        :none
    end
  end

  defp definition_from_node({form, meta, [head | _rest]} = node, modules)
       when form in @callback_forms do
    callback_definition(node, meta, modules, form, head)
  end

  defp definition_from_node({:defdelegate, meta, [head | _rest]} = node, modules) do
    case function_head(head) do
      {:ok, name, arity} ->
        module = List.first(modules)

        {:definition,
         %Definition{
           kind: :defdelegate,
           module: module,
           name: identifier_name(name),
           arity: arity,
           qualified_name: qualified_name(module, name, arity),
           mfa: mfa(module, name, arity),
           visibility: :public,
           line: meta[:line],
           column: meta[:column],
           node: node
         }}

      :unknown ->
        :none
    end
  end

  defp definition_from_node({:@, meta, [{:callback, _, [head]}]} = node, modules) do
    callback_definition(node, meta, modules, :defcallback, head)
  end

  defp definition_from_node({:@, meta, [{:macrocallback, _, [head]}]} = node, modules) do
    callback_definition(node, meta, modules, :defmacrocallback, head)
  end

  defp definition_from_node({:@, meta, [{name, _, _args}]} = node, modules) do
    if identifier?(name) do
      module = List.first(modules)

      {:definition,
       %Definition{
         kind: :attribute,
         module: module,
         name: identifier_name(name),
         arity: nil,
         qualified_name: attribute_name(module, name),
         mfa: nil,
         visibility: nil,
         line: meta[:line],
         column: meta[:column],
         node: node
       }}
    else
      :none
    end
  end

  defp definition_from_node(_node, _modules), do: :none

  defp callback_definition(node, meta, modules, kind, head) do
    case callback_head(head) do
      {:ok, name, arity} ->
        module = List.first(modules)

        {:definition,
         %Definition{
           kind: kind,
           module: module,
           name: identifier_name(name),
           arity: arity,
           qualified_name: qualified_name(module, name, arity),
           mfa: mfa(module, name, arity),
           visibility: :public,
           line: meta[:line],
           column: meta[:column],
           node: node
         }}

      :unknown ->
        :none
    end
  end

  defp references_from_node({{:., meta, [module_ast, name]}, _call_meta, args} = node)
       when is_list(args) do
    if identifier?(name) do
      case alias_name(module_ast) do
        {:ok, module} ->
          arity = length(args)

          [
            %Reference{
              kind: :remote_call,
              module: module,
              name: identifier_name(name),
              arity: arity,
              qualified_name: qualified_name(module, name, arity),
              mfa: mfa(module, name, arity),
              line: meta[:line],
              column: meta[:column],
              node: node
            }
          ]

        :error ->
          []
      end
    else
      []
    end
  end

  defp references_from_node({:@, meta, [{name, _, _args}]} = node) do
    if identifier?(name) do
      name = identifier_name(name)

      [
        %Reference{
          kind: :module_attribute,
          module: nil,
          name: name,
          arity: nil,
          qualified_name: "@#{name}",
          mfa: nil,
          line: meta[:line],
          column: meta[:column],
          node: node
        }
      ]
    else
      []
    end
  end

  defp references_from_node({:__aliases__, meta, parts} = node) when is_list(parts) do
    if Enum.all?(parts, &identifier?/1) do
      name = Enum.map_join(parts, ".", &identifier_name/1)

      [
        %Reference{
          kind: :alias,
          module: name,
          name: name,
          arity: nil,
          qualified_name: name,
          mfa: nil,
          line: meta[:line],
          column: meta[:column],
          node: node
        }
      ]
    else
      []
    end
  end

  defp references_from_node({name, meta, args} = node) when is_list(args) do
    if identifier?(name) and not synthetic_call?(name) do
      arity = length(args)

      [
        %Reference{
          kind: :local_call,
          module: nil,
          name: identifier_name(name),
          arity: arity,
          qualified_name: qualified_name(nil, name, arity),
          mfa: nil,
          line: meta[:line],
          column: meta[:column],
          node: node
        }
      ]
    else
      []
    end
  end

  defp references_from_node(_node), do: []

  defp function_head({:when, _, [head | _guards]}), do: function_head(head)

  defp function_head({name, _, nil}) do
    if identifier?(name), do: {:ok, name, 0}, else: :unknown
  end

  defp function_head({name, _, args}) when is_list(args) do
    if identifier?(name), do: {:ok, name, length(args)}, else: :unknown
  end

  defp function_head(_head), do: :unknown

  defp callback_head({:"::", _, [{name, _, args}, _type]}) when is_list(args) do
    if identifier?(name), do: {:ok, name, length(args)}, else: :unknown
  end

  defp callback_head({name, _, args}) when is_list(args) do
    if identifier?(name), do: {:ok, name, length(args)}, else: :unknown
  end

  defp callback_head(_head), do: :unknown

  defp alias_name({:__aliases__, _, parts}) when is_list(parts) do
    if Enum.all?(parts, &identifier?/1),
      do: {:ok, Enum.map_join(parts, ".", &identifier_name/1)},
      else: :error
  end

  defp alias_name(atom) when is_atom(atom), do: {:ok, module_name(atom)}
  defp alias_name(ident), do: if(Ident.ident?(ident), do: {:ok, Ident.name(ident)}, else: :error)

  defp qualified_name(nil, name, arity), do: "#{identifier_name(name)}/#{arity}"
  defp qualified_name(module, name, arity), do: "#{module}.#{identifier_name(name)}/#{arity}"

  defp mfa(nil, _name, _arity), do: nil
  defp mfa(_module, _name, nil), do: nil

  defp mfa(module, name, arity) when is_binary(name) do
    case existing_atom(name) do
      nil -> nil
      name -> mfa(module, name, arity)
    end
  end

  defp mfa(module, name, arity) when is_atom(name) and is_integer(arity) do
    case existing_module(module) do
      nil -> nil
      module -> {module, name, arity}
    end
  end

  defp mfa(_module, _name, _arity), do: nil

  defp parse_qualified_name(name) do
    case Regex.run(~r/^(?:(.+)\.)?([^\.\/]+)\/(\d+)$/, name) do
      [_match, module, name, arity] -> {empty_to_nil(module), name, String.to_integer(arity)}
      nil -> nil
    end
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp existing_module(module) when is_atom(module), do: module

  defp existing_module(module) when is_binary(module) do
    ["Elixir.#{module}", module]
    |> Enum.find_value(fn candidate ->
      try do
        String.to_existing_atom(candidate)
      rescue
        ArgumentError -> nil
      end
    end)
  end

  defp existing_module(_module), do: nil

  defp existing_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp module_name(module) when is_atom(module) do
    module
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
  end

  defp attribute_name(nil, name), do: "@#{identifier_name(name)}"
  defp attribute_name(module, name), do: "#{module}.@#{identifier_name(name)}"

  defp identifier?(value), do: is_atom(value) or Ident.ident?(value)

  defp identifier_name(value) when is_atom(value), do: Atom.to_string(value)
  defp identifier_name(value), do: Ident.name(value)

  defp synthetic_call?(name) when is_atom(name) do
    name in [
      :__aliases__,
      :...,
      :_,
      :.,
      :@,
      :defmodule,
      :defdelegate,
      :def,
      :defp,
      :defmacro,
      :defmacrop,
      :defcallback,
      :defmacrocallback
    ]
  end

  defp synthetic_call?(_name), do: false

  defp visibility(:defp), do: :private
  defp visibility(:defmacrop), do: :private
  defp visibility(_form), do: :public

  defp to_ast(source) when is_binary(source), do: Sourceror.parse_string!(source)
  defp to_ast(ast), do: ast
end
