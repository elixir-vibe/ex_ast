defmodule ExAst.PatternTest do
  use ExUnit.Case, async: true

  alias ExAst.Pattern

  defp match!(source, pattern) do
    ast = Sourceror.parse_string!(source)
    Pattern.match(ast, pattern)
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
  end

  describe "directives" do
    test "use" do
      assert {:ok, %{mod: {:__aliases__, nil, [:GenServer]}}} =
               match!("use GenServer", "use mod")
    end

    test "import" do
      assert {:ok, caps} = match!("import Ecto.Query", "import mod")
      assert Map.has_key?(caps, :mod)
    end

    test "alias" do
      assert {:ok, caps} = match!("alias MyApp.Accounts.User", "alias mod")
      assert Map.has_key?(caps, :mod)
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
end
