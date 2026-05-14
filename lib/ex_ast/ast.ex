defmodule ExAST.AST do
  @moduledoc false

  @spec strip_sourceror_meta(map()) :: map()
  def strip_sourceror_meta(captures) when is_map(captures) do
    Map.new(captures, fn {key, value} -> {key, do_strip_sourceror_meta(value)} end)
  end

  defp do_strip_sourceror_meta({form, _meta, args}) when is_atom(form),
    do: {form, [], do_strip_sourceror_meta(args)}

  defp do_strip_sourceror_meta({form, _meta, args}),
    do: {do_strip_sourceror_meta(form), [], do_strip_sourceror_meta(args)}

  defp do_strip_sourceror_meta({left, right}),
    do: {do_strip_sourceror_meta(left), do_strip_sourceror_meta(right)}

  defp do_strip_sourceror_meta(list) when is_list(list),
    do: Enum.map(list, &do_strip_sourceror_meta/1)

  defp do_strip_sourceror_meta(other), do: other
end
