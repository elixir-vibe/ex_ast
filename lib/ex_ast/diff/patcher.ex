defmodule ExAST.Diff.Patcher do
  @moduledoc """
  Applies diff edits to produce patched source code.

  Takes a diff result and builds Sourceror patches for updates, deletes,
  and inserts, then applies them in a single pass to the left source.
  Move edits are skipped since they represent reorders without content changes.
  """

  alias ExAST.Diff.Annotated
  alias ExAST.Diff.Edit
  alias ExAST.Diff.Result

  @spec apply(Result.t()) :: String.t()
  def apply(%Result{} = result) do
    patches =
      result.edits
      |> Enum.flat_map(&to_patches(&1, result))
      |> deduplicate()

    Sourceror.patch_string(result.left.source, patches)
  end

  # --- Patch generation ---

  defp to_patches(%Edit{op: :update, old_range: %{} = range, new_range: %{} = new_range}, %Result{
         right: right
       }) do
    [%{range: range, change: extract(right.source, new_range)}]
  end

  defp to_patches(%Edit{op: :delete, old_range: %{} = range}, _result) do
    [%{range: expand_to_full_line(range), change: ""}]
  end

  defp to_patches(
         %Edit{op: :insert, new_id: new_id, new_range: %{} = new_range},
         %Result{} = result
       ) do
    case insertion_point(new_id, result) do
      nil ->
        []

      point ->
        text = extract(result.right.source, new_range)
        indent = detect_indent(result.left.source, point)
        [%{range: %{start: point, end: point}, change: indent <> text <> "\n"}]
    end
  end

  defp to_patches(_edit, _result), do: []

  # --- Insertion point ---

  defp insertion_point(new_id, %Result{left: left, right: right, mappings: mappings}) do
    reverse = Map.new(mappings, fn {l, r} -> {r, l} end)
    new_info = Annotated.fetch!(right, new_id)

    case new_info.parent_id do
      nil ->
        nil

      parent_id ->
        siblings = Annotated.fetch!(right, parent_id).children_ids
        my_index = Enum.find_index(siblings, &(&1 == new_id)) || 0

        case find_mapped_predecessor(siblings, my_index, reverse, left) do
          {:ok, point} -> point
          :error -> find_ancestor_start(parent_id, right, reverse, left)
        end
    end
  end

  defp find_mapped_predecessor(siblings, my_index, reverse, left) do
    siblings
    |> Enum.take(my_index)
    |> Enum.reverse()
    |> Enum.find_value(:error, fn sib_id ->
      with left_id when is_integer(left_id) <- Map.get(reverse, sib_id),
           %{end: end_pos} <- Annotated.fetch!(left, left_id).range do
        {:ok, [line: end_pos[:line] + 1, column: 1]}
      else
        _ -> nil
      end
    end)
  end

  defp find_ancestor_start(right_id, right, reverse, left) do
    case Map.get(reverse, right_id) do
      nil ->
        case Annotated.fetch!(right, right_id).parent_id do
          nil -> nil
          grandparent_id -> find_ancestor_start(grandparent_id, right, reverse, left)
        end

      left_id ->
        case Annotated.fetch!(left, left_id).range do
          %{start: start} -> [line: start[:line] + 1, column: 1]
          _ -> nil
        end
    end
  end

  # --- Source extraction ---

  defp extract(source, %{start: start_pos, end: end_pos}) do
    lines = String.split(source, "\n")
    sl = start_pos[:line]
    sc = start_pos[:column]
    el = end_pos[:line]
    ec = end_pos[:column]

    lines
    |> Enum.slice((sl - 1)..(el - 1)//1)
    |> Enum.with_index(sl)
    |> Enum.map_join("\n", fn {line, n} ->
      cond do
        n == sl and n == el -> String.slice(line, (sc - 1)..(ec - 2)//1)
        n == sl -> String.slice(line, (sc - 1)..-1//1)
        n == el -> String.slice(line, 0..(ec - 2)//1)
        true -> line
      end
    end)
  end

  # --- Helpers ---

  defp expand_to_full_line(%{start: s, end: e}) do
    %{start: [line: s[:line], column: 1], end: [line: e[:line] + 1, column: 1]}
  end

  defp detect_indent(source, point) do
    line_num = point[:line]

    case source |> String.split("\n") |> Enum.at(line_num - 1) do
      nil -> "  "
      line -> String.duplicate(" ", byte_size(line) - byte_size(String.trim_leading(line)))
    end
  end

  defp deduplicate(patches) do
    Enum.uniq_by(patches, fn %{range: r, change: c} ->
      {r.start[:line], r.start[:column], r.end[:line], r.end[:column], c}
    end)
  end
end
