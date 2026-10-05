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

  @doc """
  Renders AST as source like `Macro.to_string/1`, keeping the escapes of
  interpolated strings.

  `Macro.to_string/1` writes interpolated string parts as is, so a part holding a
  backslash, `\#{` or a newline renders as a different string. Sigil contents are
  raw source and stay untouched.
  """
  @spec to_string(Macro.t()) :: String.t()
  def to_string(ast), do: ast |> escape_interpolations() |> Macro.to_string()

  defp escape_interpolations({name, meta, [{:<<>>, string_meta, parts}, modifiers]})
       when is_atom(name) and is_list(parts) and is_list(modifiers) do
    if sigil?(name) do
      parts = Enum.map(parts, &if(is_binary(&1), do: &1, else: escape_interpolations(&1)))
      {name, meta, [{:<<>>, string_meta, parts}, modifiers]}
    else
      {name, meta, escape_interpolations([{:<<>>, string_meta, parts}, modifiers])}
    end
  end

  defp escape_interpolations({:<<>>, meta, parts}) when is_list(parts) do
    if interpolated_string?(parts),
      do: {:<<>>, meta, Enum.map(parts, &escape_part/1)},
      else: {:<<>>, meta, escape_interpolations(parts)}
  end

  defp escape_interpolations({form, meta, args}),
    do: {escape_interpolations(form), meta, escape_interpolations(args)}

  defp escape_interpolations({left, right}),
    do: {escape_interpolations(left), escape_interpolations(right)}

  defp escape_interpolations(list) when is_list(list),
    do: Enum.map(list, &escape_interpolations/1)

  defp escape_interpolations(other), do: other

  defp sigil?(name), do: name |> Atom.to_string() |> String.starts_with?("sigil_")

  defp interpolated_string?(parts), do: Enum.all?(parts, &(is_binary(&1) or interpolation?(&1)))

  defp interpolation?({:"::", _, [{{:., _, [Kernel, :to_string]}, _, [_]}, {:binary, _, _}]}),
    do: true

  defp interpolation?(_part), do: false

  defp escape_part(part) when is_binary(part) do
    part
    |> String.replace("\\", "\\\\")
    |> String.replace("\#{", "\\\#{")
    |> String.replace("\n", "\\n")
    |> String.replace("\t", "\\t")
    |> String.replace("\r", "\\r")
  end

  defp escape_part(interpolation), do: escape_interpolations(interpolation)
end
