defmodule Mix.Tasks.ExAst.SearchTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    Mix.Task.reenable("ex_ast.search")
    :ok
  end

  describe "selector flags" do
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

      assert output =~ "2 match(es)"
    end

    @tag :tmp_dir
    test "expands bare imports with --expand-imports", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")
      File.write!(file, "import Enum\n\nmap(list, &(&1 + 1))\n")

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", ["Enum.map(_, _)", file])
        end)

      assert output =~ "0 match(es)"

      Mix.Task.reenable("ex_ast.search")

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", ["Enum.map(_, _)", file, "--expand-imports"])
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

    @tag :tmp_dir
    test "--count-by-file reports per-file counts", %{tmp_dir: dir} do
      a = Path.join(dir, "a.ex")
      b = Path.join(dir, "b.ex")
      File.write!(a, "IO.inspect(1)\nIO.inspect(2)\n")
      File.write!(b, "IO.inspect(3)\n")

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", ["IO.inspect(_)", a, b, "--count-by-file"])
        end)

      assert output =~ "2\t#{a}"
      assert output =~ "1\t#{b}"
      assert output =~ "3 match(es) in 2 file(s)"

      lines = String.split(output, "\n", trim: true)

      assert Enum.find_index(lines, &(&1 == "2\t#{a}")) <
               Enum.find_index(lines, &(&1 == "1\t#{b}"))
    end
  end

  @tag :tmp_dir
  test "searches explicitly passed .exs files", %{tmp_dir: dir} do
    file = Path.join(dir, "sample_test.exs")
    File.write!(file, "IO.inspect(value)\n")

    output =
      capture_io(fn ->
        Mix.Task.run("ex_ast.search", ["IO.inspect(expr)", file])
      end)

    assert output =~ "1 match(es)"
    assert output =~ "expr: value"
  end

  describe "multiple -e patterns" do
    @tag :tmp_dir
    test "runs several patterns in one invocation, tagged", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")
      File.write!(file, "IO.inspect(value)\ndbg(other)\n")

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", ["-e", "IO.inspect(_)", "-e", "dbg(_)", file])
        end)

      assert output =~ "[IO.inspect(_)] #{file}:1"
      assert output =~ "[dbg(_)] #{file}:2"
      assert output =~ "2 pattern(s), 2 match(es)"
    end

    @tag :tmp_dir
    test "per-pattern filters do not cross-contaminate", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")

      File.write!(file, """
      def handle_call(_, _, _) do
        Repo.get!(User, id)
        IO.inspect(:in_call)
      end

      def other do
        Repo.get!(Post, pid)
        IO.inspect(:in_other)
      end
      """)

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", [
            "-e",
            "Repo.get!(_, _)",
            "--inside",
            "def handle_call(_, _, _) do _ end",
            "-e",
            "IO.inspect(_)",
            "--not-inside",
            "def handle_call(_, _, _) do _ end",
            file
          ])
        end)

      assert output =~ "[Repo.get!(_, _)] #{file}:2"
      refute output =~ "[Repo.get!(_, _)] #{file}:7"
      assert output =~ "[IO.inspect(_)] #{file}:8"
      refute output =~ "[IO.inspect(_)] #{file}:3"
    end

    @tag :tmp_dir
    test "--count reports a per-pattern tally plus total", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")
      File.write!(file, "IO.inspect(a)\ndbg(b)\n")

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", [
            "-e",
            "IO.inspect(_)",
            "-e",
            "dbg(_)",
            "-e",
            "Enum.member?(_, _)",
            file,
            "--count"
          ])
        end)

      assert output =~ "1\tIO.inspect(_)"
      assert output =~ "1\tdbg(_)"
      assert output =~ "0\tEnum.member?(_, _)"
      assert output =~ "2 match(es) across 3 pattern(s)"
    end

    @tag :tmp_dir
    test "--json includes the :pattern field", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")
      File.write!(file, "IO.inspect(value)\n")

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", ["-e", "IO.inspect(expr)", file, "--json"])
        end)

      assert %{"count" => 1, "matches" => [%{"pattern" => "IO.inspect(expr)"}]} =
               Jason.decode!(output)
    end

    @tag :tmp_dir
    test "global flags after -e apply to the batch", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")
      File.write!(file, "import Enum\n\nmap(list, &(&1 + 1))\n")

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", ["-e", "Enum.map(_, _)", file, "--expand-imports"])
        end)

      assert output =~ "1 pattern(s), 1 match(es)"
    end

    @tag :tmp_dir
    test "raises when positional pattern is mixed with -e", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")
      File.write!(file, "IO.inspect(value)\n")

      assert_raise Mix.Error, ~r/positional pattern with -e/, fn ->
        Mix.Task.run("ex_ast.search", ["IO.inspect(_)", "-e", "dbg(_)", file])
      end
    end

    @tag :tmp_dir
    test "raises on duplicate pattern strings", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")
      File.write!(file, "IO.inspect(value)\n")

      assert_raise Mix.Error, ~r/Duplicate pattern/, fn ->
        Mix.Task.run("ex_ast.search", ["-e", "IO.inspect(_)", "-e", "IO.inspect(_)", file])
      end
    end

    @tag :tmp_dir
    test "raises when --count-by-file is combined with -e", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")
      File.write!(file, "IO.inspect(value)\n")

      assert_raise Mix.Error, ~r/not supported with -e/, fn ->
        Mix.Task.run("ex_ast.search", ["-e", "IO.inspect(_)", file, "--count-by-file"])
      end
    end

    @tag :tmp_dir
    test "raises when a selector filter precedes the first -e", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")
      File.write!(file, "IO.inspect(value)\n")

      assert_raise Mix.Error, ~r/before the first -e/, fn ->
        Mix.Task.run("ex_ast.search", [
          "--inside",
          "def _ do ... end",
          "-e",
          "IO.inspect(_)",
          file
        ])
      end
    end

    @tag :tmp_dir
    test "preserves path argument order within a segment", %{tmp_dir: dir} do
      a = Path.join(dir, "a.ex")
      b = Path.join(dir, "b.ex")
      File.write!(a, "IO.inspect(1)\n")
      File.write!(b, "IO.inspect(2)\n")

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", ["-e", "IO.inspect(_)", a, b, "--limit", "1"])
        end)

      assert output =~ "#{a}:1"
      refute output =~ "#{b}:1"
    end

    @tag :tmp_dir
    test "handles long patterns", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")
      File.write!(file, "IO.inspect(value)\n")

      pattern = "[" <> Enum.map_join(1..100, ", ", fn _ -> "_" end) <> "]"
      assert byte_size(pattern) > 255

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", ["-e", pattern, file, "--count"])
        end)

      assert output =~ "0\t#{pattern}"
      assert output =~ "across 1 pattern(s)"
    end
  end
end
