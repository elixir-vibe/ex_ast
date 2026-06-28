defmodule Mix.Tasks.ExAst.ReplaceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("ex_ast.replace")
    :ok
  end

  describe "selector flags" do
    @tag :tmp_dir
    test "replaces only matches accepted by parent flags", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")

      File.write!(file, """
      def run do
        IO.inspect(:direct)

        if true do
          IO.inspect(:nested)
        end
      end
      """)

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.replace", [
            "IO.inspect(value)",
            "dbg(value)",
            file,
            "--parent",
            "def run do ... end"
          ])
        end)

      assert output =~ "1 replacement(s)"
      content = File.read!(file)
      assert content =~ "dbg(:direct)"
      assert content =~ "IO.inspect(:nested)"
    end

    @tag :tmp_dir
    test "prints JSON summaries", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")
      File.write!(file, "IO.inspect(value)\n")

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.replace", [
            "IO.inspect(expr)",
            "dbg(expr)",
            file,
            "--dry-run",
            "--format",
            "json"
          ])
        end)

      assert %{"dry_run" => true, "replacements" => 1} = Jason.decode!(output)
    end

    @tag :tmp_dir
    test "supports dry-run with has and not-has filters", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")

      File.write!(file, """
      def safe do
        Repo.transaction(fn -> :ok end)
      end

      def noisy do
        Repo.transaction(fn -> IO.inspect(:debug) end)
      end
      """)

      original = File.read!(file)

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.replace", [
            "Repo.transaction(expr)",
            "Repo.checkout(expr)",
            file,
            "--has",
            ":ok",
            "--not-has",
            "IO.inspect(_)",
            "--dry-run"
          ])
        end)

      assert output =~ "Would update"
      assert output =~ "1 replacement(s)"
      assert File.read!(file) == original
    end
  end

  @tag :tmp_dir
  test "replaces in explicitly passed .exs files", %{tmp_dir: dir} do
    file = Path.join(dir, "sample_test.exs")
    File.write!(file, "IO.inspect(value)\n")

    output =
      capture_io(fn ->
        Mix.Task.run("ex_ast.replace", ["IO.inspect(expr)", "dbg(expr)", file])
      end)

    assert output =~ "1 replacement(s)"
    assert File.read!(file) == "dbg(value)\n"
  end
end
