defmodule ExAST.Diff.Edit do
  @moduledoc """
  A single syntax-aware edit between two Elixir sources.
  """

  @type op :: :insert | :delete | :update | :move

  @type t :: %__MODULE__{
          op: op(),
          kind: atom(),
          summary: String.t(),
          old_id: non_neg_integer() | nil,
          new_id: non_neg_integer() | nil,
          old_range: Sourceror.Range.t() | nil,
          new_range: Sourceror.Range.t() | nil,
          meta: map()
        }

  @enforce_keys [:op, :kind, :summary]
  defstruct [:op, :kind, :summary, :old_id, :new_id, :old_range, :new_range, meta: %{}]
end
