defmodule ExAST.CLI.SelectorOptions do
  @moduledoc false

  alias ExAST.Selector

  @switches [
    parent: :string,
    not_parent: :string,
    ancestor: :string,
    not_ancestor: :string,
    inside: :string,
    not_inside: :string,
    has_child: :string,
    not_has_child: :string,
    has_descendant: :string,
    not_has_descendant: :string,
    has: :string,
    not_has: :string
  ]

  @negated_filters [
    :not_inside,
    :not_ancestor,
    :not_parent,
    :not_has_child,
    :not_has_descendant,
    :not_has
  ]

  def switches, do: @switches

  def pattern(pattern, opts, validate_filter!, ignored_opts \\ []) do
    if selector_filters?(opts, ignored_opts) do
      build_selector(pattern, opts, validate_filter!)
    else
      pattern
    end
  end

  def where_opts(opts, ignored_opts \\ []) do
    if selector_filters?(opts, ignored_opts),
      do: [],
      else: Keyword.take(opts, [:inside, :not_inside])
  end

  defp selector_filters?(opts, ignored_opts) do
    opts
    |> Keyword.drop([:inside, :not_inside] ++ ignored_opts)
    |> Keyword.take(Keyword.keys(@switches))
    |> Enum.any?()
  end

  defp build_selector(pattern, opts, validate_filter!) do
    selector = Selector.pattern(pattern)

    Enum.reduce(selector_filters(opts, validate_filter!), selector, fn {predicate, negated?},
                                                                       selector ->
      predicate = if negated?, do: Selector.not(predicate), else: predicate
      Selector.where_predicate(selector, predicate)
    end)
  end

  defp selector_filters(opts, validate_filter!) do
    opts
    |> Keyword.take(Keyword.keys(@switches))
    |> Enum.map(fn {key, pattern} ->
      validate_filter!.(pattern)
      {selector_predicate(key, pattern), key in @negated_filters}
    end)
  end

  defp selector_predicate(key, pattern)
       when key in [:inside, :ancestor, :not_inside, :not_ancestor],
       do: Selector.ancestor(pattern)

  defp selector_predicate(key, pattern)
       when key in [:has, :has_descendant, :not_has, :not_has_descendant],
       do: Selector.has_descendant(pattern)

  defp selector_predicate(key, pattern) when key in [:parent, :not_parent],
    do: Selector.parent(pattern)

  defp selector_predicate(key, pattern) when key in [:has_child, :not_has_child],
    do: Selector.has_child(pattern)
end
