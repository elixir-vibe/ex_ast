defmodule ExAST.Diff do
  @moduledoc """
  Syntax-aware diffing for Elixir source code.

  Parses two source strings with Sourceror, maps structurally similar AST nodes,
  and produces a diff result with insert, delete, update, and move edits.
  """

  alias ExAST.Diff.Annotated
  alias ExAST.Diff.Classifier
  alias ExAST.Diff.Matcher
  alias ExAST.Diff.Patcher
  alias ExAST.Diff.Render
  alias ExAST.Diff.Result

  @type option :: {:include_moves, boolean()}

  @spec diff(String.t(), String.t(), [option()]) :: Result.t()
  def diff(left_source, right_source, opts \\ []) do
    left = Annotated.from_source(left_source)
    right = Annotated.from_source(right_source)
    mappings = Matcher.match(left, right)
    edits = Classifier.classify(left, right, mappings, opts)

    %Result{
      left: left,
      right: right,
      mappings: mappings,
      edits: edits,
      summary: Render.summary(edits)
    }
  end

  @spec diff_files(String.t(), String.t(), [option()]) :: Result.t()
  def diff_files(left_path, right_path, opts \\ []) do
    diff(File.read!(left_path), File.read!(right_path), opts)
  end

  @doc """
  Applies a diff result to the left source, producing the patched output.

  Updates and deletes are applied via range replacement. Inserts are placed
  at the resolved insertion point based on sibling/parent context.
  Move edits are skipped (content unchanged, only order differs).
  """
  @spec apply(Result.t()) :: String.t()
  defdelegate apply(result), to: Patcher
end
