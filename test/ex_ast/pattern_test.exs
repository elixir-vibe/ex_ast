defmodule ExAST.PatternTest do
  use ExUnit.Case, async: true

  alias ExAST.Pattern

  defp match!(source, pattern) do
    ast = Sourceror.parse_string!(source)
    Pattern.match(ast, pattern, Pattern.collect_aliases(ast))
  end

  describe "literals" do
    test "exact match" do
      assert {:ok, %{}} = match!("IO.inspect(data)", "IO.inspect(data)")
    end

    test "atom" do
      assert {:ok, %{}} = match!(":ok", ":ok")
      assert :error = match!(":ok", ":error")
    end

    test "string" do
      assert {:ok, %{}} = match!(~s("hello"), ~s("hello"))
      assert :error = match!(~s("hello"), ~s("world"))
    end

    test "integer" do
      assert {:ok, %{}} = match!("42", "42")
      assert :error = match!("42", "43")
    end

    test "no match on different function" do
      assert :error = match!("IO.inspect(data)", "IO.puts(data)")
    end

    test "no match on different arity" do
      assert :error = match!("Enum.map(a, b)", "Enum.map(a)")
    end
  end

  describe "wildcards" do
    test "underscore matches anything" do
      assert {:ok, %{}} = match!("IO.inspect(data)", "IO.inspect(_)")
    end

    test "underscore-prefixed matches anything" do
      assert {:ok, %{}} = match!("IO.inspect(data)", "IO.inspect(_expr)")
    end

    test "wildcards don't appear in captures" do
      assert {:ok, caps} = match!("Enum.map(list, fun)", "Enum.map(_, _)")
      assert caps == %{}
    end
  end

  describe "captures" do
    test "single capture" do
      assert {:ok, caps} = match!("IO.inspect(data)", "IO.inspect(expr)")
      assert Map.has_key?(caps, :expr)
    end

    test "multiple captures" do
      assert {:ok, caps} = match!("Enum.map(list, fun)", "Enum.map(input, mapper)")
      assert Map.has_key?(caps, :input)
      assert Map.has_key?(caps, :mapper)
    end

    test "repeated variable requires same value" do
      assert {:ok, _} = match!("Enum.map(x, x)", "Enum.map(a, a)")
      assert :error = match!("Enum.map(x, y)", "Enum.map(a, a)")
    end

    test "capture string value" do
      assert {:ok, %{name: "subject"}} =
               match!(~s(%Step{id: "subject"}), ~s(%Step{id: name}))
    end
  end

  describe "structs (partial match)" do
    test "matches with subset of keys" do
      assert {:ok, %{}} =
               match!(
                 ~s(%Step{id: "subject", title: "Hello", fields: []}),
                 ~s(%Step{id: "subject"})
               )
    end

    test "captures struct field values" do
      assert {:ok, %{name: "subject"}} =
               match!(
                 ~s(%Step{id: "subject", title: "Hello"}),
                 ~s(%Step{id: name})
               )
    end

    test "rejects missing key" do
      assert :error =
               match!(
                 ~s(%Step{id: "subject"}),
                 ~s(%Step{id: "subject", nonexistent: _})
               )
    end

    test "rejects wrong struct name" do
      assert :error = match!(~s(%Step{id: "x"}), ~s(%Field{id: "x"}))
    end

    test "matches with multiple pattern keys" do
      assert {:ok, %{}} =
               match!(
                 ~s(%Step{id: "subject", title: "Hello", fields: []}),
                 ~s(%Step{id: "subject", title: "Hello"})
               )
    end
  end

  describe "maps (partial match)" do
    test "matches with subset of keys" do
      assert {:ok, %{}} =
               match!(
                 ~s(%{name: "John", age: 30}),
                 ~s(%{name: "John"})
               )
    end

    test "captures map values" do
      assert {:ok, %{n: "John"}} =
               match!(
                 ~s(%{name: "John", age: 30}),
                 ~s(%{name: n})
               )
    end
  end

  describe "tuples" do
    test "{:ok, _}" do
      assert {:ok, %{}} = match!("{:ok, 42}", "{:ok, _}")
    end

    test "{:error, reason}" do
      assert {:ok, %{reason: "boom"}} =
               match!(~s({:error, "boom"}), "{:error, reason}")
    end

    test "{:noreply, state}" do
      assert {:ok, caps} = match!("{:noreply, []}", "{:noreply, state}")
      assert Map.has_key?(caps, :state)
    end
  end

  describe "function definitions" do
    test "def with wildcards" do
      assert {:ok, %{}} =
               match!(
                 "def handle_call(:ping, _from, state)",
                 "def handle_call(_, _, _)"
               )
    end

    test "def with specific first arg" do
      assert {:ok, %{}} =
               match!(
                 "def handle_call(:ping, _from, state)",
                 "def handle_call(:ping, _, _)"
               )
    end
  end

  describe "pipes" do
    test "pipe into function" do
      assert {:ok, %{}} = match!("data |> Enum.map(fun)", "_ |> Enum.map(_)")
    end

    test "pipe matches unpipelined call" do
      assert {:ok, %{}} = match!("data |> Enum.map(fun)", "Enum.map(_, _)")
    end

    test "unpipelined call matches pipe pattern" do
      assert {:ok, %{}} = match!("Enum.map(data, fun)", "data |> Enum.map(fun)")
    end

    test "pipe captures" do
      assert {:ok, %{input: _, mapper: _}} =
               match!("data |> Enum.map(fun)", "Enum.map(input, mapper)")
    end

    test "multi-step pipe normalizes" do
      assert {:ok, %{}} =
               match!(
                 "data |> Enum.map(f) |> Enum.filter(g)",
                 "Enum.filter(Enum.map(data, f), g)"
               )
    end

    test "pipe into zero-arity" do
      assert {:ok, %{}} = match!("data |> Enum.to_list()", "Enum.to_list(_)")
    end

    test "pipe into bare function" do
      assert {:ok, %{}} = match!("data |> to_string", "to_string(_)")
    end
  end

  describe "directives" do
    test "use" do
      assert {:ok, %{mod: {:__aliases__, nil, [:GenServer]}}} =
               match!("use GenServer", "use mod")
    end

    test "expands aliases for nested remote calls" do
      assert {:ok, %{}} =
               match!(
                 """
                 defmodule Example do
                   alias AshPhoenix.Form

                   def run(form) do
                     Form.for_update(form, :update)
                   end
                 end
                 """,
                 """
                 defmodule Example do
                   alias AshPhoenix.Form

                   def run(form) do
                     AshPhoenix.Form.for_update(form, :update)
                   end
                 end
                 """
               )
    end

    test "expands aliases for selector and inside-style matching" do
      source = """
      defmodule Example do
        alias AshPhoenix.Form

        def run(form) do
          value =
            if ready?() do
              Form.for_update(form, :update)
            end

          value
        end
      end
      """

      assert [_] = ExAST.Patcher.find_all(source, "AshPhoenix.Form.for_update(_, _)")

      assert [_] =
               ExAST.Patcher.find_all(source, "AshPhoenix.Form.for_update(_, _)",
                 inside: "def _ do ... end"
               )

      assert [] = ExAST.Patcher.find_all(source, "Form.for_update(_, _)")
    end

    test "import" do
      assert {:ok, caps} = match!("import Ecto.Query", "import mod")
      assert Map.has_key?(caps, :mod)
    end

    test "alias" do
      assert {:ok, caps} = match!("alias MyApp.Accounts.User", "alias mod")
      assert Map.has_key?(caps, :mod)
    end

    test "collects grouped aliases" do
      ast =
        Sourceror.parse_string!("""
        defmodule Example do
          alias Phoenix.Socket.{Broadcast, Message, Reply}
        end
        """)

      assert ExAST.Pattern.collect_aliases(ast) == %{
               Broadcast: [:Phoenix, :Socket, :Broadcast],
               Message: [:Phoenix, :Socket, :Message],
               Reply: [:Phoenix, :Socket, :Reply]
             }
    end
  end

  describe "module attributes" do
    test "@behaviour" do
      assert {:ok, caps} = match!("@behaviour GenServer", "@behaviour mod")
      assert Map.has_key?(caps, :mod)
    end

    test "@impl true" do
      assert {:ok, %{}} = match!("@impl true", "@impl true")
    end

    test "captures attribute name" do
      assert {:ok, caps} =
               match!("@env Application.get_env(:app, :key)", "@name Application.get_env(_, _)")

      assert caps[:name] == :env
    end

    test "wildcards in attribute name" do
      assert {:ok, %{}} =
               match!("@env Application.get_env(:app, :key)", "@_ Application.get_env(_, _)")
    end

    test "wildcard-prefixed attribute name" do
      assert {:ok, %{}} =
               match!("@env Application.get_env(:app, :key)", "@_name Application.get_env(_, _)")
    end

    test "literal attribute name match" do
      assert {:ok, caps} =
               match!("@env Application.get_env(:app, :key)", "@env Application.get_env(_, _)")

      assert caps[:env] == :env
    end

    test "captures attribute name with Patcher.find_all" do
      source = """
      @env Application.get_env(:my_app, :key)
      @timeout 5000
      @db_url Application.get_env(:my_app, :db_url)
      """

      alias ExAST.Patcher
      matches = Patcher.find_all(source, "@name Application.get_env(_, _)")
      assert length(matches) == 2
      assert Enum.map(matches, & &1.captures[:name]) == [:env, :db_url]
    end
  end

  describe "control flow" do
    test "case" do
      assert {:ok, %{}} =
               match!(
                 "case x do :ok -> 1 end",
                 "case _ do _ -> _ end"
               )
    end

    test "anonymous function" do
      assert {:ok, %{}} = match!("fn x -> x + 1 end", "fn _ -> _ end")
    end

    test "capture operator" do
      assert {:ok, %{}} = match!("&String.upcase/1", "&_/1")
    end
  end

  describe "substitute/2" do
    test "replaces capture variables in template" do
      captures = %{expr: {:data, nil, nil}}
      template = Code.string_to_quoted!("Logger.debug(inspect(expr))")
      result = Pattern.substitute(template, captures)
      assert Macro.to_string(result) == "Logger.debug(inspect(data))"
    end

    test "leaves non-capture variables unchanged" do
      captures = %{expr: {:data, nil, nil}}
      template = Code.string_to_quoted!("IO.puts(other)")
      result = Pattern.substitute(template, captures)
      assert Macro.to_string(result) == "IO.puts(other)"
    end

    test "leaves wildcards unchanged" do
      captures = %{expr: {:data, nil, nil}}
      template = Code.string_to_quoted!("fn _ -> expr end")
      result = Pattern.substitute(template, captures)
      assert Macro.to_string(result) =~ "data"
    end
  end

  describe "multi_node?/1" do
    test "single expression" do
      refute Pattern.multi_node?("IO.inspect(x)")
    end

    test "semicolon-separated" do
      assert Pattern.multi_node?("a = 1; b = 2")
    end

    test "newline-separated" do
      assert Pattern.multi_node?("a = 1\nb = 2")
    end
  end

  describe "match_sequences/2" do
    test "finds contiguous match" do
      nodes = Enum.map(["x = 1", "y = 2", "z = 3"], &Code.string_to_quoted!/1)
      patterns = Enum.map(["_ = 1", "_ = 2"], &Code.string_to_quoted!/1)

      assert [{caps, 0..1}] = Pattern.match_sequences(nodes, patterns)
      assert map_size(caps) == 0
    end

    test "consistent captures across nodes" do
      nodes =
        Enum.map(
          ["a = Repo.get!(User, 1)", "Repo.delete(a)"],
          &Code.string_to_quoted!/1
        )

      patterns =
        Enum.map(
          ["x = Repo.get!(_, _)", "Repo.delete(x)"],
          &Code.string_to_quoted!/1
        )

      assert [{caps, 0..1}] = Pattern.match_sequences(nodes, patterns)
      assert Map.has_key?(caps, :x)
    end

    test "rejects inconsistent captures" do
      nodes =
        Enum.map(
          ["a = Repo.get!(User, 1)", "Repo.delete(b)"],
          &Code.string_to_quoted!/1
        )

      patterns =
        Enum.map(
          ["x = Repo.get!(_, _)", "Repo.delete(x)"],
          &Code.string_to_quoted!/1
        )

      assert [] = Pattern.match_sequences(nodes, patterns)
    end

    test "no match returns empty list" do
      nodes = Enum.map(["x = 1"], &Code.string_to_quoted!/1)
      patterns = Enum.map(["_ = 1", "_ = 2"], &Code.string_to_quoted!/1)

      assert [] = Pattern.match_sequences(nodes, patterns)
    end
  end

  describe "ellipsis (...)" do
    test "matches zero args" do
      assert {:ok, %{}} = match!("foo()", "foo(...)")
    end

    test "matches one arg" do
      assert {:ok, %{}} = match!("foo(1)", "foo(...)")
    end

    test "matches multiple args" do
      assert {:ok, %{}} = match!("foo(1, 2, 3)", "foo(...)")
    end

    test "captures before ellipsis" do
      assert {:ok, %{first: _}} = match!("foo(1, 2, 3)", "foo(first, ...)")
    end

    test "captures after ellipsis" do
      assert {:ok, %{last: _}} = match!("foo(1, 2, 3)", "foo(..., last)")
    end

    test "captures both sides of ellipsis" do
      assert {:ok, caps} = match!("foo(1, 2, 3, 4)", "foo(first, ..., last)")
      assert Map.has_key?(caps, :first)
      assert Map.has_key?(caps, :last)
    end

    test "rejects too few args for surrounding captures" do
      assert :error = match!("foo(1)", "foo(first, ..., last)")
    end

    test "ellipsis in list" do
      assert {:ok, %{}} = match!("[1, 2, 3]", "[...]")
    end

    test "ellipsis with head in list" do
      assert {:ok, %{head: _}} = match!("[1, 2, 3]", "[head, ...]")
    end

    test "ellipsis with tail in list" do
      assert {:ok, %{last: _}} = match!("[1, 2, 3]", "[..., last]")
    end

    test "matches remote call any arity" do
      assert {:ok, %{}} = match!("Enum.map(list, fun)", "Enum.map(...)")
    end

    test "matches remote call with capture + ellipsis" do
      assert {:ok, %{list: _}} = match!("Enum.reduce(list, acc, fun)", "Enum.reduce(list, ...)")
    end

    test "ellipsis in do block" do
      assert {:ok, %{}} = match!("def foo do\n  1\n  2\n  3\nend", "def foo do ... end")
    end

    test "ellipsis in case clause" do
      assert {:ok, %{}} = match!("case x do\n  :ok -> 1\nend", "case _ do ... end")
    end

    test "no match when ellipsis pattern head mismatches" do
      assert :error = match!("bar(1, 2)", "foo(...)")
    end

    test "quoted ellipsis" do
      ast = Sourceror.parse_string!("foo(1, 2, 3)")
      assert {:ok, %{}} = Pattern.match(ast, quote(do: foo(...)))
    end

    test "quoted ellipsis with capture" do
      ast = Sourceror.parse_string!("foo(1, 2, 3)")
      assert {:ok, %{first: _}} = Pattern.match(ast, quote(do: foo(first, ...)))
    end
  end

  describe "~p sigil" do
    import ExAST.Sigil

    test "parses pattern at compile time" do
      pattern = ~p"IO.inspect(_)"
      ast = Sourceror.parse_string!("IO.inspect(data)")
      assert {:ok, %{}} = Pattern.match(ast, pattern)
    end

    test "captures work" do
      pattern = ~p"Enum.map(list, fun)"
      ast = Sourceror.parse_string!("Enum.map(data, &to_string/1)")
      assert {:ok, caps} = Pattern.match(ast, pattern)
      assert Map.has_key?(caps, :list)
      assert Map.has_key?(caps, :fun)
    end

    test "ellipsis in sigil" do
      pattern = ~p"foo(first, ...)"
      ast = Sourceror.parse_string!("foo(1, 2, 3)")
      assert {:ok, %{first: _}} = Pattern.match(ast, pattern)
    end

    test "works with find_all" do
      source = """
      IO.inspect(a)
      IO.puts("hello")
      IO.inspect(b, label: "x")
      """

      matches = ExAST.Patcher.find_all(source, ~p"IO.inspect(...)")
      assert length(matches) == 2
    end

    test "works with replace_all" do
      source = "dbg(data)\n"
      result = ExAST.Patcher.replace_all(source, ~p"dbg(expr)", ~p"expr")
      assert result =~ "data"
      refute result =~ "dbg"
    end
  end
end
