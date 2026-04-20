defmodule ExAST.Diff.Annotated do
  @moduledoc false

  alias ExAST.Diff.Normalize

  @type node_info :: %{
          id: non_neg_integer(),
          node: Macro.t(),
          normalized: Macro.t(),
          kind: atom(),
          label: term(),
          hash: binary(),
          signature: {atom(), term(), Macro.t()},
          range: Sourceror.Range.t() | nil,
          size: pos_integer(),
          parent_id: non_neg_integer() | nil,
          children_ids: [non_neg_integer()]
        }

  @type t :: %__MODULE__{
          source: String.t(),
          ast: Macro.t(),
          nodes: %{non_neg_integer() => node_info()},
          root_id: non_neg_integer(),
          postorder_ids: [non_neg_integer()]
        }

  @enforce_keys [:source, :ast, :nodes, :root_id, :postorder_ids]
  defstruct [:source, :ast, :nodes, :root_id, :postorder_ids]

  @spec from_source(String.t()) :: t()
  def from_source(source) do
    ast = Sourceror.parse_string!(source)
    {root_id, nodes, postorder, _counter} = annotate(ast, nil, %{}, [], 1)

    %__MODULE__{
      source: source,
      ast: ast,
      nodes: nodes,
      root_id: root_id,
      postorder_ids: Enum.reverse(postorder)
    }
  end

  @spec fetch!(t(), non_neg_integer()) :: node_info()
  def fetch!(%__MODULE__{nodes: nodes}, id), do: Map.fetch!(nodes, id)

  # --- Tree annotation ---

  defp annotate(node, parent_id, nodes, postorder, counter) do
    id = counter
    children = direct_children(node)

    {child_ids, nodes, postorder, counter} =
      Enum.reduce(children, {[], nodes, postorder, counter + 1}, fn child, {ids, n, p, c} ->
        {child_id, n, p, c} = annotate(child, id, n, p, c)
        {[child_id | ids], n, p, c}
      end)

    child_ids = Enum.reverse(child_ids)
    normalized = Normalize.for_equivalence(node)

    info = %{
      id: id,
      node: node,
      normalized: normalized,
      kind: Normalize.kind(node),
      label: Normalize.label(node),
      signature: Normalize.signature(node),
      hash: :erlang.term_to_binary(normalized),
      range: safe_range(node),
      size: 1 + subtree_size(child_ids, nodes),
      parent_id: parent_id,
      children_ids: child_ids
    }

    {id, Map.put(nodes, id, info), [id | postorder], counter}
  end

  defp subtree_size(child_ids, nodes) do
    Enum.reduce(child_ids, 0, fn id, acc -> acc + Map.fetch!(nodes, id).size end)
  end

  defp safe_range(node) do
    Sourceror.get_range(node)
  rescue
    _ -> nil
  end

  # --- Child extraction ---

  defp direct_children({:__block__, _, children}) when is_list(children), do: children

  defp direct_children({_form, _meta, args}) when is_list(args),
    do: Enum.filter(args, &ast_node?/1)

  defp direct_children({left, right}), do: Enum.filter([left, right], &ast_node?/1)
  defp direct_children(list) when is_list(list), do: Enum.filter(list, &ast_node?/1)
  defp direct_children(_), do: []

  defp ast_node?({_, _, _}), do: true
  defp ast_node?({_, _}), do: true

  defp ast_node?(list) when is_list(list),
    do: Keyword.keyword?(list) or Enum.any?(list, &ast_node?/1)

  defp ast_node?(_), do: false
end
