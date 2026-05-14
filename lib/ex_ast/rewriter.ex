defmodule ExAST.Rewriter.Replacement do
  @moduledoc """
  A planned source replacement.
  """

  @type t :: %__MODULE__{
          range: Sourceror.Range.t(),
          original: String.t() | nil,
          replacement: String.t(),
          captures: ExAST.Pattern.captures()
        }

  @enforce_keys [:range, :replacement, :captures]
  defstruct [:range, :original, :replacement, :captures]
end

defmodule ExAST.Rewriter.Plan do
  @moduledoc """
  A rewrite plan that can be inspected, encoded, or applied.
  """

  @type t :: %__MODULE__{
          replacements: [ExAST.Rewriter.Replacement.t()],
          conflicts: [ExAST.PatchConflict.t()]
        }

  @enforce_keys [:replacements, :conflicts]
  defstruct [:replacements, :conflicts]
end

defmodule ExAST.Rewriter do
  @moduledoc """
  Builds and applies replacement plans without immediately changing files.
  """

  alias ExAST.PatchConflict
  alias ExAST.Pattern
  alias ExAST.Rewriter.{Plan, Replacement}

  @type conflict_mode :: :raise | :skip | :keep

  @spec plan(String.t(), Pattern.pattern() | ExAST.Selector.t(), Pattern.pattern(), keyword()) ::
          Plan.t()
  def plan(source, pattern, replacement, opts \\ []) when is_binary(source) do
    replacement_ast = to_quoted(replacement)

    replacements =
      source
      |> ExAST.Patcher.find_all(pattern, opts)
      |> Enum.map(fn %{range: range, source: original, captures: captures} ->
        replacement_source =
          replacement_ast
          |> Pattern.substitute(ExAST.AST.strip_sourceror_meta(captures))
          |> restore_meta()
          |> Macro.to_string()

        %Replacement{
          range: range,
          original: original,
          replacement: replacement_source,
          captures: captures
        }
      end)

    %Plan{replacements: replacements, conflicts: conflicts(replacements)}
  end

  @spec apply(String.t(), Plan.t(), keyword()) :: String.t()
  def apply(source, %Plan{} = plan, opts \\ []) do
    replacements = conflict_safe_replacements(plan, Keyword.get(opts, :on_conflict, :raise))
    patches = Enum.map(replacements, &%{range: &1.range, change: &1.replacement})
    Sourceror.patch_string(source, patches)
  end

  defp conflict_safe_replacements(%Plan{conflicts: [], replacements: replacements}, _mode),
    do: replacements

  defp conflict_safe_replacements(%Plan{conflicts: conflicts}, :raise) do
    raise ArgumentError, "rewrite plan contains #{length(conflicts)} overlapping replacement(s)"
  end

  defp conflict_safe_replacements(%Plan{replacements: replacements, conflicts: conflicts}, :skip) do
    conflict_ranges =
      conflicts
      |> Enum.flat_map(&[&1.first_range, &1.second_range])
      |> MapSet.new(&range_key/1)

    Enum.reject(replacements, &MapSet.member?(conflict_ranges, range_key(&1.range)))
  end

  defp conflict_safe_replacements(%Plan{replacements: replacements}, :keep), do: replacements

  defp conflicts(replacements) do
    replacements
    |> Enum.sort_by(&range_start_key(&1.range))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [left, right] -> overlaps?(left.range, right.range) end)
    |> Enum.map(fn [left, right] ->
      %PatchConflict{
        first_range: left.range,
        second_range: right.range,
        reason: :overlapping_replacements
      }
    end)
  end

  defp overlaps?(nil, _range), do: false
  defp overlaps?(_range, nil), do: false
  defp overlaps?(left, right), do: range_start_key(right) < range_end_key(left)

  defp range_key(nil), do: nil

  defp range_key(range),
    do: {range.start[:line], range.start[:column], range.end[:line], range.end[:column]}

  defp range_start_key(nil), do: {0, 0}
  defp range_start_key(range), do: {range.start[:line] || 0, range.start[:column] || 0}
  defp range_end_key(nil), do: {0, 0}
  defp range_end_key(range), do: {range.end[:line] || 0, range.end[:column] || 0}

  defp to_quoted(pattern) when is_binary(pattern), do: Code.string_to_quoted!(pattern)
  defp to_quoted(pattern), do: pattern

  defp restore_meta(ast) do
    Macro.prewalk(ast, fn
      {form, nil, args} -> {form, [], args}
      other -> other
    end)
  end
end

defimpl Jason.Encoder, for: ExAST.Rewriter.Replacement do
  def encode(replacement, opts) do
    Jason.Encode.map(
      %{
        range: replacement.range,
        original: replacement.original,
        replacement: replacement.replacement,
        captures: encode_captures(replacement.captures)
      },
      opts
    )
  end

  defp encode_captures(captures) do
    Map.new(captures, fn {name, value} -> {name, Macro.to_string(value)} end)
  end
end

defimpl Jason.Encoder, for: ExAST.Rewriter.Plan do
  def encode(plan, opts) do
    Jason.Encode.map(%{replacements: plan.replacements, conflicts: plan.conflicts}, opts)
  end
end
