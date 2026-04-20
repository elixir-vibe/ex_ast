defmodule ExAST.Diff.Render do
  @moduledoc false

  alias ExAST.Diff.Edit

  @spec summary([Edit.t()]) :: [String.t()]
  def summary(edits), do: Enum.map(edits, & &1.summary)

  @spec node_source(Macro.t()) :: String.t()
  def node_source(node) do
    Sourceror.to_string(node)
  rescue
    _ -> safe_to_string(node)
  catch
    _, _ -> safe_to_string(node)
  end

  defp safe_to_string(node) do
    Macro.to_string(node)
  rescue
    _ -> inspect(node, pretty: true, limit: 50)
  catch
    _, _ -> inspect(node, pretty: true, limit: 50)
  end
end
