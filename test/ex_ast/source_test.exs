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
    File.chmod!(path, 0o444)

    assert Source.update(path, fn source -> {source, :unchanged} end) == :unchanged

    File.chmod!(path, 0o644)
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

    assert_raise ArgumentError, ~r/changed while it was updated/, fn ->
      Source.update(path, fn source ->
        File.write!(path, source <> "more\n")
        {source <> "ours\n", :rewritten}
      end)
    end
  end
end
