defmodule ExAST.CompiledPattern do
  @moduledoc """
  Precomputed metadata for an ExAST pattern.
  """

  @type t :: %__MODULE__{
          ast: Macro.t(),
          original: term(),
          signature: term(),
          terms: MapSet.t(String.t()),
          multi_node?: boolean(),
          broad?: boolean()
        }

  @enforce_keys [:ast, :original, :signature, :terms, :multi_node?, :broad?]
  defstruct [:ast, :original, :signature, :terms, :multi_node?, :broad?]

  @spec new(keyword()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
