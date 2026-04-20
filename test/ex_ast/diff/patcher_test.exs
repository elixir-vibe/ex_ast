defmodule ExAST.Diff.PatcherTest do
  use ExUnit.Case, async: true

  alias ExAST.Diff

  defp patch(left, right) do
    result = Diff.diff(left, right)
    Diff.apply(result)
  end

  describe "updates" do
    test "applies function body update" do
      left = """
      defmodule A do
        def run, do: :ok
      end
      """

      right = """
      defmodule A do
        def run, do: :error
      end
      """

      patched = patch(left, right)
      assert patched =~ ":error"
      refute patched =~ ":ok"
    end

    test "applies multiple function updates" do
      left = """
      defmodule A do
        def foo, do: 1
        def bar, do: 2
        def baz, do: 3
      end
      """

      right = """
      defmodule A do
        def foo, do: 10
        def bar, do: 2
        def baz, do: 30
      end
      """

      patched = patch(left, right)
      assert patched =~ "10"
      assert patched =~ "30"
      assert patched =~ "def bar, do: 2"
    end

    test "applies guard change" do
      left = """
      defmodule A do
        def run(x) when is_integer(x), do: x
      end
      """

      right = """
      defmodule A do
        def run(x) when is_number(x), do: x
      end
      """

      patched = patch(left, right)
      assert patched =~ "is_number"
      refute patched =~ "is_integer"
    end
  end

  describe "deletions" do
    test "applies function deletion" do
      left = """
      defmodule A do
        def first, do: 1
        def second, do: 2
      end
      """

      right = """
      defmodule A do
        def first, do: 1
      end
      """

      patched = patch(left, right)
      assert patched =~ "def first"
      refute patched =~ "def second"
    end

    test "applies multi-line function deletion" do
      left = """
      defmodule A do
        def keep, do: :ok

        def remove(x) do
          x
          |> foo()
          |> bar()
        end
      end
      """

      right = """
      defmodule A do
        def keep, do: :ok
      end
      """

      patched = patch(left, right)
      assert patched =~ "def keep"
      refute patched =~ "def remove"
      refute patched =~ "foo"
    end
  end

  describe "insertions" do
    test "applies function insertion" do
      left = """
      defmodule A do
        def first, do: 1
      end
      """

      right = """
      defmodule A do
        def first, do: 1
        def second, do: 2
      end
      """

      patched = patch(left, right)
      assert patched =~ "def first"
      assert patched =~ "def second"
    end

    test "applies insertion at beginning of module" do
      left = """
      defmodule A do
        def existing, do: :ok
      end
      """

      right = """
      defmodule A do
        use GenServer
        def existing, do: :ok
      end
      """

      patched = patch(left, right)
      assert patched =~ "use GenServer"
      assert patched =~ "def existing"
    end
  end

  describe "combined edits" do
    test "applies update + insert together" do
      left = """
      defmodule A do
        def run, do: :old
      end
      """

      right = """
      defmodule A do
        def run, do: :new
        def helper, do: :ok
      end
      """

      patched = patch(left, right)
      assert patched =~ ":new"
      assert patched =~ "def helper"
      refute patched =~ ":old"
    end

    test "applies update + delete together" do
      left = """
      defmodule A do
        def keep, do: 1
        def remove, do: 2
        def update, do: 3
      end
      """

      right = """
      defmodule A do
        def keep, do: 1
        def update, do: 30
      end
      """

      patched = patch(left, right)
      assert patched =~ "def keep, do: 1"
      assert patched =~ "30"
      refute patched =~ "def remove"
    end
  end

  describe "identity" do
    test "no edits returns source unchanged" do
      source = """
      defmodule A do
        def run(x), do: x + 1
      end
      """

      patched = patch(source, source)
      assert patched == source
    end
  end

  describe "round-trip" do
    test "patching produces parseable Elixir" do
      left = """
      defmodule Counter do
        def init, do: 0
        def inc(n), do: n + 1
        def dec(n), do: n - 1
      end
      """

      right = """
      defmodule Counter do
        def init, do: 0
        def inc(n), do: n + 1
        def double(n), do: n * 2
        def dec(n), do: n - 1
        def reset, do: 0
      end
      """

      patched = patch(left, right)
      assert {:ok, _} = Code.string_to_quoted(patched)
      assert patched =~ "def double"
      assert patched =~ "def reset"
    end

    test "patching empty module to full module" do
      left = """
      defmodule A do
      end
      """

      right = """
      defmodule A do
        use GenServer
        def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
        def init(state), do: {:ok, state}
      end
      """

      patched = patch(left, right)
      assert patched =~ "use GenServer"
      assert patched =~ "def start_link"
      assert patched =~ "def init"
    end

    test "patching full module to empty" do
      left = """
      defmodule A do
        def foo, do: 1
        def bar, do: 2
      end
      """

      right = """
      defmodule A do
      end
      """

      patched = patch(left, right)
      refute patched =~ "def foo"
      refute patched =~ "def bar"
    end
  end

  describe "public API" do
    test "ExAST.apply_diff/1" do
      left = """
      defmodule A do
        def run, do: :ok
      end
      """

      right = """
      defmodule A do
        def run, do: :error
      end
      """

      result = ExAST.diff(left, right)
      patched = ExAST.apply_diff(result)
      assert patched =~ ":error"
      refute patched =~ ":ok"
    end
  end
end
