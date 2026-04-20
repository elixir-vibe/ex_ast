defmodule ExAST.DiffTest do
  use ExUnit.Case, async: true

  alias ExAST.Diff

  describe "identical sources" do
    test "produces no edits" do
      source = """
      defmodule Sample do
        def run(x), do: x + 1
      end
      """

      result = Diff.diff(source, source)
      assert result.edits == []
    end
  end

  describe "function body updates" do
    test "detects update when body changes" do
      left = """
      defmodule Sample do
        def run(x) do
          x + 1
        end
      end
      """

      right = """
      defmodule Sample do
        def run(x) do
          x + 2
        end
      end
      """

      result = Diff.diff(left, right)

      assert Enum.any?(result.edits, fn e ->
               e.op == :update and e.kind == :function
             end)
    end

    test "update meta contains old and new source" do
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

      result = Diff.diff(left, right)
      [edit] = Enum.filter(result.edits, &(&1.op == :update and &1.kind == :function))
      assert edit.meta.old =~ ":ok"
      assert edit.meta.new =~ ":error"
    end
  end

  describe "function insertions and deletions" do
    test "detects inserted function" do
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

      result = Diff.diff(left, right)

      assert Enum.any?(result.edits, fn e ->
               e.op == :insert and e.kind == :function and e.summary =~ "second"
             end)
    end

    test "detects deleted function" do
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

      result = Diff.diff(left, right)

      assert Enum.any?(result.edits, fn e ->
               e.op == :delete and e.kind == :function and e.summary =~ "second"
             end)
    end
  end

  describe "function moves" do
    test "detects reordered functions" do
      left = """
      defmodule Sample do
        def first, do: 1
        def second, do: 2
      end
      """

      right = """
      defmodule Sample do
        def second, do: 2
        def first, do: 1
      end
      """

      result = Diff.diff(left, right)

      assert Enum.any?(result.edits, fn e ->
               e.op == :move and e.kind == :function and e.summary =~ "first"
             end)
    end

    test "no moves when include_moves: false" do
      left = """
      defmodule Sample do
        def first, do: 1
        def second, do: 2
      end
      """

      right = """
      defmodule Sample do
        def second, do: 2
        def first, do: 1
      end
      """

      result = Diff.diff(left, right, include_moves: false)
      refute Enum.any?(result.edits, &(&1.op == :move))
    end
  end

  describe "pipeline changes" do
    test "detects inserted pipeline stage" do
      left = """
      defmodule Sample do
        def run(x) do
          x
          |> foo()
          |> bar()
        end
      end
      """

      right = """
      defmodule Sample do
        def run(x) do
          x
          |> foo()
          |> baz()
          |> bar()
        end
      end
      """

      result = Diff.diff(left, right)

      assert Enum.any?(result.edits, fn e ->
               e.op == :update and e.kind == :function and e.meta.new =~ "baz"
             end)
    end
  end

  describe "call updates" do
    test "detects updated call arguments" do
      left = """
      defmodule A do
        def run do
          foo(a: 1, b: 2)
        end
      end
      """

      right = """
      defmodule A do
        def run do
          foo(a: 2, b: 2, c: 3)
        end
      end
      """

      result = Diff.diff(left, right)

      assert Enum.any?(result.edits, fn e ->
               e.op == :update and e.kind in [:keyword, :call, :function]
             end)
    end
  end

  describe "map and struct changes" do
    test "detects updated map" do
      left = """
      defmodule A do
        def run do
          %{name: "old", age: 30}
        end
      end
      """

      right = """
      defmodule A do
        def run do
          %{name: "new", age: 30}
        end
      end
      """

      result = Diff.diff(left, right)

      has_map_or_fn_update =
        Enum.any?(result.edits, fn e ->
          e.op == :update and e.kind in [:map, :function]
        end)

      assert has_map_or_fn_update
    end
  end

  describe "summary" do
    test "returns human-readable summary lines" do
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

      result = Diff.diff(left, right)
      assert is_list(result.summary)
      assert result.summary != []
      assert Enum.all?(result.summary, &is_binary/1)
    end
  end

  describe "diff_files/2" do
    @tag :tmp_dir
    test "diffs files from disk", %{tmp_dir: dir} do
      left_path = Path.join(dir, "left.ex")
      right_path = Path.join(dir, "right.ex")

      File.write!(left_path, "defmodule A do\n  def run, do: :ok\nend\n")
      File.write!(right_path, "defmodule A do\n  def run, do: :error\nend\n")

      result = Diff.diff_files(left_path, right_path)
      assert Enum.any?(result.edits, &(&1.op == :update))
    end
  end

  describe "ExAST.diff/2 public API" do
    test "delegates to ExAST.Diff" do
      left = "defmodule A do\n  def run, do: :ok\nend\n"
      right = "defmodule A do\n  def run, do: :error\nend\n"

      result = ExAST.diff(left, right)
      assert %ExAST.Diff.Result{} = result
      assert Enum.any?(result.edits, &(&1.op == :update))
    end
  end

  describe "edge cases" do
    test "completely different modules" do
      left = """
      defmodule A do
        def foo, do: 1
      end
      """

      right = """
      defmodule B do
        def bar, do: 2
      end
      """

      result = Diff.diff(left, right)
      assert result.edits != []
    end

    test "empty module bodies" do
      left = """
      defmodule A do
      end
      """

      right = """
      defmodule A do
      end
      """

      result = Diff.diff(left, right)
      assert result.edits == []
    end

    test "multiple functions changed" do
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

      result = Diff.diff(left, right)
      updated = Enum.filter(result.edits, &(&1.op == :update and &1.kind == :function))
      assert [_, _] = updated
    end
  end
end
