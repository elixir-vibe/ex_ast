defimpl Jason.Encoder, for: Sourceror.Range do
  def encode(%Sourceror.Range{start: start, end: end_}, opts) do
    Jason.Encode.map(%{start: position(start), end: position(end_)}, opts)
  end

  defp position(value) when is_list(value) do
    %{line: value[:line], column: value[:column]}
  end

  defp position(value), do: value
end

defimpl Jason.Encoder, for: MapSet do
  def encode(set, opts) do
    set
    |> MapSet.to_list()
    |> Jason.Encode.list(opts)
  end
end

defimpl Jason.Encoder, for: Regex do
  def encode(regex, opts), do: Jason.Encode.string(inspect(regex), opts)
end

defimpl Jason.Encoder, for: ExAST.CompiledPattern do
  def encode(pattern, opts) do
    Jason.Encode.map(
      %{
        original: render(pattern.original),
        signature: inspect(pattern.signature),
        terms: pattern.terms,
        multi_node: pattern.multi_node?,
        broad: pattern.broad?
      },
      opts
    )
  end

  defp render(value) when is_binary(value), do: value
  defp render(value), do: Macro.to_string(value)
end

defimpl Jason.Encoder, for: ExAST.Diff.Edit do
  def encode(edit, opts) do
    Jason.Encode.map(
      %{
        op: edit.op,
        kind: edit.kind,
        summary: edit.summary,
        old_id: edit.old_id,
        new_id: edit.new_id,
        old_range: edit.old_range,
        new_range: edit.new_range,
        meta: stringify_meta(edit.meta)
      },
      opts
    )
  end

  defp stringify_meta(meta) do
    Map.new(meta, fn {key, value} -> {key, stringify(value)} end)
  end

  defp stringify(value) when is_binary(value), do: value

  defp stringify(value)
       when is_atom(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, stringify(item)} end)

  defp stringify(value), do: inspect(value)
end
