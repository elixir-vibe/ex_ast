defmodule ExASTTest do
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

      results = ExAST.search(dir, "IO.inspect(_)")
      assert length(results) == 1
      assert [%{file: _, line: 1, source: _, captures: _}] = results

      results = ExAST.search(dir, "IO.inspect(_, _)")
      assert length(results) == 1
    end

    @tag :tmp_dir
    test "includes .exs files from explicit paths, globs, and directories", %{tmp_dir: dir} do
      explicit_file = Path.join(dir, "sample_test.exs")
      nested_dir = Path.join(dir, "nested")
      File.mkdir_p!(nested_dir)
      globbed_file = Path.join(nested_dir, "globbed_test.exs")

      File.write!(explicit_file, "IO.inspect(:explicit)\n")
      File.write!(globbed_file, "IO.inspect(:globbed)\n")

      assert [%{file: ^explicit_file}] = ExAST.search(explicit_file, "IO.inspect(_)")

      assert [%{file: ^globbed_file}] =
               ExAST.search(Path.join(nested_dir, "**/*_test.exs"), "IO.inspect(_)")

      assert [_, _] = ExAST.search(dir, "IO.inspect(_)")
    end

    @tag :tmp_dir
    test "returns full source and captures", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "a.ex"), """
      IO.inspect(data, label: "debug")
      """)

      [match] = ExAST.search(dir, "IO.inspect(expr, _)")
      assert match.source =~ "IO.inspect"
      assert Map.has_key?(match.captures, :expr)
    end
  end

  describe "search_many/3" do
    @tag :tmp_dir
    test "finds named patterns across files", %{tmp_dir: dir} do
      path = Path.join(dir, "a.ex")

      File.write!(path, """
      IO.inspect(data)
      dbg(other)
      """)

      results =
        ExAST.search_many(dir,
          inspect_call: "IO.inspect(expr)",
          dbg_call: "dbg(expr)"
        )

      assert [inspect_match, dbg_match] = results
      assert inspect_match.file == path
      assert inspect_match.pattern == :inspect_call
      assert inspect_match.line == 1
      assert inspect_match.source == "IO.inspect(data)"
      assert dbg_match.pattern == :dbg_call
      assert dbg_match.source == "dbg(other)"
    end

    @tag :tmp_dir
    test "respects limit", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "a.ex"), """
      IO.inspect(a)
      dbg(b)
      """)

      assert [_] =
               ExAST.search_many(dir, [inspect_call: "IO.inspect(_)", dbg_call: "dbg(_)"],
                 limit: 1
               )
    end
  end

  describe "replace/4" do
    @tag :tmp_dir
    test "modifies files and returns count", %{tmp_dir: dir} do
      path = Path.join(dir, "a.ex")

      File.write!(path, """
      IO.inspect(data)
      IO.puts("keep")
      IO.inspect(other)
      """)

      [{^path, 2}] = ExAST.replace(dir, "IO.inspect(expr)", "dbg(expr)")
      content = File.read!(path)
      assert content =~ "dbg(data)"
      assert content =~ "dbg(other)"
      assert content =~ "IO.puts"
    end

    @tag :tmp_dir
    test "modifies .exs files", %{tmp_dir: dir} do
      path = Path.join(dir, "sample_test.exs")
      File.write!(path, "IO.inspect(data)\n")

      [{^path, 1}] = ExAST.replace(path, "IO.inspect(expr)", "dbg(expr)")
      assert File.read!(path) == "dbg(data)\n"
    end

    @tag :tmp_dir
    test "dry run does not modify files", %{tmp_dir: dir} do
      path = Path.join(dir, "a.ex")
      File.write!(path, "IO.inspect(data)\n")

      [{^path, 1}] = ExAST.replace(dir, "IO.inspect(expr)", "dbg(expr)", dry_run: true)
      assert File.read!(path) =~ "IO.inspect"
    end

    @tag :tmp_dir
    test "returns empty list when no matches", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "a.ex"), "IO.puts(:ok)\n")
      assert [] = ExAST.replace(dir, "IO.inspect(_)", "dbg(_)")
    end

    @tag :tmp_dir
    test "can format modified files", %{tmp_dir: dir} do
      path = Path.join(dir, "a.ex")
      File.write!(path, "def run do\n  dbg(  user  )\nend\n")

      [{^path, 1}] = ExAST.replace(path, "dbg(expr)", "expr", format: true)

      assert File.read!(path) == "def run do\n  user\nend"
    end
  end

  describe "rewrite plans" do
    test "expose replacements without applying them" do
      source = "def run do\n  dbg(user)\nend\n"

      plan = ExAST.rewrite_plan(source, "dbg(expr)", "expr")

      assert [%ExAST.Rewriter.Replacement{replacement: "user"}] = plan.replacements
      assert plan.conflicts == []
      assert ExAST.Rewriter.apply(source, plan) == "def run do\n  user\nend\n"
    end
  end

  describe "compiled patterns" do
    test "carry reusable metadata" do
      compiled = ExAST.Pattern.compile("IO.inspect(expr)")

      assert %ExAST.CompiledPattern{multi_node?: false, broad?: false} = compiled
      assert MapSet.member?(compiled.terms, "call.remote:IO.inspect/1")
    end

    test "compile_ast/1 returns the normalized AST for compatibility" do
      compiled = ExAST.Pattern.compile("data |> Enum.map(fun)")

      assert ExAST.Pattern.compile_ast(compiled) ==
               ExAST.Pattern.compile_ast("Enum.map(data, fun)")
    end
  end
end
