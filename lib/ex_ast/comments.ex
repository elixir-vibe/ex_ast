defmodule ExAST.Comments do
  @moduledoc """
  Extracts comments from Elixir source while preserving source positions.
  """

  alias ExAST.Comment

  @spec extract(String.t()) :: [Comment.t()]
  def extract(source) when is_binary(source) do
    {_ast, comments} = Code.string_to_quoted_with_comments!(source)

    Enum.map(comments, fn comment ->
      %Comment{
        text: Map.get(comment, :text, ""),
        line: Map.get(comment, :line),
        column: Map.get(comment, :column),
        previous_eol_count: Map.get(comment, :previous_eol_count),
        next_eol_count: Map.get(comment, :next_eol_count)
      }
    end)
  end

  @spec text(String.t()) :: String.t()
  def text(source) when is_binary(source) do
    source
    |> extract()
    |> Enum.map_join("\n", & &1.text)
  end

  @doc """
  Returns comments associated with a source range.

  Relations are `:comment`, `:before`, `:after`, `:inside`, and `:inline`.
  `:comment` includes before, inside, and inline comments.
  """
  @spec associated(String.t(), Sourceror.Range.t(), atom()) :: [Comment.t()]
  def associated(source, range, relation \\ :comment) when is_binary(source) do
    source
    |> extract()
    |> Enum.filter(&in_relation?(&1, relation, range))
  end

  defp in_relation?(comment, relation, %{start: start, end: end_}) do
    start_line = start[:line]
    start_column = start[:column] || 1
    end_line = end_[:line]
    end_column = end_[:column] || start_column

    comment_in_relation?(comment, relation, start_line, start_column, end_line, end_column)
  end

  defp comment_in_relation?(comment, :comment, start_line, start_column, end_line, end_column) do
    comment_in_relation?(comment, :before, start_line, start_column, end_line, end_column) or
      comment_in_relation?(comment, :inside, start_line, start_column, end_line, end_column) or
      comment_in_relation?(comment, :inline, start_line, start_column, end_line, end_column)
  end

  defp comment_in_relation?(comment, :before, start_line, _start_column, _end_line, _end_column),
    do: comment.line < start_line and comment.line + comment.next_eol_count == start_line

  defp comment_in_relation?(comment, :after, _start_line, _start_column, end_line, _end_column),
    do: comment.line > end_line and comment.line - comment.previous_eol_count == end_line

  defp comment_in_relation?(comment, :inside, start_line, _start_column, end_line, _end_column),
    do: comment.line >= start_line and comment.line <= end_line

  defp comment_in_relation?(comment, :inline, start_line, _start_column, end_line, end_column),
    do: start_line == end_line and comment.line == start_line and comment.column >= end_column

  defp comment_in_relation?(
         _comment,
         _relation,
         _start_line,
         _start_column,
         _end_line,
         _end_column
       ),
       do: false
end
