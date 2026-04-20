defmodule ExAST.Diff.Matcher do
  @moduledoc false

  alias ExAST.Diff.Annotated

  @semantic_kinds [
    :module,
    :function,
    :call,
    :remote_call,
    :keyword,
    :map,
    :struct,
    :assignment,
    :block
  ]

  @spec match(Annotated.t(), Annotated.t()) :: %{non_neg_integer() => non_neg_integer()}
  def match(left, right) do
    %{}
    |> anchor_roots(left, right)
    |> anchor_functions(left, right)
    |> anchor_semantic_nodes(left, right)
    |> anchor_children(left, right)
  end

  # --- Phase 1: root anchoring ---

  defp anchor_roots(mappings, left, right) do
    Map.put(mappings, left.root_id, right.root_id)
  end

  # --- Phase 2: function anchoring by {name, arity} + parent propagation ---

  defp anchor_functions(mappings, left, right) do
    mappings
    |> anchor_by_kind(left, right, :function)
    |> anchor_function_parents(left, right)
  end

  defp anchor_by_kind(mappings, left, right, kind) do
    left.postorder_ids
    |> Enum.map(&Annotated.fetch!(left, &1))
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.reduce(mappings, fn left_info, acc ->
      case find_unique(right, acc, &(&1.kind == kind and &1.label == left_info.label)) do
        {:ok, right_id} -> Map.put(acc, left_info.id, right_id)
        :error -> acc
      end
    end)
  end

  defp anchor_function_parents(mappings, left, right) do
    mappings
    |> Enum.filter(fn {lid, _} -> Annotated.fetch!(left, lid).kind == :function end)
    |> Enum.reduce(mappings, fn {lid, rid}, acc ->
      lp = Annotated.fetch!(left, lid).parent_id
      rp = Annotated.fetch!(right, rid).parent_id

      if is_integer(lp) and is_integer(rp) and not Map.has_key?(acc, lp) do
        Map.put(acc, lp, rp)
      else
        acc
      end
    end)
  end

  # --- Phase 3: remaining semantic nodes by similarity ---

  defp anchor_semantic_nodes(mappings, left, right) do
    left
    |> semantic_ids()
    |> Enum.reject(&Map.has_key?(mappings, &1))
    |> Enum.reduce(mappings, fn left_id, acc ->
      left_info = Annotated.fetch!(left, left_id)

      case best_candidate(right, acc, left_info) do
        {:ok, right_id} -> Map.put(acc, left_id, right_id)
        :error -> acc
      end
    end)
  end

  # --- Phase 4: child recovery within matched parents ---

  defp anchor_children(mappings, left, right) do
    Enum.reduce(mappings, mappings, fn {left_id, right_id}, acc ->
      left_info = Annotated.fetch!(left, left_id)
      right_info = Annotated.fetch!(right, right_id)

      match_children(left, right, left_info, right_info, acc)
      |> Enum.reduce(acc, fn {cl, cr}, inner -> Map.put_new(inner, cl, cr) end)
    end)
  end

  # --- Helpers ---

  defp semantic_ids(tree) do
    Enum.filter(tree.postorder_ids, fn id ->
      Annotated.fetch!(tree, id).kind in @semantic_kinds
    end)
  end

  defp find_unique(tree, mappings, predicate) do
    used = MapSet.new(Map.values(mappings))

    tree.postorder_ids
    |> Enum.reject(&MapSet.member?(used, &1))
    |> Enum.map(&Annotated.fetch!(tree, &1))
    |> Enum.filter(predicate)
    |> case do
      [%{id: id}] -> {:ok, id}
      _ -> :error
    end
  end

  defp best_candidate(right, mappings, left_info) do
    used = MapSet.new(Map.values(mappings))

    right
    |> semantic_ids()
    |> Enum.reject(&MapSet.member?(used, &1))
    |> Enum.map(&Annotated.fetch!(right, &1))
    |> Enum.filter(&compatible?(left_info, &1))
    |> Enum.map(&{&1.id, similarity(mappings, left_info, &1)})
    |> Enum.filter(fn {_, score} -> score > 0 end)
    |> Enum.max_by(fn {_, score} -> score end, fn -> nil end)
    |> case do
      {id, _} -> {:ok, id}
      nil -> :error
    end
  end

  defp match_children(left, right, left_info, right_info, mappings) do
    case left_info.kind do
      k when k in [:map, :struct, :keyword] ->
        match_by_signature(left, right, left_info, right_info, mappings)

      k when k in [:module, :function] ->
        match_by_compatibility(left, right, left_info, right_info, mappings)

      _ ->
        []
    end
  end

  defp match_by_signature(left, right, left_info, right_info, mappings) do
    right_children = Enum.map(right_info.children_ids, &Annotated.fetch!(right, &1))
    used = MapSet.new(Map.values(mappings))

    left_info.children_ids
    |> Enum.map(&Annotated.fetch!(left, &1))
    |> Enum.reject(&Map.has_key?(mappings, &1.id))
    |> Enum.reduce([], fn lc, acc ->
      case Enum.find(
             right_children,
             &(not MapSet.member?(used, &1.id) and lc.signature == &1.signature)
           ) do
        nil -> acc
        rc -> [{lc.id, rc.id} | acc]
      end
    end)
  end

  defp match_by_compatibility(left, right, left_info, right_info, mappings) do
    right_children =
      right_info.children_ids
      |> Enum.map(&Annotated.fetch!(right, &1))
      |> Enum.filter(&(&1.kind in @semantic_kinds))

    used = MapSet.new(Map.values(mappings))

    left_info.children_ids
    |> Enum.map(&Annotated.fetch!(left, &1))
    |> Enum.filter(&(&1.kind in @semantic_kinds))
    |> Enum.reject(&Map.has_key?(mappings, &1.id))
    |> Enum.reduce([], fn lc, acc ->
      case Enum.find(right_children, &(not MapSet.member?(used, &1.id) and compatible?(lc, &1))) do
        nil -> acc
        rc -> [{lc.id, rc.id} | acc]
      end
    end)
  end

  defp similarity(mappings, a, b) do
    kind = if a.kind == b.kind, do: 5, else: 0
    label = if a.label == b.label, do: 8, else: 0
    sig = if a.signature == b.signature, do: 4, else: 0
    size = max(0, 3 - abs(a.size - b.size))

    parent =
      case {a.parent_id, b.parent_id} do
        {lp, rp} when is_integer(lp) and is_integer(rp) ->
          if Map.get(mappings, lp) == rp, do: 6, else: 0

        {nil, nil} ->
          2

        _ ->
          0
      end

    kind + label + sig + parent + size
  end

  defp compatible?(a, b), do: a.kind == b.kind and same_identity?(a, b)

  defp same_identity?(%{kind: :function, label: l}, %{kind: :function, label: l}), do: true
  defp same_identity?(%{kind: :module, label: l}, %{kind: :module, label: l}), do: true

  defp same_identity?(%{kind: :call, label: {:call, n, a}}, %{kind: :call, label: {:call, n, a}}),
    do: true

  defp same_identity?(
         %{kind: :remote_call, label: {:remote_call, _, f, a}},
         %{kind: :remote_call, label: {:remote_call, _, f, a}}
       ),
       do: true

  defp same_identity?(%{kind: k, label: l}, %{kind: k, label: l}), do: true
  defp same_identity?(_, _), do: false
end
