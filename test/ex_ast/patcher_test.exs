defmodule ExAST.PatcherTest do
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
end
