defmodule ExAstTest do
  use ExUnit.Case, async: true

  describe "search/2" do
    @tag :tmp_dir
    test "finds matches across files", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "a.ex"), """
      IO.inspect(x)
      IO.puts("hello")
      """)

      File.write!(Path.join(dir, "b.ex"), """
      IO.inspect(y, label: "debug")
      """)

      results = ExAst.search(dir, "IO.inspect(_)")
      assert length(results) == 1

      results = ExAst.search(dir, "IO.inspect(_, _)")
      assert length(results) == 1
    end
  end

  describe "replace/4" do
    @tag :tmp_dir
    test "modifies files in place", %{tmp_dir: dir} do
      path = Path.join(dir, "a.ex")

      File.write!(path, """
      IO.inspect(data)
      IO.puts("keep")
      """)

      [^path] = ExAst.replace(dir, "IO.inspect(expr)", "dbg(expr)")
      content = File.read!(path)
      assert content =~ "dbg(data)"
      assert content =~ "IO.puts"
    end

    @tag :tmp_dir
    test "dry run does not modify files", %{tmp_dir: dir} do
      path = Path.join(dir, "a.ex")
      File.write!(path, "IO.inspect(data)\n")

      ExAst.replace(dir, "IO.inspect(expr)", "dbg(expr)", dry_run: true)
      assert File.read!(path) =~ "IO.inspect"
    end
  end
end
