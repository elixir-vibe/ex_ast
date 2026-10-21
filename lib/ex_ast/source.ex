defmodule ExAST.Source do
  @moduledoc """
  Serializes updates of one source file and rewrites from a fresh read.

  Updating a file is a read, a rewrite and a write. Two updates of the same file at once would
  each rewrite the source they read, so all but the last write is lost. `update/3` serializes
  updates of one file in this node, and rewrites from a fresh read when the file changed while
  it was updating.

  The check before the write only narrows the window for a writer outside this node, an editor
  or another tool: the write is not atomic, so a change that lands between the check and the
  write is still overwritten.
  """

  @attempts 3

  @doc """
  Reads `path`, rewrites the content with `fun` and writes it back.

  `fun` receives the file's content and returns `{rewritten, result}`. The file is written only
  when `rewritten` differs from the content that was read, and `fun` runs again on a fresh read
  when another writer changed the file first. Returns the `result` of the rewrite that was
  written, and raises `ExAST.Source.ConcurrentUpdateError` when the file keeps changing.
  """
  @spec update(Path.t(), (String.t() -> {String.t(), result}), pos_integer()) :: result
        when result: var
  def update(path, fun, attempts \\ @attempts) do
    :global.trans(
      {{__MODULE__, Path.expand(path)}, self()},
      fn -> attempt(path, fun, attempts) end,
      [
        node()
      ]
    )
  end

  defp attempt(path, fun, attempts) do
    source = File.read!(path)
    {rewritten, result} = fun.(source)

    cond do
      rewritten == source ->
        result

      File.read!(path) == source ->
        File.write!(path, rewritten)
        result

      attempts > 1 ->
        attempt(path, fun, attempts - 1)

      true ->
        raise ExAST.Source.ConcurrentUpdateError, path: path
    end
  end
end
