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

  describe "find_all/2 with piped calls (arity)" do
    test "piped call matches only its normalized arity, not the raw RHS" do
      assert [_] = Patcher.find_all("x |> f(a)", "f(_, _)")
      assert Patcher.find_all("x |> f(a)", "f(_)") == []
    end

    test "piped 2-arg call matches normalized arity 3, not raw arity 2" do
      assert [_] = Patcher.find_all("x |> f(a, b)", "f(_, _, _)")
      assert Patcher.find_all("x |> f(a, b)", "f(_, _)") == []
    end

    test "un-piped call still matches its written arity" do
      assert [_] = Patcher.find_all("f(a)", "f(_)")
    end

    test "nested call inside a piped RHS still matches" do
      assert Patcher.find_all("x |> f(g(a))", "f(_)") == []
      assert [_] = Patcher.find_all("x |> f(g(a))", "f(_, _)")
      assert [_] = Patcher.find_all("x |> f(g(a))", "g(_)")
    end

    test "remote piped call matches only normalized arity" do
      assert [_] = Patcher.find_all("x |> Enum.map(f)", "Enum.map(_, _)")
      assert Patcher.find_all("x |> Enum.map(f)", "Enum.map(_)") == []
    end

    test "chained pipes match each normalized arity but no raw RHS" do
      source = "a |> b(x) |> c(y)"
      assert [_] = Patcher.find_all(source, "b(_, _)")
      assert [_] = Patcher.find_all(source, "c(_, _)")
      assert Patcher.find_all(source, "b(_)") == []
      assert Patcher.find_all(source, "c(_)") == []
    end
  end

  describe "find_many/2 with piped calls (arity)" do
    test "piped call does not spuriously match a lower-arity pattern" do
      matches =
        Patcher.find_many("x |> Enum.map(f)", %{
          low: "Enum.map(_)",
          high: "Enum.map(_, _)"
        })

      assert Enum.map(matches, & &1.pattern) == [:high]
    end
  end

  describe "find_all/2 with list ellipsis patterns" do
    test "[...] matches any list, including empty" do
      assert [_] = Patcher.find_all("[1, 2, 3]", "[...]")
      assert [_] = Patcher.find_all("[]", "[...]")
      assert [_] = Patcher.find_all("[:only]", "[...]")
    end

    test "[1, ...] matches lists with a leading fixed element only" do
      assert [_] = Patcher.find_all("[1, 2, 3]", "[1, ...]")
      assert [_] = Patcher.find_all("[1]", "[1, ...]")
      assert Patcher.find_all("[2, 3]", "[1, ...]") == []
    end

    test "[..., x] matches and captures the trailing element" do
      assert [%{captures: %{x: 3}}] = Patcher.find_all("[1, 2, 3]", "[..., x]")
    end

    test "[1, ..., z] matches leading and trailing fixed elements" do
      assert [%{captures: %{z: 3}}] = Patcher.find_all("[1, 2, 3]", "[1, ..., z]")
      assert Patcher.find_all("[9, 2, 3]", "[1, ..., z]") == []
    end

    test "ellipsis absorbs a variable-length middle" do
      assert [_] = Patcher.find_all("[1, 2, 3, 4, 5]", "[1, ..., z]")
      assert [_] = Patcher.find_all("[1, 2]", "[1, ..., z]")
    end

    test "[x, y, z, ...] captures multiple leading elements" do
      assert [%{captures: %{x: 10, y: 20, z: 30}}] =
               Patcher.find_all("[10, 20, 30, 40, 50]", "[x, y, z, ...]")

      assert Patcher.find_all("[10, 20]", "[x, y, z, ...]") == []
    end

    test "[..., y, z] captures multiple trailing elements" do
      assert [%{captures: %{y: 40, z: 50}}] =
               Patcher.find_all("[10, 20, 30, 40, 50]", "[..., y, z]")
    end

    test "[first, second, ..., last] captures on both sides of the ellipsis" do
      assert [%{captures: %{first: 10, second: 20, last: 50}}] =
               Patcher.find_all("[10, 20, 30, 40, 50]", "[first, second, ..., last]")
    end

    test "fixed-length list patterns still match exactly (regression)" do
      assert [_] = Patcher.find_all("[1, 2, 3]", "[1, 2, 3]")
      assert [_] = Patcher.find_all("[1, 2, 3]", "[_, _, _]")
      assert Patcher.find_all("[1, 2, 3]", "[_, _]") == []
    end

    test "a literal is matched once, not once per Sourceror block wrapper" do
      assert [_] = Patcher.find_all("f([:a, :b])", "[...]")
      assert [_] = Patcher.find_all("f(42)", "42")
      assert [_] = Patcher.find_all("f(:hello)", ":hello")
      assert [_] = Patcher.find_all("f(\"hi\")", "\"hi\"")
    end
  end

  describe "replace_all/3" do
    test "replaces single match" do
      source = "IO.inspect(data)\n"
      result = Patcher.replace_all(source, "IO.inspect(expr)", "Logger.debug(inspect(expr))")
      assert result =~ "Logger.debug(inspect(data))"
      refute result =~ "IO.inspect"
    end

    test "keeps escape sequences in a captured string" do
      source = ~S|IO.puts("a\n\tb \"q\"")| <> "\n"
      result = Patcher.replace_all(source, "IO.puts(x)", "Logger.info(x)")
      assert result == ~S|Logger.info("a\n\tb \"q\"")| <> "\n"
    end

    test "keeps escape sequences in a captured interpolated string" do
      source = ~S|IO.puts("dir\\file \#{literal} #{name}\n\t\"q\"")| <> "\n"
      result = Patcher.replace_all(source, "IO.puts(x)", "Logger.info(x)")
      assert result == ~S|Logger.info("dir\\file \#{literal} #{name}\n\t\"q\"")| <> "\n"
    end

    test "keeps escape sequences in an interpolated replacement string" do
      source = "IO.puts(name)\n"
      result = Patcher.replace_all(source, "IO.puts(x)", ~S|Logger.info("dir\\#{x}\n")|)
      assert result == ~S|Logger.info("dir\\#{name}\n")| <> "\n"
    end

    test "leaves sigils and bitstrings in a replacement as written" do
      source = "IO.puts(name)\n"
      replacement = ~S|Logger.info({~r/a\n#{x}/, ~S"raw\n", <<1::8, "a\nb">>})|

      assert Patcher.replace_all(source, "IO.puts(x)", replacement) ==
               ~S|Logger.info({~r/a\n#{name}/, ~S"raw\n", <<1::8, "a\nb">>})| <> "\n"
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

    test "keeps an attribute that appears in the pattern and the replacement" do
      source = """
      defmodule Example do
        def cleanup do
          Process.delete(@fragment_epoch)
        end
      end
      """

      result =
        Patcher.replace_all(
          source,
          "Process.delete(@fragment_epoch)",
          "Process.delete(@fragment_epoch)"
        )

      assert result =~ "Process.delete(@fragment_epoch)"
      refute result =~ "@:"
    end

    test "substitutes a captured attribute name" do
      source = """
      @env Application.get_env(:app, :key)
      """

      assert Patcher.replace_all(
               source,
               "@name Application.get_env(:app, :key)",
               "@name Application.get_env(:app, :other_key)"
             ) =~ "@env Application.get_env(:app, :other_key)"
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

    test "renders with Sourceror when captures are literals" do
      source = ~S"""
      IO.puts(:ok)
      IO.puts(42)
      IO.puts("dir\\file\n\"q\"")
      IO.puts("hi \#{lit} #{name}\n")
      """

      result =
        source
        |> Sourceror.parse_string!()
        |> Sourceror.Zipper.zip()
        |> Patcher.replace_all("IO.puts(x)", "Logger.info(x, label: :out)")

      assert Sourceror.to_string(result) <> "\n" == ~S"""
             Logger.info(:ok, label: :out)
             Logger.info(42, label: :out)
             Logger.info("dir\\file\n\"q\"", label: :out)
             Logger.info("hi \#{lit} #{name}\n", label: :out)
             """
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

  describe "candidate prefiltering" do
    test "keeps module attribute patterns with nested remote calls" do
      source = """
      @name Application.get_env(:app, :name)
      @other :literal
      """

      assert [%{source: "@name Application.get_env(:app, :name)"}] =
               Patcher.find_all(source, "@_ Application.get_env(_, _)")
    end

    test "keeps nested remote calls under aliases" do
      source = """
      alias Application, as: App
      @name App.get_env(:app, :name)
      """

      assert [%{source: "@name App.get_env(:app, :name)"}] =
               Patcher.find_all(source, "@_ Application.get_env(_, _)")
    end

    test "keeps patterns with nested calls inside arguments" do
      source = "wrap(Application.get_env(:app, :name))"

      assert [%{source: "wrap(Application.get_env(:app, :name))"}] =
               Patcher.find_all(source, "wrap(Application.get_env(_, _))")
    end

    test "keeps piped calls matched by direct-call patterns" do
      source = "data |> Enum.map(&to_string/1)"

      assert [%{source: "data |> Enum.map(&to_string/1)"}] =
               Patcher.find_all(source, "Enum.map(_, _)")
    end

    test "keeps each matching stage in a pipe chain" do
      source = """
      conn
      |> assert_has(".a", checked: true)
      |> assert_has(".b", checked: true)
      """

      assert [outer, inner] = Patcher.find_all(source, "assert_has(_, _, checked: _)")
      assert outer.source =~ ~s|assert_has(".b", checked: true)|
      assert inner.source =~ ~s|assert_has(".a", checked: true)|
    end

    test "keeps explicit pipe patterns" do
      source = "Enum.reverse(values) |> hd()"

      assert [%{source: "Enum.reverse(values) |> hd()"}] =
               Patcher.find_all(source, "Enum.reverse(_) |> hd()")
    end

    test "keeps nested piped calls" do
      source = "@items list |> Enum.map(fun)"

      assert [%{source: "@items list |> Enum.map(fun)"}] =
               Patcher.find_all(source, "@_ Enum.map(_, _)")
    end

    test "keeps nested calls in batched scans" do
      source = """
      @name Application.get_env(:app, :name)
      dbg(value)
      """

      assert [%{pattern: :env}, %{pattern: :debug}] =
               Patcher.find_many(source,
                 env: "@_ Application.get_env(_, _)",
                 debug: "dbg(_)"
               )
    end

    test "does not reject broad nested captures" do
      source = "wrap(dynamic(:value))"

      assert [%{captures: %{expr: {:dynamic, nil, [:value]}}}] =
               Patcher.find_all(source, "wrap(expr)")
    end
  end

  describe "find_many/3" do
    test "finds multiple named patterns in one source scan" do
      source = """
      IO.inspect(value)
      dbg(other)
      IO.puts("keep")
      """

      matches =
        Patcher.find_many(source,
          inspect_call: "IO.inspect(expr)",
          dbg_call: "dbg(expr)"
        )

      assert [inspect_match, dbg_match] = matches
      assert inspect_match.pattern == :inspect_call
      assert inspect_match.source == "IO.inspect(value)"
      assert inspect_match.captures[:expr] == {:value, nil, nil}
      assert dbg_match.pattern == :dbg_call
      assert dbg_match.source == "dbg(other)"
    end

    test "accepts maps of named patterns" do
      source = "IO.inspect(value)"

      assert [%{pattern: :inspect_call}] =
               Patcher.find_many(source, %{inspect_call: "IO.inspect(_)"})
    end

    test "respects inside filters" do
      source = """
      defmodule A do
        def run, do: IO.inspect(1)
        defp helper, do: IO.inspect(2)
      end
      """

      matches =
        Patcher.find_many(source, [inspect_call: "IO.inspect(expr)"], inside: "defp _ do _ end")

      assert [%{source: "IO.inspect(2)", pattern: :inspect_call}] = matches
    end

    test "finds single-step selectors with tagged results" do
      import ExAST.Query

      source = """
      Enum.into(opts, %{})
      Enum.into(opts, %{a: 1})
      text |> Regex.replace(~r/foo/, "")
      Regex.replace(~r/foo/, text, "")
      """

      matches =
        Patcher.find_many(source,
          into_empty_map:
            from("Enum.into(_, target)")
            |> where(match?({:%{}, _, []}, ^target)),
          piped_replace:
            from("Regex.replace(_, _, _)")
            |> where(piped())
        )

      assert Enum.map(matches, & &1.pattern) == [:into_empty_map, :piped_replace]

      assert Enum.map(matches, & &1.source) == [
               "Enum.into(opts, %{})",
               "text |> Regex.replace(~r/foo/, \"\")"
             ]
    end

    test "batched selectors respect find_many inside and not_inside options" do
      import ExAST.Query

      source = """
      def public do
        IO.inspect(:public)
      end

      defp private do
        IO.inspect(:private)
      end
      """

      selector = from("IO.inspect(value)") |> where(match?(atom when is_atom(atom), ^value))

      assert [%{pattern: :inspect_atom, source: "IO.inspect(:private)"}] =
               Patcher.find_many(source, [inspect_atom: selector], inside: "defp _ do ... end")

      assert [%{pattern: :inspect_atom, source: "IO.inspect(:public)"}] =
               Patcher.find_many(source, [inspect_atom: selector],
                 not_inside: "defp _ do ... end"
               )
    end

    test "batched selectors preserve comment filters" do
      import ExAST.Query

      source = """
      # generated helper
      def generated do
        :ok
      end

      def regular do
        :ok
      end
      """

      assert [%{pattern: :generated, source: source_fragment}] =
               Patcher.find_many(source,
                 generated:
                   from("def name do ... end")
                   |> where(comment_before("generated helper"))
               )

      assert source_fragment =~ "def generated"
    end

    test "multi-step selectors still return tagged fallback results" do
      import ExAST.Selector

      source = """
      defmodule Example do
        def run do
          IO.inspect(:ok)
        end
      end
      """

      selector =
        pattern("defmodule Example do ... end")
        |> descendant("IO.inspect(value)")

      assert [%{pattern: :nested_inspect, captures: %{value: :ok}}] =
               Patcher.find_many(source, nested_inspect: selector)
    end

    test "batched selectors do not change nested single-pattern blocking" do
      source = """
      IO.inspect(IO.inspect(value))
      """

      assert [%{pattern: :inspect, source: "IO.inspect(IO.inspect(value))"}] =
               Patcher.find_many(source, inspect: "IO.inspect(_)")
    end

    test "falls back for sequence patterns with tagged results" do
      source = """
      a = Repo.get!(User, id)
      Repo.delete(a)
      """

      assert [%{pattern: :delete_after_get}] =
               Patcher.find_many(source,
                 delete_after_get: "a = Repo.get!(_, _); Repo.delete(a)"
               )
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

      assert result == """
             Logger.warning("a")
             Logger.warning("b", extra: true)
             Logger.info("keep")
             """

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

  describe "replace_all/3 with ... in the replacement" do
    defp replace(source, pattern, replacement),
      do: source |> Patcher.replace_all(pattern, replacement) |> String.trim_trailing()

    test "splices the arguments a trailing ... matched" do
      pattern = "Logger.debug(msg, ...)"
      replacement = "Logger.warning(msg, ...)"

      assert replace("Logger.debug(msg)", pattern, replacement) == "Logger.warning(msg)"

      assert replace("Logger.debug(msg, meta)", pattern, replacement) ==
               "Logger.warning(msg, meta)"

      assert replace(~S|Logger.debug(msg, label: "a", limit: 5)|, pattern, replacement) ==
               ~S|Logger.warning(msg, label: "a", limit: 5)|
    end

    test "moves leading and middle arguments" do
      assert replace("foo(a, b, last)", "foo(..., last)", "bar(last, ...)") == "bar(last, a, b)"
      assert replace("foo(a, b, c, d)", "foo(a, ..., d)", "bar(d, ..., a)") == "bar(d, b, c, a)"
    end

    test "merges a trailing keyword list with the replacement's options" do
      replacement = "Logger.info(x, ..., limit: 5)"

      assert replace(~S|IO.inspect(x, label: "a")|, "IO.inspect(x, ...)", replacement) ==
               ~S|Logger.info(x, label: "a", limit: 5)|

      assert replace("IO.inspect(x)", "IO.inspect(x, ...)", replacement) ==
               "Logger.info(x, limit: 5)"

      assert replace("IO.inspect(x, [1, 2])", "IO.inspect(x, ...)", replacement) ==
               "Logger.info(x, [1, 2], limit: 5)"
    end

    test "reuses a single ... wherever the replacement has one" do
      assert replace("f(a, b)", "f(...)", "g(...) && h(...)") == "g(a, b) && h(a, b)"
    end

    test "maps several ... in order" do
      source = """
      def run(a, b) do
        x = a + b
        x * 2
      end
      """

      assert replace(source, "def run(...) do ... end", "defp run(...) do ... end") == """
             defp run(a, b) do
               x = a + b
               x * 2
             end\
             """

      assert replace("outer(inner(1, 2), 3)", "outer(inner(...), ...)", "swap(...)(...)") ==
               "swap(1, 2)(3)"
    end

    test "raises when several ... don't line up with the replacement" do
      assert_raise ArgumentError, ~r/replacement has 1 `...` but the pattern has 2/, fn ->
        Patcher.replace_all("def run(a), do: a", "def run(...) do ... end", "defp run(...)")
      end
    end

    test "drops what ... matched when the replacement has none" do
      assert replace("def run(a), do: a", "def run(...) do ... end", "defp run") == "defp run"
    end

    test "keeps ... as written when the pattern has none" do
      assert replace("spec(x)", "spec(x)", "@spec f(x) :: [...]") == "@spec f(x) :: [...]"
    end

    test "splices block bodies" do
      source = """
      def run do
        a()
        b()
      end
      """

      replacement = """
      def run do
        log()
        ...
      end
      """

      assert replace(source, "def run do ... end", replacement) == """
             def run do
               log()
               a()
               b()
             end\
             """

      assert replace("def run, do: log(a)", "def run, do: ...", replacement) ==
               "def run do\n  log()\n  log(a)\nend"
    end

    test "splices list and tuple elements" do
      assert replace("[1, 2, 3]", "[first, ...]", "[..., first]") == "[2, 3, 1]"
      assert replace("{:ok, a, b}", "{:ok, ...}", "{:error, ...}") == "{:error, a, b}"
      assert replace("{:ok}", "{:ok, ...}", "{:error, ...}") == "{:error}"
    end

    test "splices the remaining map and struct pairs" do
      assert replace("%{a: 1, b: 2, c: 3}", "%{..., a: x}", "%{..., z: x}") ==
               "%{b: 2, c: 3, z: 1}"

      assert replace("%User{name: n, age: 3}", "%User{..., name: n}", "%Account{..., owner: n}") ==
               "%Account{age: 3, owner: n}"
    end

    test "places a single matched node in a keyword value" do
      assert replace("foo(opt: bar(1))", "foo(opt: bar(...))", "baz(opt: ...)") == "baz(opt: 1)"
    end

    test "raises when several matched nodes would replace a single node" do
      assert_raise ArgumentError, ~r/matched 2 nodes can't replace a single node/, fn ->
        Patcher.replace_all("foo(opt: bar(1, 2))", "foo(opt: bar(...))", "baz(opt: ...)")
      end
    end

    test "keeps escapes in spliced strings" do
      assert replace(
               ~S|Logger.debug(msg, "a\nb\\c")|,
               "Logger.debug(msg, ...)",
               "Logger.warning(msg, ...)"
             ) ==
               ~S|Logger.warning(msg, "a\nb\\c")|
    end

    test "uses the last step of a selector and ignores predicates" do
      import ExAST.Selector

      source = "outer(1, 2, inner(3, 4))"
      chain = pattern("outer(...)") |> descendant("inner(...)")
      filtered = pattern("outer(...)") |> where(has_child("inner(...)"))

      assert replace(source, chain, "replaced(...)") == "outer(1, 2, replaced(3, 4))"
      assert replace(source, filtered, "wrapped(...)") == "wrapped(1, 2, inner(3, 4))"
    end

    test "works for multi-node patterns" do
      assert replace("a = f(1, 2)\nb = g(a)\n", "a = f(...)\nb = g(a)", "b = g(f(...))") ==
               "b = g(f(1, 2))"
    end

    test "returns Sourceror AST for zipper input" do
      result =
        ~S|Logger.debug(msg, label: "a\n")|
        |> Sourceror.parse_string!()
        |> Sourceror.Zipper.zip()
        |> Patcher.replace_all("Logger.debug(msg, ...)", "Logger.warning(msg, ...)")

      assert Sourceror.to_string(result) == ~S|Logger.warning(msg, label: "a\n")|
    end

    test "find_all and find_many captures don't expose what ... matched" do
      source = "Logger.debug(msg, meta)"

      assert [%{captures: %{msg: _} = captures}] =
               Patcher.find_all(source, "Logger.debug(msg, ...)")

      refute Map.has_key?(captures, :...)

      assert [%{captures: captures}] = Patcher.find_many(source, a: "Logger.debug(msg, ...)")
      refute Map.has_key?(captures, :...)
    end
  end

  describe ":limit" do
    test "find_all returns the first matches in source order" do
      source = "a(1)\na(2)\na(3)\n"

      assert source |> Patcher.find_all("a(x)", limit: 2) |> Enum.map(& &1.captures.x) == [1, 2]
      assert Patcher.find_all(source, "a(x)", limit: 0) == []
    end

    test "replace_all with limit: 1 replaces only the first match" do
      assert Patcher.replace_all("a(1)\na(2)\n", "a(x)", "b(x)", limit: 1) == "b(1)\na(2)\n"
      assert Patcher.replace_all("a(a(1))\n", "a(x)", "b(x)", limit: 1) == "b(a(1))\n"
    end

    test "replace_all with limit: 1 on a zipper" do
      result =
        "a(1)\na(2)"
        |> Sourceror.parse_string!()
        |> Sourceror.Zipper.zip()
        |> Patcher.replace_all("a(x)", "b(x)", limit: 1)

      assert Sourceror.to_string(result) == "b(1)\na(2)"
    end
  end
end
