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

  # `Macro.to_string/1` writes interpolated string parts as is, so a part holding
  # a backslash, `\#{` or a newline would render as a different string.
  @interpolation_escapes %{
    "\\" => "\\\\",
    "\#{" => "\\\#{",
    "\n" => "\\n",
    "\r" => "\\r",
    "\t" => "\\t"
  }

  @doc """
  Renders AST like `Macro.to_string/1`. Accepts normalized nodes with `nil` meta and
  keeps the escapes of interpolated strings.
  """
  @spec to_string(Macro.t()) :: String.t()
  def to_string(ast), do: ast |> Macro.prewalk(&escape_interpolation/1) |> Macro.to_string()

  defp escape_interpolation({form, nil, args}), do: escape_interpolation({form, [], args})

  # Sigil contents are raw source: mark them so the walk leaves them alone.
  defp escape_interpolation({name, meta, [{:<<>>, string_meta, parts}, modifiers]} = node)
       when is_atom(name) and is_list(modifiers) do
    if String.starts_with?(Atom.to_string(name), "sigil_"),
      do: {name, meta, [{:<<>>, [ex_ast_raw: true] ++ List.wrap(string_meta), parts}, modifiers]},
      else: node
  end

  defp escape_interpolation({:<<>>, meta, parts} = node) when is_list(parts) do
    if !meta[:ex_ast_raw] and Enum.all?(parts, &string_part?/1),
      do: {:<<>>, meta, Enum.map(parts, &escape_part/1)},
      else: node
  end

  defp escape_interpolation(node), do: node

  defp string_part?(part) when is_binary(part), do: true

  defp string_part?({:"::", _, [{{:., _, [Kernel, :to_string]}, _, [_]}, {:binary, _, _}]}),
    do: true

  defp string_part?(_part), do: false

  defp escape_part(part) when is_binary(part),
    do: String.replace(part, Map.keys(@interpolation_escapes), &@interpolation_escapes[&1])

  defp escape_part(interpolation), do: interpolation
end
