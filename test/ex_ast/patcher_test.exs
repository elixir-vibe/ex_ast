defmodule ExAst.PatcherTest do
  use ExUnit.Case, async: true

  alias ExAst.Patcher

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
end
