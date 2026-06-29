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

  defp predicate_terms(%Predicate{pattern: nil}), do: MapSet.new()
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
    terms =
      if equality_capture_guard?(filters, left, right) do
        ["call.local.same_args:#{op}/2"]
      else
        []
      end

    MapSet.new(terms)
  end

  defp inferred_terms(%Selector{steps: [self: step], filters: filters}) do
    step
    |> call_capture_args()
    |> inferred_capture_arg_terms(filters)
    |> MapSet.new()
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

  defp inferred_capture_arg_terms([], _filters), do: []

  defp inferred_capture_arg_terms(capture_args, filters) do
    filters
    |> Enum.flat_map(fn
      %Predicate{relation: :captures, pattern: fun, negated?: false} when is_function(fun, 1) ->
        Enum.flat_map(capture_args, &boolean_capture_arg_terms(&1, capture_args, fun))

      _predicate ->
        []
    end)
  end

  defp boolean_capture_arg_terms({capture, call, position}, capture_args, fun) do
    true_captures = captures_for(capture_args, capture, true)
    false_captures = captures_for(capture_args, capture, false)
    placeholder_captures = captures_for(capture_args, capture, placeholder_ast(capture))

    if safe_capture_predicate?(fun, true_captures) and
         safe_capture_predicate?(fun, false_captures) and
         not safe_capture_predicate?(fun, placeholder_captures) do
      ["call.arg:#{call}:#{position}:atom:boolean"]
    else
      []
    end
  end

  defp captures_for(capture_args, target, target_value) do
    Map.new(capture_args, fn {capture, _call, _position} ->
      value = if capture == target, do: target_value, else: placeholder_ast(capture)
      {capture, value}
    end)
  end

  defp placeholder_ast(capture), do: {capture, [], nil}

  defp call_capture_args({{:., _dot_meta, [module_ast, fun]}, _meta, args})
       when is_atom(fun) and is_list(args) do
    if literal_alias?(module_ast) do
      call = "#{alias_name(module_ast)}.#{fun}/#{length(args)}"
      capture_args(call, args)
    else
      []
    end
  end

  defp call_capture_args({name, _meta, args}) when is_atom(name) and is_list(args) do
    capture_args("#{name}/#{length(args)}", args)
  end

  defp call_capture_args(_step), do: []

  defp capture_args(call, args) do
    args
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {arg, position} ->
      case capture_name(arg) do
        nil -> []
        capture -> [{capture, call, position}]
      end
    end)
  end

  defp safe_capture_predicate?(fun, captures) do
    fun.(captures) == true
  rescue
    _ -> false
  end

  defp literal_alias?({:__aliases__, _, parts}), do: Enum.all?(parts, &is_atom/1)
  defp literal_alias?(_ast), do: false

  defp alias_name({:__aliases__, _, parts}), do: Enum.join(parts, ".")

  defp capture_name({name, _meta, nil}) when is_atom(name), do: name
  defp capture_name({name, _meta, context}) when is_atom(name) and is_atom(context), do: name
  defp capture_name(_ast), do: nil
end
