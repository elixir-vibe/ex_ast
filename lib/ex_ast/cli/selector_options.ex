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
    not_has: :string,
    contains: :string,
    not_contains: :string,
    follows: :string,
    not_follows: :string,
    precedes: :string,
    not_precedes: :string,
    immediately_follows: :string,
    not_immediately_follows: :string,
    immediately_precedes: :string,
    not_immediately_precedes: :string,
    first: :boolean,
    not_first: :boolean,
    last: :boolean,
    not_last: :boolean,
    nth: :integer,
    not_nth: :integer,
    comment: :string,
    not_comment: :string,
    comment_before: :string,
    not_comment_before: :string,
    comment_after: :string,
    not_comment_after: :string,
    comment_inside: :string,
    not_comment_inside: :string,
    comment_inline: :string,
    not_comment_inline: :string
  ]

  @negated_filters [
    :not_inside,
    :not_ancestor,
    :not_parent,
    :not_has_child,
    :not_has_descendant,
    :not_has,
    :not_contains,
    :not_follows,
    :not_precedes,
    :not_immediately_follows,
    :not_immediately_precedes,
    :not_first,
    :not_last,
    :not_nth,
    :not_comment,
    :not_comment_before,
    :not_comment_after,
    :not_comment_inside,
    :not_comment_inline
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
    |> Enum.map(fn {key, value} ->
      validate_filter_value!(key, value, validate_filter!)
      {selector_predicate(key, value), key in @negated_filters}
    end)
  end

  defp validate_filter_value!(key, pattern, validate_filter!) when is_binary(pattern) do
    if comment_filter?(key) do
      parse_comment_matcher!(pattern)
    else
      validate_filter!.(pattern)
    end
  end

  defp validate_filter_value!(key, value, _validate_filter!)
       when key in [:first, :not_first, :last, :not_last] and value in [true, false],
       do: :ok

  defp validate_filter_value!(key, value, _validate_filter!)
       when key in [:nth, :not_nth] and is_integer(value) and value > 0,
       do: :ok

  defp validate_filter_value!(key, value, _validate_filter!) do
    raise ArgumentError,
          "invalid value for #{String.replace(to_string(key), "_", "-")}: #{inspect(value)}"
  end

  defp selector_predicate(key, pattern)
       when key in [:inside, :ancestor, :not_inside, :not_ancestor],
       do: Selector.ancestor(pattern)

  defp selector_predicate(key, pattern)
       when key in [
              :has,
              :has_descendant,
              :contains,
              :not_has,
              :not_has_descendant,
              :not_contains
            ],
       do: Selector.has_descendant(pattern)

  defp selector_predicate(key, pattern) when key in [:parent, :not_parent],
    do: Selector.parent(pattern)

  defp selector_predicate(key, pattern) when key in [:has_child, :not_has_child],
    do: Selector.has_child(pattern)

  defp selector_predicate(key, pattern) when key in [:follows, :not_follows],
    do: Selector.follows(pattern)

  defp selector_predicate(key, pattern) when key in [:precedes, :not_precedes],
    do: Selector.precedes(pattern)

  defp selector_predicate(key, pattern)
       when key in [:immediately_follows, :not_immediately_follows],
       do: Selector.immediately_follows(pattern)

  defp selector_predicate(key, pattern)
       when key in [:immediately_precedes, :not_immediately_precedes],
       do: Selector.immediately_precedes(pattern)

  defp selector_predicate(key, true) when key in [:first, :not_first], do: Selector.first()
  defp selector_predicate(key, true) when key in [:last, :not_last], do: Selector.last()
  defp selector_predicate(key, index) when key in [:nth, :not_nth], do: Selector.nth(index)

  defp selector_predicate(key, text) when key in [:comment, :not_comment],
    do: Selector.comment(parse_comment_matcher!(text))

  defp selector_predicate(key, text) when key in [:comment_before, :not_comment_before],
    do: Selector.comment_before(parse_comment_matcher!(text))

  defp selector_predicate(key, text) when key in [:comment_after, :not_comment_after],
    do: Selector.comment_after(parse_comment_matcher!(text))

  defp selector_predicate(key, text) when key in [:comment_inside, :not_comment_inside],
    do: Selector.comment_inside(parse_comment_matcher!(text))

  defp selector_predicate(key, text) when key in [:comment_inline, :not_comment_inline],
    do: Selector.comment_inline(parse_comment_matcher!(text))

  defp comment_filter?(key), do: key in comment_filters()

  defp comment_filters do
    [
      :comment,
      :not_comment,
      :comment_before,
      :not_comment_before,
      :comment_after,
      :not_comment_after,
      :comment_inside,
      :not_comment_inside,
      :comment_inline,
      :not_comment_inline
    ]
  end

  defp parse_comment_matcher!("~r/" <> rest), do: compile_comment_regex!(rest)
  defp parse_comment_matcher!("/" <> rest), do: compile_comment_regex!(rest)
  defp parse_comment_matcher!(text), do: text

  defp compile_comment_regex!(rest) do
    case split_comment_regex(rest) do
      {pattern, flags} -> Regex.compile!(pattern, flags)
      :error -> "/" <> rest
    end
  end

  defp split_comment_regex(rest) do
    case last_unescaped_slash(rest) do
      nil -> :error
      index -> String.split_at(rest, index)
    end
    |> case do
      {pattern, "/" <> flags} -> {pattern, flags}
      other -> other
    end
  end

  defp last_unescaped_slash(rest) do
    rest
    |> String.graphemes()
    |> Stream.with_index()
    |> Enum.reduce({nil, false}, fn
      {"/", index}, {_last, false} -> {index, false}
      {"\\", _index}, {last, false} -> {last, true}
      {_char, _index}, {last, _escaped?} -> {last, false}
    end)
    |> elem(0)
  end
end
