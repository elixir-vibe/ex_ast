defmodule ExAST.Diff.Classifier do
  @moduledoc false

  alias ExAST.Diff.Annotated
  alias ExAST.Diff.Edit
  alias ExAST.Diff.Render

  @semantic_kinds [:module, :function, :call, :remote_call, :keyword, :map, :struct, :assignment]

  @spec classify(
          Annotated.t(),
          Annotated.t(),
          %{non_neg_integer() => non_neg_integer()},
          keyword()
        ) :: [Edit.t()]
  def classify(left, right, mappings, opts) do
    include_moves = Keyword.get(opts, :include_moves, true)
    used_right = MapSet.new(Map.values(mappings))

    unmatched_left = MapSet.new(Enum.reject(left.postorder_ids, &Map.has_key?(mappings, &1)))

    unmatched_right =
      MapSet.new(Enum.reject(right.postorder_ids, &MapSet.member?(used_right, &1)))

    updates = collect_updates(left, right, mappings)
    moves = if include_moves, do: detect_function_moves(left, right, mappings), else: []
    deletions = collect_unmatched(left, unmatched_left, :delete)
    insertions = collect_unmatched(right, unmatched_right, :insert)

    (updates ++ moves ++ deletions ++ insertions)
    |> suppress_covered(left, mappings)
    |> Enum.uniq_by(&{&1.op, &1.old_id, &1.new_id})
    |> Enum.sort_by(&sort_key/1)
  end

  # --- Updates ---

  defp collect_updates(left, right, mappings) do
    Enum.flat_map(mappings, fn {left_id, right_id} ->
      left_info = Annotated.fetch!(left, left_id)
      right_info = Annotated.fetch!(right, right_id)

      case classify_update(left_info, right_info) do
        nil -> []
        edit -> [edit]
      end
    end)
  end

  defp classify_update(%{hash: hash}, %{hash: hash}), do: nil

  defp classify_update(%{kind: :function} = l, r),
    do: make_edit(:update, :function, "updated function #{render_label(l.label)}", l, r)

  defp classify_update(%{kind: k} = l, r) when k in [:call, :remote_call],
    do: make_edit(:update, k, "updated call #{render_label(l.label)}", l, r)

  defp classify_update(%{kind: k} = l, r) when k in [:keyword, :map, :struct],
    do: make_edit(:update, k, "updated #{k}", l, r)

  defp classify_update(%{kind: :assignment} = l, r),
    do: make_edit(:update, :assignment, "updated assignment", l, r)

  defp classify_update(_, _), do: nil

  # --- Inserts / Deletes ---

  defp collect_unmatched(tree, unmatched_set, op) do
    unmatched_set
    |> Enum.filter(&(Annotated.fetch!(tree, &1).kind in @semantic_kinds))
    |> Enum.reject(&has_reportable_ancestor?(tree, &1, unmatched_set))
    |> Enum.map(&unmatched_edit(tree, &1, op))
  end

  defp unmatched_edit(tree, id, :delete) do
    info = Annotated.fetch!(tree, id)

    %Edit{
      op: :delete,
      kind: info.kind,
      summary: "deleted #{info.kind} #{render_label(info.label)}",
      old_id: id,
      old_range: info.range,
      meta: %{old: Render.node_source(info.node)}
    }
  end

  defp unmatched_edit(tree, id, :insert) do
    info = Annotated.fetch!(tree, id)

    %Edit{
      op: :insert,
      kind: info.kind,
      summary: "inserted #{info.kind} #{render_label(info.label)}",
      new_id: id,
      new_range: info.range,
      meta: %{new: Render.node_source(info.node)}
    }
  end

  # --- Ancestor / range suppression ---

  defp has_reportable_ancestor?(tree, id, unmatched_set) do
    parent_id = Annotated.fetch!(tree, id).parent_id
    walk_up(tree, parent_id, unmatched_set, @semantic_kinds)
  end

  defp suppress_covered(edits, left, mappings) do
    updated_old_ids =
      edits
      |> Enum.filter(&(&1.op == :update and &1.old_id != nil))
      |> MapSet.new(& &1.old_id)

    update_old_ranges =
      edits
      |> Enum.filter(&(&1.op == :update and &1.old_range != nil))
      |> Enum.map(& &1.old_range)

    update_new_ranges =
      edits
      |> Enum.filter(&(&1.op == :update and &1.new_range != nil))
      |> Enum.map(& &1.new_range)

    Enum.reject(edits, fn edit ->
      case edit.op do
        :update ->
          edit.old_id != nil and
            walk_up_mapped(
              left,
              Annotated.fetch!(left, edit.old_id).parent_id,
              updated_old_ids,
              mappings
            )

        :delete ->
          range_covered_by_update?(edit.old_range, update_old_ranges)

        :insert ->
          range_covered_by_update?(edit.new_range, update_new_ranges)

        :move ->
          false
      end
    end)
  end

  defp range_covered_by_update?(nil, _update_ranges), do: false

  defp range_covered_by_update?(range, update_ranges) do
    Enum.any?(update_ranges, &range_strictly_contains?(&1, range))
  end

  defp range_strictly_contains?(outer, inner) do
    {ol, oc} = {outer.start[:line], outer.start[:column]}
    {oel, oec} = {outer.end[:line], outer.end[:column]}
    {il, ic} = {inner.start[:line], inner.start[:column]}
    {iel, iec} = {inner.end[:line], inner.end[:column]}

    starts_inside = il > ol or (il == ol and ic >= oc)
    ends_inside = iel < oel or (iel == oel and iec <= oec)
    not_identical = {il, ic, iel, iec} != {ol, oc, oel, oec}

    starts_inside and ends_inside and not_identical
  end

  defp walk_up(_tree, nil, _set, _kinds), do: false

  defp walk_up(tree, parent_id, set, kinds) do
    info = Annotated.fetch!(tree, parent_id)

    if MapSet.member?(set, parent_id) and info.kind in kinds do
      true
    else
      walk_up(tree, info.parent_id, set, kinds)
    end
  end

  defp walk_up_mapped(_tree, nil, _set, _mappings), do: false

  defp walk_up_mapped(tree, parent_id, set, mappings) do
    if Map.has_key?(mappings, parent_id) and MapSet.member?(set, parent_id) do
      true
    else
      walk_up_mapped(tree, Annotated.fetch!(tree, parent_id).parent_id, set, mappings)
    end
  end

  # --- Function move detection ---

  defp detect_function_moves(left, right, mappings) do
    mappings
    |> Enum.filter(fn {lid, rid} ->
      Annotated.fetch!(left, lid).kind == :function and
        Annotated.fetch!(right, rid).kind == :function
    end)
    |> Enum.group_by(fn {lid, _} -> Annotated.fetch!(left, lid).parent_id end)
    |> Enum.flat_map(fn {left_parent_id, pairs} ->
      right_parent_id = Annotated.fetch!(right, elem(hd(pairs), 1)).parent_id

      if length(pairs) > 1 and Map.get(mappings, left_parent_id) == right_parent_id do
        detect_reorders(left, right, pairs)
      else
        []
      end
    end)
  end

  defp detect_reorders(left, right, pairs) do
    pairs
    |> Enum.sort_by(fn {lid, _} -> function_index(left, lid) end)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{left_id, right_id}, old_index} ->
      if old_index != function_index(right, right_id) do
        left_info = Annotated.fetch!(left, left_id)
        right_info = Annotated.fetch!(right, right_id)

        [
          %Edit{
            op: :move,
            kind: :function,
            summary: "moved function #{render_label(left_info.label)}",
            old_id: left_id,
            new_id: right_id,
            old_range: left_info.range,
            new_range: right_info.range
          }
        ]
      else
        []
      end
    end)
  end

  defp function_index(tree, id) do
    case Annotated.fetch!(tree, id).parent_id do
      nil ->
        0

      parent_id ->
        tree
        |> Annotated.fetch!(parent_id)
        |> Map.fetch!(:children_ids)
        |> Enum.map(&Annotated.fetch!(tree, &1))
        |> Enum.filter(&(&1.kind == :function))
        |> Enum.find_index(&(&1.id == id))
    end
  end

  # --- Helpers ---

  defp make_edit(op, kind, summary, left_info, right_info) do
    %Edit{
      op: op,
      kind: kind,
      summary: summary,
      old_id: left_info.id,
      new_id: right_info.id,
      old_range: left_info.range,
      new_range: right_info.range,
      meta: %{old: Render.node_source(left_info.node), new: Render.node_source(right_info.node)}
    }
  end

  defp render_label(nil), do: ""

  defp render_label({kind, name, arity}) when kind in [:def, :defp],
    do: "#{kind} #{name}/#{arity}"

  defp render_label({:module, parts}), do: Enum.join(parts, ".")
  defp render_label({:call, name, arity}), do: "#{name}/#{arity}"

  defp render_label({:remote_call, target, fun, arity}),
    do: "#{format_target(target)}.#{fun}/#{arity}"

  defp render_label({:struct, parts}), do: "%" <> Enum.join(parts, ".") <> "{}"
  defp render_label({:map, _keys}), do: "%{}"
  defp render_label({:keyword, _keys}), do: "keyword"
  defp render_label(label) when is_atom(label), do: Atom.to_string(label)
  defp render_label(label) when is_binary(label), do: label
  defp render_label(label), do: inspect(label)

  defp format_target(parts) when is_list(parts), do: Enum.join(parts, ".")
  defp format_target(other), do: inspect(other)

  defp sort_key(%Edit{old_range: %{start: s}, op: op, new_range: nil}), do: {s[:line], order(op)}
  defp sort_key(%Edit{new_range: %{start: s}, op: op, old_range: nil}), do: {s[:line], order(op)}

  defp sort_key(%Edit{old_range: %{start: a}, new_range: %{start: b}, op: op}),
    do: {min(a[:line], b[:line]), order(op)}

  defp sort_key(%Edit{op: op}), do: {0, order(op)}

  defp order(:move), do: 0
  defp order(:update), do: 1
  defp order(:delete), do: 2
  defp order(:insert), do: 3
end
