defmodule ExAST.PatchConflict do
  @moduledoc """
  Describes overlapping replacement ranges in a rewrite plan.
  """

  @type t :: %__MODULE__{
          first_range: Sourceror.Range.t(),
          second_range: Sourceror.Range.t(),
          reason: :overlapping_replacements
        }

  @enforce_keys [:first_range, :second_range, :reason]
  defstruct [:first_range, :second_range, :reason]
end

defimpl Jason.Encoder, for: ExAST.PatchConflict do
  def encode(conflict, opts) do
    Jason.Encode.map(
      %{
        first_range: conflict.first_range,
        second_range: conflict.second_range,
        reason: conflict.reason
      },
      opts
    )
  end
end
