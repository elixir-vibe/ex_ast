defmodule ExAST.Source.ConcurrentUpdateError do
  @moduledoc """
  Raised when a file keeps changing while it is rewritten.

  `ExAST.replace/4` rewrites a file from a fresh read when another writer changed it first, and
  gives up with this error when the file keeps changing.
  """

  @type t :: %__MODULE__{path: Path.t()}

  defexception [:path]

  def message(%{path: path}), do: "#{path} changed while it was updated; run the update again"
end
