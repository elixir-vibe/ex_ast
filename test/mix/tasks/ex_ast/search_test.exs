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
    test "a map pattern with ... matches through the mix task", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")

      File.write!(
        file,
        "defmodule M do\n  def perms, do: %{admin: grant(:admin), user: :ok}\nend\n"
      )

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", ["def name do %{...} end", file])
        end)

      assert output =~ "1 match(es)"
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

  @tag :tmp_dir
  test "--print prints only the named capture, one value per match", %{tmp_dir: dir} do
    file = Path.join(dir, "runtime.exs")

    File.write!(file, """
    config :my_app, feature_enabled: true
    config :my_app, feature_enabled: System.get_env("FEATURE") == "1"
    """)

    output =
      capture_io(fn ->
        Mix.Task.run("ex_ast.search", [
          "config :my_app, feature_enabled: x",
          file,
          "--print",
          "x"
        ])
      end)

    assert output == "true\nSystem.get_env(\"FEATURE\") == \"1\"\n"
  end

  @tag :tmp_dir
  test "--print keeps a multi-line value on several lines", %{tmp_dir: dir} do
    file = Path.join(dir, "runtime.exs")

    File.write!(file, """
    config :my_app, handler: fn a ->
      b = a + 1
      b * 2
    end
    """)

    output =
      capture_io(fn ->
        Mix.Task.run("ex_ast.search", ["config :my_app, handler: x", file, "--print", "x"])
      end)

    assert output == "fn a ->\n  b = a + 1\n  b * 2\nend\n"
  end

  @tag :tmp_dir
  test "--print raises when the pattern does not declare the variable", %{tmp_dir: dir} do
    file = Path.join(dir, "sample.ex")
    File.write!(file, "IO.inspect(value)\n")

    assert_raise Mix.Error, ~r/does not declare x/, fn ->
      Mix.Task.run("ex_ast.search", ["IO.inspect(_x)", file, "--print", "x"])
    end
  end

  describe "context lines" do
    @tag :tmp_dir
    test "-C prints the whole match span with context under a file heading", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")

      File.write!(file, """
      defmodule A do
        def f(x) do
          IO.inspect(x,
            label: "a")
        end

        def g(y) do
          y
        end

        def h(z) do
          IO.inspect(z)
        end
      end
      """)

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", ["IO.inspect(...)", file, "-C", "1"])
        end)

      assert output == """
             #{file}
             2-  def f(x) do
             3:    IO.inspect(x,
             4:      label: "a")
             5-  end
             --
             11-  def h(z) do
             12:    IO.inspect(z)
             13-  end

             2 match(es)
             """
    end

    @tag :tmp_dir
    test "-A and -B merge groups that overlap or touch", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")

      File.write!(file, """
      IO.inspect(1)
      IO.inspect(2)
      :ok
      :ok
      IO.inspect(3)
      """)

      after_output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", ["IO.inspect(_)", file, "-A", "1"])
        end)

      assert after_output == """
             #{file}
             1:IO.inspect(1)
             2:IO.inspect(2)
             3-:ok
             --
             5:IO.inspect(3)

             3 match(es)
             """

      Mix.Task.reenable("ex_ast.search")

      before_output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", ["IO.inspect(_)", file, "--before-context", "2"])
        end)

      assert before_output == """
             #{file}
             1:IO.inspect(1)
             2:IO.inspect(2)
             3-:ok
             4-:ok
             5:IO.inspect(3)

             3 match(es)
             """
    end

    @tag :tmp_dir
    test "separates files with a blank line", %{tmp_dir: dir} do
      first = Path.join(dir, "a.ex")
      second = Path.join(dir, "b.ex")
      File.write!(first, ":ok\nIO.inspect(1)\n")
      File.write!(second, "IO.inspect(2)\n:ok")

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", ["IO.inspect(_)", first, second, "--context", "1"])
        end)

      assert output == """
             #{first}
             1-:ok
             2:IO.inspect(1)

             #{second}
             1:IO.inspect(2)
             2-:ok

             2 match(es)
             """
    end

    @tag :tmp_dir
    test "works with several -e patterns", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")
      File.write!(file, "IO.inspect(1)\n:ok\ndbg(2)\n")

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", ["-e", "dbg(_)", "-e", "IO.inspect(_)", file, "-C", "1"])
        end)

      assert output == """
             #{file}
             1:IO.inspect(1)
             2-:ok
             3:dbg(2)

             2 pattern(s), 2 match(es)
             """
    end

    @tag :tmp_dir
    test "--color marks the path, line numbers and the exact match span", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")

      File.write!(file, """
      {IO.inspect(1), IO.inspect(2)}
      IO.inspect(x,
        label: "a")
      :ok
      """)

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", ["IO.inspect(...)", file, "-C", "0", "--color"])
        end)

      path = IO.ANSI.magenta()
      number = IO.ANSI.green()
      match = IO.ANSI.bright()
      reset = IO.ANSI.reset()

      assert output == """
             #{path}#{file}#{reset}
             #{number}1#{reset}:{#{match}IO.inspect(1)#{reset}, #{match}IO.inspect(2)#{reset}}
             #{number}2#{reset}:#{match}IO.inspect(x,#{reset}
             #{number}3#{reset}:#{match}  label: "a")#{reset}

             3 match(es)
             """
    end

    @tag :tmp_dir
    test "--color gives each capture its own color inside the span", %{tmp_dir: dir} do
      file = Path.join(dir, "config.exs")

      File.write!(file, """
      config :ripple, Ripple.Maps,
        disabled: false
      """)

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", ["config app, key, opts", file, "-C", "0", "--color"])
        end)

      path = IO.ANSI.magenta()
      number = IO.ANSI.green()
      span = IO.ANSI.bright()
      app = IO.ANSI.red() <> IO.ANSI.bright()
      key = IO.ANSI.yellow() <> IO.ANSI.bright()
      opts = IO.ANSI.cyan() <> IO.ANSI.bright()
      reset = IO.ANSI.reset()

      assert output == """
             #{path}#{file}#{reset}
             #{number}1#{reset}:#{span}config #{reset}#{app}:ripple#{reset}#{span}, #{reset}#{key}Ripple.Maps#{reset}#{span},#{reset}
             #{number}2#{reset}:#{span}  #{reset}#{opts}disabled: false#{reset}

             1 match(es)
             """
    end

    @tag :tmp_dir
    test "--color ends a boolean capture at the literal", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")
      File.write!(file, "Map.put(m, :on, false)\n")

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", ["Map.put(map, key, value)", file, "-C", "0", "--color"])
        end)

      span = IO.ANSI.bright()
      key = IO.ANSI.red() <> IO.ANSI.bright()
      map = IO.ANSI.yellow() <> IO.ANSI.bright()
      value = IO.ANSI.cyan() <> IO.ANSI.bright()
      reset = IO.ANSI.reset()

      assert output =~
               "#{span}Map.put(#{reset}#{map}m#{reset}#{span}, #{reset}#{key}:on#{reset}#{span}, #{reset}#{value}false#{reset}#{span})#{reset}\n"
    end

    @tag :tmp_dir
    test "--color colors a capture written through an alias", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")

      File.write!(file, """
      alias Foo.Bar
      IO.inspect(Bar)
      """)

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", ["IO.inspect(x)", file, "-C", "0", "--color"])
        end)

      span = IO.ANSI.bright()
      x = IO.ANSI.red() <> IO.ANSI.bright()
      reset = IO.ANSI.reset()

      assert output =~ "#{span}IO.inspect(#{reset}#{x}Bar#{reset}#{span})#{reset}\n"
    end

    @tag :tmp_dir
    test "raises when combined with a non-line output mode", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")
      File.write!(file, "IO.inspect(1)\n")

      for flag <- [["--count"], ["--count-by-file"], ["--json"], ["--print", "x"]] do
        Mix.Task.reenable("ex_ast.search")

        assert_raise Mix.Error, ~r/-A, -B and -C/, fn ->
          Mix.Task.run("ex_ast.search", ["IO.inspect(x)", file, "-C", "1" | flag])
        end
      end
    end
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
    test "--print prints only the named capture across all patterns", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")
      File.write!(file, "IO.inspect(a)\ndbg(b)\n")

      output =
        capture_io(fn ->
          Mix.Task.run("ex_ast.search", [
            "-e",
            "IO.inspect(x)",
            "-e",
            "dbg(x)",
            file,
            "--print",
            "x"
          ])
        end)

      assert output == "a\nb\n"
    end

    @tag :tmp_dir
    test "--print raises when any pattern does not declare the variable", %{tmp_dir: dir} do
      file = Path.join(dir, "sample.ex")
      File.write!(file, "IO.inspect(a)\ndbg(b)\n")

      assert_raise Mix.Error, ~r/"dbg\(y\)" does not declare x/, fn ->
        Mix.Task.run("ex_ast.search", [
          "-e",
          "IO.inspect(x)",
          "-e",
          "dbg(y)",
          file,
          "--print",
          "x"
        ])
      end
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
