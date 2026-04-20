defmodule ExAST.Diff.Result do
  @moduledoc """
  The result of comparing two Elixir sources.
  """

  alias ExAST.Diff.Annotated
  alias ExAST.Diff.Edit

  @type t :: %__MODULE__{
          left: Annotated.t(),
          right: Annotated.t(),
          mappings: %{non_neg_integer() => non_neg_integer()},
          edits: [Edit.t()],
          summary: [String.t()]
        }

  @enforce_keys [:left, :right]
  defstruct [:left, :right, mappings: %{}, edits: [], summary: []]
end
