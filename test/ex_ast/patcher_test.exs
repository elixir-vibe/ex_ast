defmodule ExAST.PatcherTest do
  # credo:disable-for-this-file Credo.Check.Warning.IoInspect
  # credo:disable-for-this-file Credo.Check.Warning.Dbg
  use ExUnit.Case, async: true

  alias ExAST.Patcher

  describe "find_all/2" do
    test "finds multiple matches" do
      source = """
      IO.inspect(a)
      IO.puts("hello")
      IO.inspect(b, label: "debug")
      """

      matches = Patcher.find_all(source, "IO.inspect(_)")
      assert length(matches) == 1

      matches = Patcher.find_all(source, "IO.inspect(_, _)")
      assert length(matches) == 1
    end

    test "finds struct patterns" do
      source = """
      [
        %Step{id: "subject", title: "Hello"},
        %Step{id: "target", title: "World"},
        %Field{id: "other"}
      ]
      """

      matches = Patcher.find_all(source, ~s(%Step{id: _}))
      assert length(matches) == 2
    end

    test "finds nested patterns" do
      source = """
      defmodule Example do
        def run do
          IO.inspect(1)
          IO.inspect(2)
        end
      end
      """

      matches = Patcher.find_all(source, "IO.inspect(_)")
      assert length(matches) == 2
    end

    test "returns captures" do
      source = ~s(%Step{id: "subject", title: "Hello"})
      [match] = Patcher.find_all(source, ~s(%Step{id: name}))
      assert match.captures[:name] == "subject"
    end

    test "returns source range" do
      source = """
      x = 1
      IO.inspect(data)
      y = 2
      """

      [match] = Patcher.find_all(source, "IO.inspect(_)")
      assert match.range.start[:line] == 2
    end

    test "includes source text in match result for source string input" do
      source = """
      IO.inspect(value)
      Enum.map(list, fn x -> x end)
      IO.inspect(other)
      """

      matches = Patcher.find_all(source, "IO.inspect(name)")
      assert length(matches) == 2

      assert [%{source: "IO.inspect(value)"}, %{source: "IO.inspect(other)"}] = matches
    end

    test "returns nil source for AST input" do
      ast = quote do: IO.inspect(:hello)
      [match] = Patcher.find_all(ast, "IO.inspect(_)")
      assert match.source == nil
    end

    test "source text for multi-line match" do
      source = """
      def run do
        :ok
      end
      """

      [match] = Patcher.find_all(source, "def name do ... end")
      assert match.source =~ "def run do"
      assert match.source =~ ":ok"
      assert match.source =~ "end"
    end
  end

  describe "replace_all/3" do
    test "replaces single match" do
      source = "IO.inspect(data)\n"
      result = Patcher.replace_all(source, "IO.inspect(expr)", "Logger.debug(inspect(expr))")
      assert result =~ "Logger.debug(inspect(data))"
      refute result =~ "IO.inspect"
    end

    test "replaces multiple matches" do
      source = """
      IO.inspect(a)
      x = 1
      IO.inspect(b)
      """

      result = Patcher.replace_all(source, "IO.inspect(expr)", "dbg(expr)")
      assert result =~ "dbg(a)"
      assert result =~ "dbg(b)"
      refute result =~ "IO.inspect"
    end

    test "preserves unmatched code" do
      source = """
      IO.inspect(data)
      IO.puts("keep this")
      """

      result = Patcher.replace_all(source, "IO.inspect(expr)", "dbg(expr)")
      assert result =~ "dbg(data)"
      assert result =~ "IO.puts"
    end

    test "replaces struct with function call" do
      source = """
      [
        %Step{id: "subject", title: "Hello"},
        %Step{id: "other", title: "World"}
      ]
      """

      result =
        Patcher.replace_all(
          source,
          ~s(%Step{id: "subject", title: _}),
          "SharedSteps.subject_step()"
        )

      assert result =~ "SharedSteps.subject_step()"
      assert result =~ ~s(%Step{id: "other")
    end

    test "no match returns source unchanged" do
      source = "IO.puts(:hello)\n"
      result = Patcher.replace_all(source, "IO.inspect(_)", "dbg(_)")
      assert result == source
    end

    test "replaces with captured values" do
      source = ~s(%Step{id: "subject", fields: @my_fields}\n)

      result =
        Patcher.replace_all(
          source,
          ~s(%Step{id: "subject", fields: opts}),
          "build_step(opts)"
        )

      assert result =~ "build_step(@my_fields)"
    end
  end

  describe "where conditions" do
    test "inside filters by ancestor" do
      source = """
      defmodule Example do
        def run do
          IO.inspect(1)
        end

        defp helper do
          IO.inspect(2)
        end
      end
      """

      matches = Patcher.find_all(source, "IO.inspect(_)", inside: "defp _ do _ end")
      assert length(matches) == 1
      assert matches |> hd() |> Map.get(:range) |> get_in([Access.key(:start), :line]) == 7
    end

    test "not_inside excludes by ancestor" do
      source = """
      defmodule Example do
        def run do
          IO.inspect(1)
        end

        test "example" do
          IO.inspect(2)
        end
      end
      """

      matches = Patcher.find_all(source, "IO.inspect(_)", not_inside: "test _ do _ end")
      assert length(matches) == 1
      assert matches |> hd() |> Map.get(:range) |> get_in([Access.key(:start), :line]) == 3
    end

    test "inside and not_inside combined" do
      source = """
      defmodule Example do
        def run do
          if true do
            IO.inspect(1)
          end
          IO.inspect(2)
        end
      end
      """

      matches =
        Patcher.find_all(source, "IO.inspect(_)",
          inside: "def _ do _ end",
          not_inside: "if _ do _ end"
        )

      assert length(matches) == 1
      assert matches |> hd() |> Map.get(:range) |> get_in([Access.key(:start), :line]) == 6
    end

    test "ancestors are not leaked into result" do
      source = """
      def run do
        IO.inspect(1)
      end
      """

      [match] = Patcher.find_all(source, "IO.inspect(_)")
      refute Map.has_key?(match, :ancestors)
    end
  end

  describe "multi-node patterns" do
    test "matches sequential statements" do
      source = """
      def run do
        record = Repo.get!(User, id)
        Repo.delete(record)
      end
      """

      matches = Patcher.find_all(source, "a = Repo.get!(_, _); Repo.delete(a)")
      assert length(matches) == 1
    end

    test "captures are consistent across statements" do
      source = """
      def run do
        record = Repo.get!(User, id)
        Repo.delete(record)
      end
      """

      [match] = Patcher.find_all(source, "a = Repo.get!(_, _); Repo.delete(a)")
      assert Map.has_key?(match.captures, :a)
    end

    test "rejects inconsistent captures" do
      source = """
      def run do
        record = Repo.get!(User, id)
        Repo.delete(other)
      end
      """

      matches = Patcher.find_all(source, "a = Repo.get!(_, _); Repo.delete(a)")
      assert matches == []
    end

    test "non-adjacent statements are not matched" do
      source = """
      def run do
        record = Repo.get!(User, id)
        Logger.info("deleting")
        Repo.delete(record)
      end
      """

      matches = Patcher.find_all(source, "a = Repo.get!(_, _); Repo.delete(a)")
      assert matches == []
    end

    test "range spans all matched nodes" do
      source = """
      def run do
        IO.inspect(1)
        IO.inspect(2)
        IO.inspect(3)
      end
      """

      matches = Patcher.find_all(source, "IO.inspect(1); IO.inspect(2)")
      assert length(matches) == 1
      [match] = matches
      assert match.range.start[:line] == 2
      assert match.range.end[:line] == 3
    end

    test "multi-node with where conditions" do
      source = """
      defmodule A do
        def run do
          x = Repo.get!(User, 1)
          Repo.delete(x)
        end

        test "example" do
          y = Repo.get!(User, 2)
          Repo.delete(y)
        end
      end
      """

      matches =
        Patcher.find_all(
          source,
          "a = Repo.get!(_, _); Repo.delete(a)",
          not_inside: "test _ do _ end"
        )

      assert length(matches) == 1
      assert matches |> hd() |> Map.get(:range) |> get_in([Access.key(:start), :line]) == 3
    end
  end

  describe "find_all/3 with AST input" do
    test "accepts raw AST" do
      ast = Sourceror.parse_string!("IO.inspect(data)")
      [match] = Patcher.find_all(ast, "IO.inspect(_)")
      assert match.captures == %{}
    end

    test "accepts Sourceror zipper" do
      zipper = "IO.inspect(data)" |> Sourceror.parse_string!() |> Sourceror.Zipper.zip()
      [match] = Patcher.find_all(zipper, "IO.inspect(_)")
      assert match.captures == %{}
    end

    test "captures work with AST input" do
      ast = Sourceror.parse_string!(~s(%Step{id: "subject", title: "Hello"}))
      [match] = Patcher.find_all(ast, ~s(%Step{id: name}))
      assert match.captures[:name] == "subject"
    end

    test "finds nested patterns in AST" do
      ast =
        Sourceror.parse_string!("""
        defmodule Example do
          def run do
            IO.inspect(1)
            IO.inspect(2)
          end
        end
        """)

      matches = Patcher.find_all(ast, "IO.inspect(_)")
      assert length(matches) == 2
    end

    test "inside/not_inside work with AST input" do
      ast =
        Sourceror.parse_string!("""
        defmodule Example do
          def run, do: IO.inspect(1)
          defp helper, do: IO.inspect(2)
        end
        """)

      matches = Patcher.find_all(ast, "IO.inspect(_)", inside: "defp _ do _ end")
      assert length(matches) == 1
    end

    test "range is nil for nodes without position metadata" do
      ast = Code.string_to_quoted!("IO.inspect(data)")
      [match] = Patcher.find_all(ast, "IO.inspect(_)")
      assert match.range == nil
    end
  end

  describe "replace_all/4 with AST input" do
    test "returns modified AST from raw AST" do
      ast = Sourceror.parse_string!("IO.inspect(data)")
      result = Patcher.replace_all(ast, "IO.inspect(expr)", "dbg(expr)")
      assert Macro.to_string(result) =~ "dbg(data)"
    end

    test "returns modified AST from zipper" do
      zipper = "IO.inspect(data)" |> Sourceror.parse_string!() |> Sourceror.Zipper.zip()
      result = Patcher.replace_all(zipper, "IO.inspect(expr)", "dbg(expr)")
      assert Macro.to_string(result) =~ "dbg(data)"
    end

    test "substitutes captures in replacement" do
      ast =
        Sourceror.parse_string!("""
        defmodule A do
          def run do
            IO.inspect(data, label: "debug")
          end
        end
        """)

      result = Patcher.replace_all(ast, "IO.inspect(expr, _)", "Logger.debug(expr)")
      source = Macro.to_string(result)
      assert source =~ "Logger.debug(data)"
      refute source =~ "IO.inspect"
    end

    test "preserves unmatched nodes" do
      ast =
        Sourceror.parse_string!("""
        IO.inspect(data)
        IO.puts("keep")
        """)

      result = Patcher.replace_all(ast, "IO.inspect(expr)", "dbg(expr)")
      source = Macro.to_string(result)
      assert source =~ "dbg(data)"
      assert source =~ "IO.puts"
    end

    test "no match returns AST unchanged" do
      ast = Sourceror.parse_string!("IO.puts(:hello)")
      result = Patcher.replace_all(ast, "IO.inspect(_)", "dbg(_)")
      assert result == ast
    end

    test "inside/not_inside work with AST replacement" do
      ast =
        Sourceror.parse_string!("""
        defmodule A do
          def run, do: IO.inspect(1)
          defp helper, do: IO.inspect(2)
        end
        """)

      result =
        Patcher.replace_all(ast, "IO.inspect(expr)", "dbg(expr)", inside: "defp _ do _ end")

      source = inspect(result, limit: :infinity)
      assert source =~ ":inspect"
      assert source =~ ":dbg"
    end
  end

  describe "quoted patterns" do
    test "find_all accepts quoted pattern" do
      source = "IO.inspect(data)"
      matches = Patcher.find_all(source, quote(do: IO.inspect(_)))
      assert [%{captures: %{}}] = matches
    end

    test "find_all with quoted captures" do
      source = "Enum.map(list, fun)"
      [match] = Patcher.find_all(source, quote(do: Enum.map(input, mapper)))
      assert Map.has_key?(match.captures, :input)
      assert Map.has_key?(match.captures, :mapper)
    end

    test "replace_all with quoted pattern and replacement on source string" do
      source = "IO.inspect(data)\n"
      result = Patcher.replace_all(source, quote(do: IO.inspect(expr)), quote(do: dbg(expr)))
      assert result =~ "dbg(data)"
      refute result =~ "IO.inspect"
    end

    test "replace_all with quoted on AST" do
      ast = Sourceror.parse_string!("IO.inspect(data)")
      result = Patcher.replace_all(ast, quote(do: IO.inspect(expr)), quote(do: dbg(expr)))
      assert Macro.to_string(result) =~ "dbg(data)"
    end

    test "find_all with quoted inside/not_inside" do
      source = """
      defmodule A do
        def run, do: IO.inspect(1)
        defp helper, do: IO.inspect(2)
      end
      """

      matches =
        Patcher.find_all(source, quote(do: IO.inspect(_)), inside: quote(do: defp(_, do: _)))

      assert [_] = matches
    end

    test "mixed string and quoted" do
      source = "IO.inspect(data)\n"
      result = Patcher.replace_all(source, "IO.inspect(expr)", quote(do: dbg(expr)))
      assert result =~ "dbg(data)"
    end

    test "quoted struct partial match" do
      source = ~s(%Step{id: "subject", title: "Hello"})
      [match] = Patcher.find_all(source, quote(do: %Step{id: name}))
      assert match.captures[:name] == "subject"
    end
  end

  describe "ellipsis matching" do
    test "find_all matches any arity with ellipsis" do
      source = """
      IO.inspect(a)
      IO.puts("hello")
      IO.inspect(b, label: "x")
      """

      matches = Patcher.find_all(source, "IO.inspect(...)")
      assert length(matches) == 2
    end

    test "find_all with capture + ellipsis" do
      source = "Enum.reduce(list, 0, &+/2)"
      [match] = Patcher.find_all(source, "Enum.reduce(collection, ...)")
      assert Map.has_key?(match.captures, :collection)
    end

    test "replace_all with ellipsis pattern" do
      source = """
      Logger.debug("a")
      Logger.debug("b", extra: true)
      Logger.info("keep")
      """

      result = Patcher.replace_all(source, "Logger.debug(...)", "Logger.warning(...)")
      assert result =~ "Logger.warning"
      assert result =~ "Logger.info"
      refute result =~ "Logger.debug"
    end

    test "find_all with def ... end matches any body" do
      source = """
      defmodule A do
        def foo do
          1
          2
          3
        end

        def bar, do: :ok
      end
      """

      matches = Patcher.find_all(source, "def _ do ... end")
      assert length(matches) == 2
    end

    test "find_all with ellipsis matches any function args" do
      source = """
      defmodule A do
        def run(a, b, c), do: :ok
        def run(x), do: :error
      end
      """

      matches = Patcher.find_all(source, "def run(...) do ... end")
      assert length(matches) == 2
    end
  end
end
