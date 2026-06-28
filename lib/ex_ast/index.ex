defmodule ExAST.Index do
  @moduledoc """
  Candidate-index metadata for ExAST patterns and selectors.

  This module exposes conservative structural terms and source requirements for
  storage/indexing layers. Terms are only candidates; callers must still verify
  matches with ExAST.
  """

  alias ExAST.CompiledPattern
  alias ExAST.Index.{Plan, Terms}
  alias ExAST.Selector
  alias ExAST.Selector.{CommentMatcher, Predicate}

  @spec plan(ExAST.Pattern.pattern() | Selector.t()) :: Plan.t()
  def plan(%Selector{} = selector) do
    {positive, negative, candidate_groups} = selector_terms(selector)
    positive = MapSet.union(positive, inferred_terms(selector))
    {required, optional} = partition_terms(positive)

    %Plan{
      required_terms: required,
      optional_terms: optional,
      negative_terms: negative,
      candidate_groups: Enum.map(candidate_groups, &candidate_group_terms/1),
      requires_source?: Selector.requires_source?(selector),
      requires_comments?: Selector.requires_comments?(selector)
    }
  end

  def plan(%CompiledPattern{terms: terms}) do
    {required, optional} = partition_terms(terms)
    %Plan{required_terms: required, optional_terms: optional}
  end

  def plan(pattern) do
    {required, optional} = pattern |> Terms.from_pattern() |> partition_terms()
    %Plan{required_terms: required, optional_terms: optional}
  end

  @spec terms(ExAST.Pattern.pattern() | Selector.t()) :: MapSet.t(String.t())
  def terms(pattern_or_selector) do
    plan = plan(pattern_or_selector)

    plan.required_terms
    |> MapSet.union(plan.optional_terms)
    |> MapSet.union(plan.negative_terms)
    |> then(fn terms ->
      Enum.reduce(plan.candidate_groups, terms, &MapSet.union/2)
    end)
  end

  @spec term_signal(String.t()) :: Terms.signal()
  defdelegate term_signal(term), to: Terms, as: :signal

  defp selector_terms(%Selector{steps: steps, filters: filters}) do
    step_terms =
      steps
      |> Enum.flat_map(fn {_relation, pattern} ->
        pattern |> Terms.from_pattern() |> MapSet.to_list()
      end)
      |> MapSet.new()

    Enum.reduce(filters, {step_terms, MapSet.new(), []}, fn filter, {pos, neg, groups} ->
      terms = predicate_terms(filter)

      cond do
        filter.negated? ->
          {pos, MapSet.union(neg, terms), groups}

        filter.relation == :any ->
          {pos, neg, combine_candidate_groups(groups, any_candidate_groups(filter))}

        true ->
          {MapSet.union(pos, terms), neg, groups}
      end
    end)
  end

  defp predicate_terms(%Predicate{relation: relation})
       when relation in [
              :first,
              :last,
              :nth,
              :captures,
              :comment,
              :comment_before,
              :comment_after,
              :comment_inside,
              :comment_inline
            ],
       do: MapSet.new()

  defp predicate_terms(%Predicate{relation: relation, pattern: predicates})
       when relation in [:all, :any] and is_list(predicates) do
    predicates
    |> Enum.map(&predicate_terms/1)
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
  end

  defp predicate_terms(%Predicate{pattern: %CommentMatcher{}}), do: MapSet.new()
  defp predicate_terms(%Predicate{pattern: %Regex{}}), do: MapSet.new()
  defp predicate_terms(%Predicate{pattern: pattern}), do: Terms.from_pattern(pattern)

  defp any_candidate_groups(%Predicate{relation: :any, pattern: predicates}) do
    Enum.map(predicates, &candidate_group_terms(predicate_terms(&1)))
  end

  defp combine_candidate_groups(existing, new_groups) do
    new_groups = Enum.reject(new_groups, &(MapSet.size(&1) == 0))

    cond do
      new_groups == [] -> existing
      existing == [] -> new_groups
      true -> for left <- existing, right <- new_groups, do: MapSet.union(left, right)
    end
  end

  defp candidate_group_terms(terms) do
    {required, _optional} = partition_terms(terms)
    required
  end

  defp partition_terms(terms) do
    high_signal = Enum.filter(terms, &Terms.high_signal?/1) |> MapSet.new()
    indexable = Enum.reject(terms, &Terms.low_signal?/1) |> MapSet.new()

    cond do
      MapSet.size(high_signal) > 0 -> {high_signal, MapSet.difference(indexable, high_signal)}
      MapSet.size(indexable) > 0 -> {indexable, MapSet.new()}
      true -> {MapSet.new(), MapSet.new()}
    end
  end

  defp inferred_terms(%Selector{steps: [self: {op, _meta, [left, right]}], filters: filters})
       when is_atom(op) do
    if equality_capture_guard?(filters, left, right) do
      MapSet.new(["call.local.same_args:#{op}/2"])
    else
      MapSet.new()
    end
  end

  defp inferred_terms(_selector), do: MapSet.new()

  defp equality_capture_guard?(filters, left, right) do
    left_name = capture_name(left)
    right_name = capture_name(right)

    left_name && right_name &&
      Enum.any?(filters, &same_capture_predicate?(&1, left_name, right_name))
  end

  defp same_capture_predicate?(%Predicate{relation: :captures, pattern: fun}, left, right)
       when is_function(fun, 1) do
    value = {:__same_capture__, [], []}
    other = {:__other_capture__, [], []}

    same? = safe_capture_predicate?(fun, %{left => value, right => value})
    different? = safe_capture_predicate?(fun, %{left => value, right => other})

    same? and not different?
  end

  defp same_capture_predicate?(%Predicate{relation: relation, pattern: predicates}, left, right)
       when relation in [:all, :any] and is_list(predicates) do
    Enum.any?(predicates, &same_capture_predicate?(&1, left, right))
  end

  defp same_capture_predicate?(_predicate, _left, _right), do: false

  defp safe_capture_predicate?(fun, captures) do
    fun.(captures) == true
  rescue
    _ -> false
  end

  defp capture_name({name, _meta, nil}) when is_atom(name), do: name
  defp capture_name({name, _meta, context}) when is_atom(name) and is_atom(context), do: name
  defp capture_name(_ast), do: nil
end
