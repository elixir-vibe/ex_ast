defmodule ExAST.Diff.Normalize do
  @moduledoc false

  @spec for_equivalence(Macro.t()) :: Macro.t()
  def for_equivalence(ast), do: normalize(ast)

  @spec signature(Macro.t()) :: {atom(), term(), Macro.t()}
  def signature(ast), do: {kind(ast), label(ast), for_identity(ast)}

  @spec kind(Macro.t()) :: atom()
  def kind({:defmodule, _, _}), do: :module
  def kind({k, _, _}) when k in [:def, :defp], do: :function
  def kind({:when, _, _}), do: :guard
  def kind({:case, _, _}), do: :case
  def kind({:cond, _, _}), do: :cond
  def kind({:with, _, _}), do: :with
  def kind({:fn, _, _}), do: :fn
  def kind({:%{}, _, _}), do: :map
  def kind({:%, _, _}), do: :struct
  def kind({:__block__, _, _}), do: :block
  def kind({:|>, _, _}), do: :pipeline
  def kind({:=, _, _}), do: :assignment
  def kind({{:., _, _}, _, _}), do: :remote_call
  def kind({name, _, args}) when is_atom(name) and is_list(args), do: :call
  def kind({l, r}) when is_tuple(l) or is_tuple(r), do: :tuple

  def kind(list) when is_list(list) do
    if Keyword.keyword?(list), do: :keyword, else: :list
  end

  def kind(a) when is_atom(a), do: :atom
  def kind(b) when is_binary(b), do: :string
  def kind(n) when is_number(n), do: :number
  def kind(_), do: :literal

  @spec label(Macro.t()) :: term()
  def label({:defmodule, _, [{:__aliases__, _, parts}, _]}), do: {:module, parts}

  def label({k, _, [{name, _, args}, _]}) when k in [:def, :defp] and is_atom(name),
    do: {k, name, length(args || [])}

  def label({k, _, [{:when, _, [{name, _, args} | _]}, _]})
      when k in [:def, :defp] and is_atom(name),
      do: {k, name, length(args || [])}

  def label({{:., _, [target, fun]}, _, args}),
    do: {:remote_call, alias_parts(target), fun, length(args || [])}

  def label({name, _, args}) when is_atom(name) and is_list(args),
    do: {:call, name, length(args)}

  def label({:%, _, [name, _]}), do: {:struct, alias_parts(name)}

  def label({:%{}, _, kvs}) when is_list(kvs),
    do: {:map, Enum.map(kvs, &elem(&1, 0))}

  def label(list) when is_list(list) do
    if Keyword.keyword?(list), do: {:keyword, Keyword.keys(list)}, else: :list
  end

  def label({:|>, _, _}), do: :pipeline
  def label(other), do: kind(other)

  # --- Private ---

  defp for_identity(ast) do
    ast |> normalize() |> strip_literals()
  end

  defp alias_parts({:__aliases__, _, parts}), do: parts
  defp alias_parts(other), do: other

  defp normalize({:__block__, _meta, [inner]}), do: normalize(inner)

  defp normalize({:|>, _m, [left, {form, m2, args}]}) when is_list(args),
    do: normalize({form, m2, [left | args]})

  defp normalize({:|>, _m, [left, {form, m2, nil}]}), do: normalize({form, m2, [left]})
  defp normalize({form, _m, args}) when is_atom(form), do: {form, nil, normalize(args)}
  defp normalize({form, _m, args}), do: {normalize(form), nil, normalize(args)}
  defp normalize({left, right}), do: {normalize(left), normalize(right)}
  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(other), do: other

  defp strip_literals({form, meta, args}), do: {strip_literals(form), meta, strip_literals(args)}
  defp strip_literals({left, right}), do: {strip_literals(left), strip_literals(right)}
  defp strip_literals(list) when is_list(list), do: Enum.map(list, &strip_literals/1)
  defp strip_literals(a) when is_atom(a), do: a
  defp strip_literals(v) when is_binary(v) or is_number(v), do: :__literal__
  defp strip_literals(other), do: other
end
