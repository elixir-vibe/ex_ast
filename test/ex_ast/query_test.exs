defmodule ExAST.QueryTest do
  use ExUnit.Case, async: true

  import ExAST.Query

  alias ExAST.Patcher

  test "queries read from selected node through where predicates" do
    source = """
    def save do
      Repo.transaction(fn -> :ok end)
    end

    def debug do
      Repo.transaction(fn -> IO.inspect(:debug) end)
    end
    """

    query =
      from("def name do ... end")
      |> where(contains("Repo.transaction(_)"))
      |> where(not contains("IO.inspect(...)"))

    [match] = Patcher.find_all(source, query)
    assert match.captures[:name] == {:save, nil, nil}
  end

  test "find and find_child select descendant and direct child nodes" do
    source = """
    defmodule Example do
      def run do
        IO.inspect(:nested)
      end
    end
    """

    assert [_] = Patcher.find_all(source, from("defmodule _ do ... end") |> find("IO.inspect(_)"))

    assert [] =
             Patcher.find_all(
               source,
               from("defmodule _ do ... end") |> find_child("IO.inspect(_)")
             )

    assert [_] =
             Patcher.find_all(
               source,
               from("defmodule _ do ... end") |> find_child("def run do ... end")
             )
  end

  test "from accepts alternative patterns" do
    source = """
    def public do
      :ok
    end

    defp private do
      :ok
    end
    """

    matches = Patcher.find_all(source, from(["def _ do ... end", "defp _ do ... end"]))
    assert length(matches) == 2
  end

  test "public search refuses unbounded broad queries" do
    tmp_dir =
      System.tmp_dir!()
      |> Path.join("ex_ast_broad_query_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.write!(Path.join(tmp_dir, "a.ex"), "defmodule A do\n  def run, do: :ok\nend\n")

    assert_raise ArgumentError, ~r/refusing broad query/, fn ->
      ExAST.search(tmp_dir, from("_"))
    end
  end

  test "public search allows broad queries with a limit and stops across files" do
    tmp_dir =
      System.tmp_dir!()
      |> Path.join("ex_ast_broad_query_limit_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.write!(Path.join(tmp_dir, "a.ex"), "defmodule A do\n  def one, do: :ok\nend\n")
    File.write!(Path.join(tmp_dir, "b.ex"), "defmodule B do\n  def two, do: :ok\nend\n")

    matches = ExAST.search(tmp_dir, from("_"), limit: 3)
    assert length(matches) == 3
  end

  test "public search allows explicitly broad queries" do
    tmp_dir =
      System.tmp_dir!()
      |> Path.join("ex_ast_broad_query_allowed_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.write!(Path.join(tmp_dir, "a.ex"), "defmodule A do\n  def run, do: :ok\nend\n")

    assert [_ | _] = ExAST.search(tmp_dir, from("_"), allow_broad: true)
  end

  test "inside and parent filter containing contexts" do
    source = """
    def run do
      IO.inspect(:direct)

      if enabled? do
        IO.inspect(:nested)
      end
    end
    """

    query =
      from("IO.inspect(value)")
      |> where(inside("def run do ... end"))
      |> where(not parent("def run do ... end"))

    [match] = Patcher.find_all(source, query)
    assert match.captures[:value] == :nested
  end

  test "sibling predicates filter by relative statement order" do
    source = """
    def run do
      record = Repo.get!(User, id)
      Logger.debug(record)
      Repo.delete(record)
    end
    """

    assert [_] =
             Patcher.find_all(
               source,
               from("Repo.delete(record)") |> where(follows("record = Repo.get!(_, _)"))
             )

    assert [_] =
             Patcher.find_all(
               source,
               from("record = Repo.get!(_, _)") |> where(precedes("Repo.delete(record)"))
             )

    assert [_] =
             Patcher.find_all(
               source,
               from("Repo.delete(record)") |> where(immediately_follows("Logger.debug(record)"))
             )

    assert [_] =
             Patcher.find_all(
               source,
               from("Logger.debug(record)") |> where(immediately_precedes("Repo.delete(record)"))
             )
  end

  test "position predicates filter first last and nth siblings" do
    source = """
    def run do
      first_call()
      second_call()
      last_call()
    end
    """

    assert [_] = Patcher.find_all(source, from("first_call()") |> where(first()))
    assert [_] = Patcher.find_all(source, from("second_call()") |> where(nth(2)))
    assert [_] = Patcher.find_all(source, from("last_call()") |> where(last()))
  end

  test "any all and boolean operators compose predicates" do
    source = """
    def transaction do
      Repo.transaction(fn -> :ok end)
    end

    def multi do
      Ecto.Multi.new()
    end

    def debug do
      IO.inspect(:debug)
    end
    """

    query =
      from("def name do ... end")
      |> where(contains("Repo.transaction(_)") or contains("Ecto.Multi.new()"))
      |> where(not contains("IO.inspect(...)"))

    matches = Patcher.find_all(source, query)

    assert Enum.map(matches, & &1.captures[:name]) == [
             {:transaction, nil, nil},
             {:multi, nil, nil}
           ]

    query =
      from("def name do ... end")
      |> where(all([contains("Repo.transaction(_)"), not contains("IO.inspect(...)")]))

    [match] = Patcher.find_all(source, query)
    assert match.captures[:name] == {:transaction, nil, nil}
  end

  test "capture guards with ^pin filter on captured values" do
    source = """
    Enum.take(users, -5)
    Enum.take(users, 10)
    Enum.take(users, -1)
    """

    query =
      from("Enum.take(_, count)")
      |> where(match?({:-, _, [_]}, ^count))

    matches = Patcher.find_all(source, query)
    assert length(matches) == 2
    assert Enum.all?(matches, fn m -> match?({:-, _, [_]}, m.captures[:count]) end)
  end

  test "capture guards with ^pin multi-capture expression" do
    source = """
    x == x
    x == y
    a + a
    """

    query =
      from("left == right")
      |> where(^left == ^right)

    [match] = Patcher.find_all(source, query)
    assert match.captures[:left] == {:x, nil, nil}
  end

  test "capture guards with ^pin and match? for structural type check" do
    source = """
    Enum.map(users, fn u -> u.name end) |> Enum.filter(fn u -> u.active? end)
    Enum.filter(users, fn u -> u.active? end)
    """

    query =
      from("Enum.filter(expr, _)")
      |> where(match?({{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, _}, ^expr))

    [match] = Patcher.find_all(source, query)
    assert match.captures[:expr] != {:users, nil, nil}
  end

  test "capture guards with ^pin specific atom value" do
    source = """
    def handle_event(:click, _, socket) do
      {:noreply, socket}
    end
    def handle_event(:keydown, _, socket) do
      {:noreply, socket}
    end
    def handle_event(:submit, _, socket) do
      {:noreply, socket}
    end
    """

    query =
      from("def handle_event(event, _, _) do ... end")
      |> where(^event == :click or ^event == :keydown)

    matches = Patcher.find_all(source, query)
    assert length(matches) == 2
  end

  test "capture guards compose with structural predicates" do
    source = """
    Enum.take(users, -5)
    Enum.take(users, 10)
    Enum.take(users, 3)
    """

    query =
      from("Enum.take(_, count)")
      |> where(match?({:-, _, [_]}, ^count))

    [match] = Patcher.find_all(source, query)
    assert match.captures[:count] == {:-, nil, [5]}
  end
end
