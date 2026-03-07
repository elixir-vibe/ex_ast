defmodule ExAst.Patcher do
  @moduledoc """
  Finds and replaces AST patterns in source code.

  Uses Sourceror for parsing, traversal, and source-level patching
  to preserve formatting of unchanged code.
  """

  alias ExAst.Pattern

  @type match :: %{
          node: Macro.t(),
          range: Sourceror.Range.t(),
          captures: Pattern.captures()
        }

  @doc """
  Finds all occurrences of `pattern` in `source`.

  Returns a list of matches with the matched node, its source range,
  and any captured values.
  """
  @spec find_all(String.t(), String.t()) :: [match()]
  def find_all(source, pattern) do
    ast = Sourceror.parse_string!(source)
    zipper = Sourceror.Zipper.zip(ast)
    collect_matches(zipper, pattern, [])
  end

  @doc """
  Replaces all occurrences of `pattern` with `replacement` in `source`.

  Captures from the pattern are substituted into the replacement template.
  Returns the modified source string.
  """
  @spec replace_all(String.t(), String.t(), String.t()) :: String.t()
  def replace_all(source, pattern, replacement) do
    replacement_ast = Code.string_to_quoted!(replacement)
    matches = find_all(source, pattern)

    patches =
      Enum.map(matches, fn %{range: range, captures: captures} ->
        substituted = Pattern.substitute(replacement_ast, captures)
        %{range: range, change: substituted |> restore_meta() |> Macro.to_string()}
      end)

    Sourceror.patch_string(source, patches)
  end

  defp restore_meta(ast) do
    Macro.prewalk(ast, fn
      {form, nil, args} -> {form, [], args}
      other -> other
    end)
  end

  defp collect_matches(nil, _pattern, acc), do: Enum.reverse(acc)

  defp collect_matches(zipper, pattern, acc) do
    node = Sourceror.Zipper.node(zipper)

    case Pattern.match(node, pattern) do
      {:ok, captures} ->
        range = Sourceror.get_range(node)

        match = %{node: node, range: range, captures: captures}
        zipper |> Sourceror.Zipper.skip() |> collect_matches(pattern, [match | acc])

      :error ->
        zipper |> Sourceror.Zipper.next() |> collect_matches(pattern, acc)
    end
  end
end
