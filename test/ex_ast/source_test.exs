defmodule ExAST.SourceTest do
  use ExUnit.Case, async: false

  alias ExAST.Source

  @tag :tmp_dir
  test "writes the rewritten content and returns the rewrite's result", %{tmp_dir: dir} do
    path = Path.join(dir, "a.ex")
    File.write!(path, "one\n")

    assert Source.update(path, fn source -> {source <> "two\n", :rewritten} end) == :rewritten
    assert File.read!(path) == "one\ntwo\n"
  end

  @tag :tmp_dir
  test "writes nothing when the rewrite leaves the content unchanged", %{tmp_dir: dir} do
    path = Path.join(dir, "a.ex")
    File.write!(path, "one\n")

    # A write is only visible in the mtime when the file does not already have the current second.
    File.touch!(path, {{2000, 1, 1}, {0, 0, 0}})
    written_at = File.stat!(path, time: :posix).mtime

    assert Source.update(path, fn source -> {source, :unchanged} end) == :unchanged

    assert File.stat!(path, time: :posix).mtime == written_at
    assert File.read!(path) == "one\n"
  end

  @tag :tmp_dir
  test "rewrites from a fresh read when another writer changed the file", %{tmp_dir: dir} do
    path = Path.join(dir, "a.ex")
    File.write!(path, "start\n")

    assert Source.update(path, fn source ->
             unless Process.get(:foreign_write) do
               Process.put(:foreign_write, true)
               File.write!(path, source <> "foreign\n")
             end

             {source <> "ours\n", :rewritten}
           end) == :rewritten

    assert File.read!(path) == "start\nforeign\nours\n"
  end

  @tag :tmp_dir
  test "raises when the file keeps changing", %{tmp_dir: dir} do
    path = Path.join(dir, "a.ex")
    File.write!(path, "start\n")

    assert_raise ExAST.Source.ConcurrentUpdateError, ~r/changed while it was updated/, fn ->
      Source.update(path, fn source ->
        File.write!(path, source <> "more\n")
        {source <> "ours\n", :rewritten}
      end)
    end
  end
end
