defmodule ExAST.Pattern do
  alias ExAST.CompiledPattern
  alias ExAST.Ident
  alias ExAST.Index.Terms

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
    match?({:__block__, _, [_, _ | _]}, to_quoted(pattern))
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
    match_compiled(node, compile(pattern), alias_env)
  end

  @doc """
  Compiles a pattern into reusable matching metadata.

  Most callers should prefer the higher-level search and patching APIs. Use this
  when matching the same pattern repeatedly and passing it to functions that
  accept compiled patterns.

  Since v0.12.0 this returns `%ExAST.CompiledPattern{}`. If you need the
  normalized pattern AST returned by earlier versions, use `compile_ast/1`.
  """
  @spec compile(pattern() | ExAST.CompiledPattern.t()) :: ExAST.CompiledPattern.t()
  def compile(%CompiledPattern{} = compiled), do: compiled

  def compile(pattern) do
    ast = compile_ast(pattern)

    CompiledPattern.new(
      ast: ast,
      original: pattern,
      signature: candidate_signature(ast),
      terms: Terms.from_pattern(pattern),
      multi_node?: multi_node?(pattern),
      broad?: broad?(ast)
    )
  end

  @doc """
  Returns the normalized AST for a pattern.

  This preserves the pre-v0.12.0 `compile/1` return shape for callers that need
  to inspect or reuse the normalized pattern AST directly.
  """
  @spec compile_ast(pattern() | ExAST.CompiledPattern.t()) :: Macro.t()
  def compile_ast(%CompiledPattern{ast: ast}), do: ast
  def compile_ast(pattern), do: pattern |> to_quoted() |> normalize()

  @doc false
  @spec match_compiled(Macro.t(), ExAST.CompiledPattern.t() | Macro.t(), %{
          optional(atom()) => [atom()]
        }) ::
          {:ok, captures()} | :error
  def match_compiled(node, %CompiledPattern{ast: ast}, alias_env) do
    match_compiled(node, ast, alias_env)
  end

  def match_compiled(node, compiled_pattern, alias_env) do
    node
    |> normalize_node(alias_env)
    |> match_normalized(compiled_pattern)
  end

  @doc false
  @spec normalize_node(Macro.t(), %{optional(atom()) => [atom()]}) :: Macro.t()
  def normalize_node(node, alias_env) do
    normalize(node, alias_env)
  end

  @doc false
  @spec match_normalized(Macro.t(), Macro.t()) :: {:ok, captures()} | :error
  def match_normalized(normalized_node, compiled_pattern) do
    do_match(normalized_node, compiled_pattern, %{})
  end

  @doc false
  @spec candidate_signature(ExAST.CompiledPattern.t() | Macro.t()) :: term()
  def candidate_signature(%CompiledPattern{signature: signature}), do: signature
  def candidate_signature(compiled_pattern), do: signature(compiled_pattern)

  @doc false
  @spec candidate?(Macro.t(), ExAST.CompiledPattern.t() | Macro.t() | term()) :: boolean()
  def candidate?(node, %CompiledPattern{signature: signature}),
    do: candidate?(node, signature)

  def candidate?(node, {:call, name, arities}), do: call_candidate?(node, name, arities)

  def candidate?(node, {:contains_call, name, arities}),
    do: contains_call_candidate?(node, name, arities)

  def candidate?(_node, :unknown), do: true

  def candidate?(node, compiled_pattern) do
    candidate?(node, candidate_signature(compiled_pattern))
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
    match_compiled(node, compile(pattern_ast), alias_env)
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
    normalized_nodes = Enum.map(nodes, &normalize(&1, alias_env))
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

  defp to_quoted(%CompiledPattern{ast: ast}), do: ast
  defp to_quoted(pattern) when is_binary(pattern), do: Code.string_to_quoted!(pattern)
  defp to_quoted(pattern), do: pattern

  # --- Normalization ---

  @doc false
  @spec normalize(Macro.t()) :: Macro.t()
  def normalize({:__block__, _meta, [inner]}), do: normalize(inner)

  def normalize({:|>, _meta, [left, {form, meta2, args}]}) when is_list(args),
    do: normalize({form, meta2, [left | args]})

  def normalize({:|>, _meta, [left, {form, meta2, nil}]}),
    do: normalize({form, meta2, [left]})

  def normalize({form, _meta, context}) when is_atom(form) and is_atom(context),
    do: {form, nil, nil}

  def normalize({form, _meta, args}) when is_atom(form),
    do: {form, nil, normalize(args)}

  def normalize({form, _meta, args}),
    do: {normalize(form), nil, normalize(args)}

  # Genuine 2-tuple literal: fold into the variadic `{:{}, _, [a, b]}` form so
  # every arity flows through one path. Map/keyword entries are also `{k, v}`
  # 2-tuples, but they arrive as list elements and are preserved by
  # `normalize_entry/1` — only standalone tuples reach here.
  def normalize({left, right}),
    do: {:{}, nil, [normalize(left), normalize(right)]}

  def normalize(list) when is_list(list),
    do: Enum.map(list, &normalize_entry/1)

  def normalize(other), do: other

  defp normalize_entry({key, value}), do: {normalize(key), normalize(value)}
  defp normalize_entry(node), do: normalize(node)

  # Sourceror encodes a genuine 2-tuple literal as `{:__block__, _, [{a, b}]}`
  # (the extra block carries metadata a bare 2-tuple has no slot for). Fold it
  # into the variadic `{:{}, _, [a, b]}` form so all tuple arities share one
  # path. Bare `{k, v}` 2-tuples are map/keyword entries and stay untouched.
  defp normalize({:__block__, _meta, [{a, b}]}, alias_env),
    do: {:{}, nil, [normalize(a, alias_env), normalize(b, alias_env)]}

  defp normalize({:__block__, _meta, [inner]}, alias_env), do: normalize(inner, alias_env)

  defp normalize({:|>, _meta, [left, {form, meta2, args}]}, alias_env) when is_list(args),
    do: normalize({form, meta2, [left | args]}, alias_env)

  defp normalize({:|>, _meta, [left, {form, meta2, nil}]}, alias_env),
    do: normalize({form, meta2, [left]}, alias_env)

  defp normalize({:__aliases__, meta, [name]} = node, alias_env) when is_atom(name) do
    {:__aliases__, _meta, parts} = expand_alias_node(node, meta, name, alias_env)
    {:__aliases__, nil, parts}
  end

  defp normalize({form, _meta, context}, _alias_env) when is_atom(form) and is_atom(context),
    do: {form, nil, nil}

  defp normalize({form, _meta, args}, alias_env) when is_atom(form) and is_list(args) do
    if import_expandable_call?(form) do
      case imported_module(alias_env, form, length(args)) do
        nil -> {form, nil, normalize(args, alias_env)}
        parts -> {{:., nil, [{:__aliases__, nil, parts}, form]}, nil, normalize(args, alias_env)}
      end
    else
      {form, nil, normalize(args, alias_env)}
    end
  end

  defp normalize({form, _meta, args}, alias_env) when is_atom(form),
    do: {form, nil, normalize(args, alias_env)}

  defp normalize({form, _meta, args}, alias_env),
    do: {normalize(form, alias_env), nil, normalize(args, alias_env)}

  defp normalize({left, right}, alias_env),
    do: {normalize(left, alias_env), normalize(right, alias_env)}

  defp normalize(list, alias_env) when is_list(list),
    do: Enum.map(list, &normalize(&1, alias_env))

  defp normalize(other, _alias_env), do: other

  @imports_key {__MODULE__, :imports}
  @locals_key {__MODULE__, :locals}
  @scope_key {__MODULE__, :scope}

  @doc false
  def collect_aliases(ast, opts \\ []) do
    {_ast, {aliases, _stack, locals}} =
      Macro.traverse(ast, {%{}, [], %{}}, &collect_pre/2, &collect_post/2)

    if Keyword.get(opts, :expand_imports, false) do
      expand_imports(aliases, locals)
    else
      aliases
    end
  end

  # Track the enclosing module path so imports/locals stay scoped per module.
  defp collect_pre({:defmodule, _, [name | _]} = node, {aliases, stack, locals}) do
    {node, {aliases, [module_parts(name) | stack], locals}}
  end

  defp collect_pre({:alias, _, args} = node, {aliases, stack, locals}) when is_list(args) do
    {node, {collect_alias_directive(args, aliases), stack, locals}}
  end

  defp collect_pre({:import, _, args} = node, {aliases, stack, locals}) when is_list(args) do
    {node, {collect_import_directive(args, aliases, current_path(stack)), stack, locals}}
  end

  defp collect_pre({kind, _, [head | _]} = node, {aliases, stack, locals})
       when kind in [:def, :defp, :defmacro, :defmacrop] do
    {node, {aliases, stack, add_local(locals, current_path(stack), head)}}
  end

  defp collect_pre(node, acc), do: {node, acc}

  defp collect_post({:defmodule, _, _} = node, {aliases, [_ | stack], locals}) do
    {node, {aliases, stack, locals}}
  end

  defp collect_post(node, acc), do: {node, acc}

  defp module_parts({:__aliases__, _, parts}) when is_list(parts),
    do: Enum.filter(parts, &is_atom/1)

  defp module_parts(_other), do: []

  defp current_path(stack), do: stack |> Enum.reverse() |> List.flatten()

  defp add_local(locals, path, head) do
    Map.update(locals, path, add_definition(MapSet.new(), head), &add_definition(&1, head))
  end

  # Resolve membership from the module's real exports. Local shadowing is left
  # to match time since it depends on the call site, not the import.
  defp expand_imports(aliases, locals) do
    imports = Map.get(aliases, @imports_key, [])

    if Enum.any?(imports, fn {_path, _parts, only} -> resolvable?(only) end) do
      aliases
      |> Map.put(@imports_key, Enum.map(imports, &resolve_import/1))
      |> Map.put(@locals_key, locals)
    else
      aliases
    end
  end

  defp resolvable?(:all), do: true
  defp resolvable?(:functions), do: true
  defp resolvable?(:macros), do: true
  defp resolvable?({:except, _}), do: true
  defp resolvable?(_other), do: false

  defp resolve_import({path, parts, only}) do
    if resolvable?(only) do
      {path, parts, resolve_only(parts, only)}
    else
      {path, parts, only}
    end
  end

  defp resolve_only(parts, {:except, except}),
    do: resolve_exports(parts, :all, MapSet.new(except))

  defp resolve_only(parts, kind), do: resolve_exports(parts, kind, MapSet.new())

  # Exports of the requested kind, minus `:except` names. Not loadable -> `:all`.
  defp resolve_exports(parts, kind, excluded) do
    mod = Module.concat(parts)

    if Code.ensure_loaded?(mod) do
      mod
      |> module_exports(kind)
      |> Enum.reject(&MapSet.member?(excluded, &1))
    else
      :all
    end
  rescue
    _ -> :all
  end

  defp module_exports(mod, :functions), do: mod.__info__(:functions)
  defp module_exports(mod, :macros), do: mod.__info__(:macros)
  defp module_exports(mod, :all), do: mod.__info__(:functions) ++ mod.__info__(:macros)

  defp add_definition(acc, {:when, _, [call | _]}), do: add_definition(acc, call)

  defp add_definition(acc, {name, _, args}) when is_atom(name) and is_list(args),
    do: MapSet.put(acc, {name, length(args)})

  defp add_definition(acc, {name, _, _}) when is_atom(name),
    do: MapSet.put(acc, {name, 0})

  defp add_definition(acc, _other), do: acc

  defp collect_import_directive([{:__aliases__, _, parts}], acc, path) when is_list(parts) do
    put_import(acc, path, parts, :all)
  end

  defp collect_import_directive([{:__aliases__, _, parts}, opts], acc, path)
       when is_list(parts) do
    put_import(acc, path, parts, import_only(opts))
  end

  defp collect_import_directive(_args, acc, _path), do: acc

  defp import_only(opts) do
    case opt_value(opts, :only) do
      nil -> import_except(opts)
      only_ast -> only_kind(only_ast)
    end
  end

  # Keep `:functions` / `:macros` so expansion resolves against just that kind.
  defp only_kind(ast) do
    case unwrap_block(ast) do
      :functions -> :functions
      :macros -> :macros
      _other -> parse_only_list(ast)
    end
  end

  # `except:` stays unresolved until `expand_imports/2`; it needs the full export list.
  defp import_except(opts) do
    case opt_value(opts, :except) do
      nil ->
        :all

      except_ast ->
        case parse_only_list(except_ast) do
          list when is_list(list) -> {:except, list}
          _ -> :all
        end
    end
  end

  defp opt_value(opts, key) do
    Enum.find_value(opts, fn
      {{:__block__, _, [^key]}, value} -> value
      {^key, value} -> value
      _other -> nil
    end)
  end

  defp parse_only_list(ast) do
    case unwrap_block(ast) do
      list when is_list(list) -> Enum.flat_map(list, &parse_only_entry/1)
      _other -> :all
    end
  end

  defp parse_only_entry({name_ast, arity_ast}) do
    case {unwrap_block(name_ast), unwrap_block(arity_ast)} do
      {name, arity} when is_atom(name) and is_integer(arity) -> [{name, arity}]
      _ -> []
    end
  end

  defp parse_only_entry(_other), do: []

  defp unwrap_block({:__block__, _, [inner]}), do: inner
  defp unwrap_block(other), do: other

  defp put_import(acc, path, parts, only) do
    imports = Map.get(acc, @imports_key, [])
    Map.put(acc, @imports_key, [{path, parts, only} | imports])
  end

  @doc false
  @spec imports?(%{optional(term()) => term()}) :: boolean()
  def imports?(alias_env), do: Map.has_key?(alias_env, @imports_key)

  @doc false
  @spec scope_alias_env(%{optional(term()) => term()}, [atom()]) :: %{optional(term()) => term()}
  def scope_alias_env(alias_env, module_path) do
    Map.put(alias_env, @scope_key, module_path)
  end

  @doc false
  @spec module_path([Macro.t()]) :: [atom()]
  def module_path(ancestors) do
    ancestors
    |> Enum.reverse()
    |> Enum.flat_map(fn
      {:defmodule, _, [name | _]} -> module_parts(name)
      _other -> []
    end)
  end

  defp imported_module(alias_env, name, arity) do
    scope = Map.get(alias_env, @scope_key, :all)

    if not locally_shadowed?(alias_env, scope, name, arity) do
      alias_env
      |> Map.get(@imports_key, [])
      |> Enum.find_value(&matching_import(&1, scope, name, arity))
    end
  end

  defp matching_import({path, parts, only}, scope, name, arity) do
    if in_scope?(scope, path) and import_matches?(only, name, arity), do: parts
  end

  # A local def in the call site's own module shadows the import.
  defp locally_shadowed?(_alias_env, :all, _name, _arity), do: false

  defp locally_shadowed?(alias_env, scope, name, arity) do
    alias_env
    |> Map.get(@locals_key, %{})
    |> Map.get(scope, MapSet.new())
    |> MapSet.member?({name, arity})
  end

  # `:all` (low-level `match/3`) is file-global; a module path scopes to descendants.
  defp in_scope?(:all, _path), do: true
  defp in_scope?(module_path, path), do: List.starts_with?(module_path, path)

  # An unresolved `:all` import (bare, unexpanded) has no membership, so it never matches.
  defp import_matches?(:all, _name, _arity), do: false
  defp import_matches?(only, name, arity) when is_list(only), do: {name, arity} in only
  defp import_matches?(_only, _name, _arity), do: false

  defp import_expandable_call?(form) do
    form not in [
      :alias,
      :import,
      :require,
      :use,
      :def,
      :defp,
      :defmodule,
      :defmacro,
      :defmacrop,
      :fn,
      :case,
      :cond,
      :with,
      :if,
      :unless,
      :try,
      :receive,
      :for
    ]
  end

  defp collect_alias_directive([target], acc), do: register_alias_target(acc, target)

  defp collect_alias_directive([target, opts], acc) when is_list(opts) do
    case alias_as(opts) do
      nil -> register_alias_target(acc, target)
      as_alias -> put_alias(acc, as_alias, target)
    end
  end

  defp collect_alias_directive(args, acc) when is_list(args) do
    Enum.reduce(args, acc, fn target, aliases ->
      register_alias_target(aliases, target)
    end)
  end

  defp alias_as(opts) do
    Enum.find_value(opts, fn
      {:as, as_alias} -> as_alias
      {{:__block__, _, [:as]}, as_alias} -> as_alias
      _other -> nil
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

  defp expand_alias_node(node, meta, name, alias_env) do
    case Map.fetch(alias_env, name) do
      {:ok, parts} -> {:__aliases__, meta, parts}
      :error -> node
    end
  end

  # --- Candidate prefiltering ---

  defp broad?({:_, _meta, nil}), do: true

  defp broad?({:__ex_ast_any_patterns__, patterns}) when is_list(patterns),
    do: Enum.any?(patterns, &broad?/1)

  defp broad?(_pattern), do: false

  defp signature({{:., nil, [_target, name]}, nil, args}) when is_atom(name) and is_list(args),
    do: {:call, name, arity_signature(args)}

  # Tuples (`{:{}, _, _}`) can't be prefiltered by call name: 2-tuples keep their
  # literal `{a, b}` shape at the source, so a `:{}` filter would drop them. And
  # `...` is a matcher directive, not a callable — treating it as a call
  # (`{:contains_call, :..., 0}`) wrongly filters out candidates.
  defp signature({head, nil, _args}) when head in [:{}, :...], do: :unknown

  defp signature({name, nil, args}) when is_atom(name) and is_list(args),
    do: {:call, name, arity_signature(args)}

  defp signature(pattern) do
    case nested_call_signature(pattern) do
      {:call, name, arities} -> {:contains_call, name, arities}
      :unknown -> :unknown
    end
  end

  defp nested_call_signature({:..., _meta, _args}), do: :unknown

  defp nested_call_signature({{:., nil, [_target, name]}, nil, args})
       when is_atom(name) and is_list(args),
       do: {:call, name, arity_signature(args)}

  defp nested_call_signature({head, _meta, _args}) when head in [:{}, :...], do: :unknown

  defp nested_call_signature({name, nil, args}) when is_atom(name) and is_list(args),
    do: {:call, name, arity_signature(args)}

  defp nested_call_signature({form, _meta, args}) when is_list(args) do
    nested_call_signature(form, args)
  end

  defp nested_call_signature({left, right}) do
    first_signature([left, right])
  end

  defp nested_call_signature(list) when is_list(list), do: first_signature(list)
  defp nested_call_signature(_pattern), do: :unknown

  defp nested_call_signature(form, args) do
    case nested_call_signature(form) do
      :unknown -> first_signature(args)
      signature -> signature
    end
  end

  defp first_signature(nodes) do
    Enum.find_value(nodes, :unknown, fn node ->
      case nested_call_signature(node) do
        :unknown -> nil
        signature -> signature
      end
    end)
  end

  defp arity_signature(args) do
    if Enum.any?(args, &ellipsis?/1) do
      :any
    else
      length(args)
    end
  end

  defp call_candidate?({:|>, _, [_left, {{:., _, [_target, call_name]}, _, args}]}, name, arities)
       when is_list(args),
       do: Ident.equal?(call_name, name) and arity_candidate?(length(args) + 1, arities)

  defp call_candidate?({:|>, _, [_left, {call_name, _, args}]}, name, arities)
       when is_list(args),
       do: Ident.equal?(call_name, name) and arity_candidate?(length(args) + 1, arities)

  defp call_candidate?({{:., _, [_target, call_name]}, _, args}, name, arities)
       when is_list(args),
       do: Ident.equal?(call_name, name) and arity_candidate?(length(args), arities)

  defp call_candidate?({call_name, _, args}, name, arities)
       when is_list(args),
       do: Ident.equal?(call_name, name) and arity_candidate?(length(args), arities)

  defp call_candidate?(_node, _name, _arities), do: false

  defp contains_call_candidate?(node, name, arities) do
    call_candidate?(node, name, arities) or
      node
      |> raw_children()
      |> Enum.any?(&contains_call_candidate?(&1, name, arities))
  end

  defp raw_children({:__block__, _meta, children}) when is_list(children), do: children
  defp raw_children({_form, _meta, args}) when is_list(args), do: args
  defp raw_children({left, right}), do: [left, right]
  defp raw_children(list) when is_list(list), do: list
  defp raw_children(_node), do: []

  defp arity_candidate?(_arity, :any), do: true
  defp arity_candidate?(arity, arity), do: true
  defp arity_candidate?(_arity, _expected), do: false

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

  # Directives: capture imported/aliased module names as a single node.
  defp do_match({directive, nil, [source]}, {directive, nil, [{pname, nil, nil}]}, caps)
       when directive in [:alias, :import] and is_atom(pname) do
    bind(pname, source, caps)
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

  # Module attribute: @name(expr) — attribute name is captureable
  defp do_match(
         {:@, nil, [{sname, nil, sargs}]},
         {:@, nil, [{pname, nil, pargs}]},
         caps
       ) do
    with {:ok, caps} <- match_attr_name(sname, pname, caps) do
      do_match(sargs, pargs, caps)
    end
  end

  # 3-tuple with same/equivalent head. Tagged source identifiers compare to
  # pattern atoms by string without interning source names.
  defp do_match({shead, nil, schild}, {phead, nil, pchild}, caps)
       when is_atom(phead) do
    cond do
      Ident.equal?(shead, phead) ->
        do_match(schild, pchild, caps)

      wildcard_name?(phead) ->
        do_match(schild, pchild, caps)

      is_atom(shead) ->
        :error

      true ->
        :error
    end
  end

  # 3-tuple with different heads (non-atom)
  defp do_match({shead, nil, schild}, {phead, nil, pchild}, caps) do
    with {:ok, caps} <- do_match(shead, phead, caps) do
      do_match(schild, pchild, caps)
    end
  end

  # Bare 2-tuple pattern vs a folded 2-element source tuple. A genuine 2-tuple
  # in a list is indistinguishable from a keyword entry at parse time, so the
  # pattern side keeps it bare while the source side folds it to the variadic
  # `{:{}, _, [a, b]}` form. Bridge the two shapes here.
  defp do_match({:{}, nil, [sa, sb]}, {pa, pb}, caps) do
    with {:ok, caps} <- do_match(sa, pa, caps) do
      do_match(sb, pb, caps)
    end
  end

  # Reverse of the above: a quoted source keeps a genuine 2-tuple bare, while a
  # standalone pattern tuple folds to `{:{}, _, [a, b]}`. Bridge that shape too.
  defp do_match({sa, sb}, {:{}, nil, [pa, pb]}, caps) do
    with {:ok, caps} <- do_match(sa, pa, caps) do
      do_match(sb, pb, caps)
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

  defp do_match(source, pattern, caps) when is_atom(pattern) do
    if Ident.equal?(source, pattern), do: {:ok, caps}, else: :error
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

  defp wildcard_name?(name) when is_atom(name) do
    case Atom.to_string(name) do
      "_" -> true
      "_" <> _ -> true
      _ -> false
    end
  end

  defp bind(name, node, captures) do
    case Map.fetch(captures, name) do
      {:ok, ^node} -> {:ok, captures}
      {:ok, _different} -> :error
      :error -> {:ok, Map.put(captures, name, node)}
    end
  end

  defp match_attr_name(_name, {:_, nil, nil}, caps), do: {:ok, caps}

  defp match_attr_name(name, pname, caps) when is_atom(pname) do
    cond do
      wildcard_name?(pname) ->
        {:ok, caps}

      Ident.ident?(name) ->
        if Ident.equal?(name, pname), do: {:ok, caps}, else: :error

      true ->
        bind(pname, name, caps)
    end
  end

  defp match_attr_name(name, name, caps), do: {:ok, caps}
  defp match_attr_name(_, _, _), do: :error

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
      {k, v} -> if Ident.equal?(k, key), do: {:ok, v}, else: nil
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
