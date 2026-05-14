defmodule Mix.Tasks.ExAstCliTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("ex_ast.search")
    Mix.Task.reenable("ex_ast.replace")
    Mix.Task.reenable("ex_ast.diff")
    :ok
  end

  describe "mix ex_ast.search selector flags" do
    @tag :tmp_dir
    test "filters matches with parent and ancestor flags", %{tmp_dir: dir} do
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
          Mix.Task.run("ex_ast.search", [
            "IO.inspect(value)",
            file,
            "--parent",
            "def run do ... end"
          ])
        end)

      assert output =~ "value: :direct"
      refute output =~ "value: :nested"

      Mix.Task.reenable("ex_ast.search")

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", [
            "IO.inspect(value)",
            file,
            "--ancestor",
            "def run do ... end"
          ])
        end)

      assert output =~ "value: :direct"
      assert output =~ "value: :nested"
    end

    @tag :tmp_dir
    test "preserves multi-node pattern matching without selector flags", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")

      File.write!(file, """
      def run do
        record = Repo.get!(User, id)
        Repo.delete(record)
      end
      """)

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", [
            "record = Repo.get!(_, _); Repo.delete(record)",
            file
          ])
        end)

      assert output =~ "1 match(es)"
    end

    @tag :tmp_dir
    test "filters selected nodes with has and not-has flags", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")

      File.write!(file, """
      def safe do
        Repo.transaction(fn -> :ok end)
      end

      def noisy do
        Repo.transaction(fn -> IO.inspect(:debug) end)
      end

      def plain do
        :ok
      end
      """)

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", [
            "def name do ... end",
            file,
            "--has",
            "Repo.transaction(_)",
            "--not-has",
            "IO.inspect(_)"
          ])
        end)

      assert output =~ "name: safe"
      refute output =~ "name: noisy"
      refute output =~ "name: plain"
    end

    @tag :tmp_dir
    test "supports query-style flags and limits", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")

      File.write!(file, """
      def run do
        record = Repo.get!(User, id)
        Logger.debug(record)
        Repo.delete(record)
      end
      """)

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", [
            "Repo.delete(record)",
            file,
            "--follows",
            "record = Repo.get!(_, _)",
            "--limit",
            "1"
          ])
        end)

      assert output =~ "Repo.delete(record)"
      assert output =~ "1 match(es)"
    end

    @tag :tmp_dir
    test "filters with comment flags", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")

      File.write!(file, """
      def keep do
        # TODO: migrate
        :ok
      end

      def skip do
        :ok
      end
      """)

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", [
            "def name do ... end",
            file,
            "--comment-inside",
            "TODO"
          ])
        end)

      assert output =~ "name: keep"
      refute output =~ "name: skip"
    end

    @tag :tmp_dir
    test "detects regex syntax in comment flags", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")

      File.write!(file, """
      def keep do
        # FIXME: migrate
        :ok
      end

      def also_keep do
        value = 1 # debug temporary
      end

      def skip do
        # note
        :ok
      end
      """)

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", [
            "def name do ... end",
            file,
            "--comment-inside",
            "/todo|fixme/i"
          ])
        end)

      assert output =~ "name: keep"
      refute output =~ "name: skip"

      output =
        capture_io(fn ->
          Mix.Task.rerun("ex_ast.search", [
            "value = 1",
            file,
            "--comment-inline",
            "~r/temporary|debug/"
          ])
        end)

      assert output =~ "value = 1"
    end

    @tag :tmp_dir
    test "allows broad search with limit", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")
      File.write!(file, "defmodule A do\n  def run, do: :ok\nend\n")

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", ["_", file, "--limit", "2"])
        end)

      assert output =~ "1 match(es)"
    end

    @tag :tmp_dir
    test "prints JSON with Jason", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")
      File.write!(file, "IO.inspect(value)\n")

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", ["IO.inspect(expr)", file, "--format", "json"])
        end)

      assert %{"count" => 1, "matches" => [%{"captures" => %{"expr" => "value"}}]} =
               Jason.decode!(output)
    end
  end

  describe "mix ex_ast.replace selector flags" do
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
end
