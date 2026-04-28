defmodule ExAST.SelectorTest do
  use ExUnit.Case, async: true

  import ExAST.Selector

  alias ExAST.Patcher

  describe "pipeline relationships" do
    test "child selects direct semantic children" do
      source = """
      defmodule Example do
        def run do
          IO.inspect(:run)
        end
      end
      """

      selector =
        pattern("defmodule Example do ... end")
        |> child("def run do ... end")

      [match] = Patcher.find_all(source, selector)
      assert Sourceror.to_string(match.node) =~ "def run"
    end

    test "child does not select nested descendants" do
      source = """
      defmodule Example do
        def run do
          IO.inspect(:run)
        end
      end
      """

      selector =
        pattern("defmodule Example do ... end")
        |> child("IO.inspect(_)")

      assert Patcher.find_all(source, selector) == []
    end

    test "descendant selects nested semantic descendants" do
      source = """
      defmodule Example do
        def run do
          IO.inspect(:run)
        end
      end
      """

      selector =
        pattern("defmodule Example do ... end")
        |> descendant("IO.inspect(value)")

      [match] = Patcher.find_all(source, selector)
      assert match.captures[:value] == :run
    end

    test "chains child and descendant relationships" do
      source = """
      defmodule Example do
        def run do
          if enabled? do
            IO.inspect(:run)
          end
        end
      end
      """

      selector =
        pattern("defmodule Example do ... end")
        |> child("def run do ... end")
        |> descendant("IO.inspect(value)")

      [match] = Patcher.find_all(source, selector)
      assert match.captures[:value] == :run
    end

    test "captures are accumulated across selector steps" do
      source = """
      defmodule Example do
        def run do
          IO.inspect(:run)
        end
      end
      """

      selector =
        pattern("defmodule module_name do ... end")
        |> descendant("IO.inspect(value)")

      [match] = Patcher.find_all(source, selector)
      assert match.captures[:module_name] == {:__aliases__, nil, [:Example]}
      assert match.captures[:value] == :run
    end

    test "repeated captures must stay consistent across selector steps" do
      source = """
      defmodule Example do
        def run do
          IO.inspect(:other)
        end
      end
      """

      selector =
        pattern("defmodule name do ... end")
        |> descendant("IO.inspect(name)")

      assert Patcher.find_all(source, selector) == []
    end
  end

  describe "selector filters" do
    test "has_child keeps the selected node" do
      source = """
      defmodule Example do
        def with_debug do
          IO.inspect(:debug)
        end

        def without_debug do
          :ok
        end
      end
      """

      selector =
        pattern("def name do ... end")
        |> where(has_child("IO.inspect(_)"))

      [match] = Patcher.find_all(source, selector)
      assert match.captures[:name] == {:with_debug, nil, nil}
      assert Sourceror.to_string(match.node) =~ "def with_debug"
    end

    test "has_descendant finds nested descendants" do
      source = """
      defmodule Example do
        def with_nested_debug do
          if true do
            IO.inspect(:debug)
          end
        end

        def without_debug do
          :ok
        end
      end
      """

      selector =
        pattern("def name do ... end")
        |> where(has_descendant("IO.inspect(_)"))

      [match] = Patcher.find_all(source, selector)
      assert match.captures[:name] == {:with_nested_debug, nil, nil}
    end

    test "has_descendant finds nested remote calls inside assigned control flow" do
      source = """
      defmodule Form do
        defp assign_form(%{assigns: %{form: form, tenant: tenant}} = socket) do
          form =
            if form do
              AshPhoenix.Form.for_update(form, :update,
                as: "form",
                actor: socket.assigns.current_user,
                tenant: tenant
              )
            else
              AshPhoenix.Form.for_create(MyApp.Form, :create,
                as: "form",
                actor: socket.assigns.current_user,
                tenant: tenant
              )
            end

          assign(socket, form: to_form(form))
        end
      end
      """

      selector =
        pattern("defp assign_form(%{assigns: %{form: form, tenant: tenant}} = socket) do ... end")
        |> where(has_descendant("AshPhoenix.Form.for_update(_, _, _)"))

      assert [_match] = Patcher.find_all(source, selector)
    end

    test "has is an alias for has_descendant" do
      source = """
      def run do
        if true do
          IO.inspect(:debug)
        end
      end
      """

      selector =
        pattern("def run do ... end")
        |> where(has("IO.inspect(_)"))

      assert [_] = Patcher.find_all(source, selector)
    end

    test "parent filters by direct semantic parent" do
      source = """
      def run do
        IO.inspect(:run)
      end

      if true do
        IO.inspect(:if)
      end
      """

      selector =
        pattern("IO.inspect(value)")
        |> where(parent("def run do ... end"))

      [match] = Patcher.find_all(source, selector)
      assert match.captures[:value] == :run
    end

    test "ancestor filters by any semantic ancestor" do
      source = """
      def run do
        if true do
          IO.inspect(:inside_def)
        end
      end

      if true do
        IO.inspect(:outside_def)
      end
      """

      selector =
        pattern("IO.inspect(value)")
        |> where(ancestor("def run do ... end"))

      [match] = Patcher.find_all(source, selector)
      assert match.captures[:value] == :inside_def
    end

    test "negative filters reject matches" do
      source = """
      def with_debug do
        IO.inspect(:debug)
      end

      def without_debug do
        :ok
      end
      """

      selector =
        pattern("def name do ... end")
        |> where(not has_descendant("IO.inspect(_)"))

      [match] = Patcher.find_all(source, selector)
      assert match.captures[:name] == {:without_debug, nil, nil}
    end
  end

  describe "complex selector scenarios" do
    test "combines descendant chain with positive and negative predicates" do
      source = """
      defmodule Admin.UserLive do
        def handle_event("save", params, socket) do
          Repo.transaction(fn ->
            Accounts.save_user(params)
          end)
        end

        def handle_event("debug", params, socket) do
          Repo.transaction(fn ->
            IO.inspect(params)
            Accounts.save_user(params)
          end)
        end

        def handle_event("noop", _params, socket) do
          {:noreply, socket}
        end
      end

      defmodule Public.UserLive do
        def handle_event("save", params, socket) do
          Repo.transaction(fn ->
            Accounts.save_user(params)
          end)
        end
      end
      """

      selector =
        pattern("defmodule Admin.UserLive do ... end")
        |> descendant("def handle_event(event, params, socket) do ... end")
        |> where(has_descendant("Repo.transaction(_)"))
        |> where(not has_descendant("IO.inspect(_)"))

      [match] = Patcher.find_all(source, selector)
      assert match.captures[:event] == "save"
      assert match.captures[:params] == {:params, nil, nil}
      assert match.captures[:socket] == {:socket, nil, nil}
    end

    test "descendant traverses nested remote calls inside assigned control flow" do
      source = """
      defmodule Form do
        defp assign_form(%{assigns: %{form: form, tenant: tenant}} = socket) do
          form =
            if form do
              AshPhoenix.Form.for_update(form, :update,
                as: "form",
                actor: socket.assigns.current_user,
                tenant: tenant
              )
            else
              AshPhoenix.Form.for_create(MyApp.Form, :create,
                as: "form",
                actor: socket.assigns.current_user,
                tenant: tenant
              )
            end

          assign(socket, form: to_form(form))
        end
      end
      """

      selector =
        pattern("defmodule Form do ... end")
        |> descendant("AshPhoenix.Form.for_update(_, _, _)")

      assert [_match] = Patcher.find_all(source, selector)
    end

    test "descendant matches alias-expanded remote calls" do
      source = """
      defmodule Form do
        alias AshPhoenix.Form

        defp assign_form(form) do
          value =
            if form do
              Form.for_update(form, :update)
            end

          value
        end
      end
      """

      selector =
        pattern("defmodule _ do ... end")
        |> descendant("AshPhoenix.Form.for_update(_, _)")

      assert [_match] = Patcher.find_all(source, selector)
    end

    test "child relationships can traverse nested modules without matching deeper descendants" do
      source = """
      defmodule Outer do
        def top_level do
          :skip
        end

        defmodule Inner do
          def run do
            call()
          end
        end
      end
      """

      selector =
        pattern("defmodule Outer do ... end")
        |> child("defmodule Inner do ... end")
        |> descendant("call()")

      [match] = Patcher.find_all(source, selector)
      assert Sourceror.to_string(match.node) == "call()"

      too_shallow =
        pattern("defmodule Outer do ... end")
        |> child("call()")

      assert Patcher.find_all(source, too_shallow) == []
    end

    test "has_child only considers direct body statements" do
      source = """
      def direct do
        IO.inspect(:direct)
      end

      def nested do
        if true do
          IO.inspect(:nested)
        end
      end
      """

      selector =
        pattern("def name do ... end")
        |> where(has_child("IO.inspect(_)"))

      [match] = Patcher.find_all(source, selector)
      assert match.captures[:name] == {:direct, nil, nil}
    end

    test "parent and ancestor predicates distinguish immediate and containing contexts" do
      source = """
      def run do
        if enabled? do
          IO.inspect(:nested)
        end
      end
      """

      nested_inspect = pattern("IO.inspect(value)")

      assert [] =
               nested_inspect
               |> where(parent("def run do ... end"))
               |> then(&Patcher.find_all(source, &1))

      selector =
        nested_inspect
        |> where(parent("if _ do _ end"))
        |> where(ancestor("def run do ... end"))

      [match] = Patcher.find_all(source, selector)

      assert match.captures[:value] == :nested
    end

    test "predicate convenience arities can be mixed with where predicates" do
      source = """
      defmodule Example do
        def safe do
          Repo.transaction(fn -> :ok end)
        end

        def noisy do
          Repo.transaction(fn -> IO.inspect(:debug) end)
        end
      end
      """

      selector =
        pattern("def name do ... end")
        |> ancestor("defmodule Example do ... end")
        |> has("Repo.transaction(_)")
        |> where(not has("IO.inspect(_)"))

      [match] = Patcher.find_all(source, selector)
      assert match.captures[:name] == {:safe, nil, nil}
    end

    test "double negation keeps the original predicate meaning" do
      source = """
      def with_transaction do
        Repo.transaction(fn -> :ok end)
      end

      def without_transaction do
        :ok
      end
      """

      selector =
        pattern("def name do ... end")
        |> where(not (not has_descendant("Repo.transaction(_)")))

      [match] = Patcher.find_all(source, selector)
      assert match.captures[:name] == {:with_transaction, nil, nil}
    end

    test "nested not parent predicate excludes direct parent matches" do
      source = """
      def run do
        IO.inspect(:direct)

        if enabled? do
          IO.inspect(:nested)
        end
      end
      """

      selector =
        pattern("IO.inspect(value)")
        |> where(not parent("def run do ... end"))
        |> where(ancestor("def run do ... end"))

      [match] = Patcher.find_all(source, selector)
      assert match.captures[:value] == :nested
    end

    test "nested not ancestor predicate keeps only top-level matches" do
      source = """
      def run do
        IO.inspect(:direct)

        if enabled? do
          IO.inspect(:nested)
        end
      end
      """

      selector =
        pattern("IO.inspect(value)")
        |> where(ancestor("def run do ... end"))
        |> where(not ancestor("if _ do _ end"))

      [match] = Patcher.find_all(source, selector)
      assert match.captures[:value] == :direct
    end

    test "nested not has_child predicate keeps only functions without direct debug" do
      source = """
      def with_direct_debug do
        IO.inspect(:direct)
      end

      def with_nested_debug do
        if enabled? do
          IO.inspect(:nested)
        end
      end

      def without_debug do
        :ok
      end
      """

      selector =
        pattern("def name do ... end")
        |> where(not has_child("IO.inspect(_)"))
        |> where(has_descendant("IO.inspect(_)"))

      [match] = Patcher.find_all(source, selector)
      assert match.captures[:name] == {:with_nested_debug, nil, nil}
    end
  end

  describe "integration" do
    test "replace_all accepts selectors" do
      source = """
      defmodule Example do
        def run do
          IO.inspect(:debug)
        end
      end
      """

      selector =
        pattern("defmodule Example do ... end")
        |> descendant("IO.inspect(value)")

      assert Patcher.replace_all(source, selector, "dbg(value)") =~ "dbg(:debug)"
    end

    test "AST replace_all accepts selectors" do
      ast =
        Sourceror.parse_string!("""
        defmodule Example do
          def run do
            IO.inspect(:debug)
          end
        end
        """)

      selector =
        pattern("defmodule Example do ... end")
        |> descendant("IO.inspect(value)")

      result = Patcher.replace_all(ast, selector, "dbg(value)")
      assert Macro.to_string(result) =~ "dbg(:debug)"
    end

    test "ExAST.search accepts selectors" do
      tmp_dir =
        System.tmp_dir!() |> Path.join("ex_ast_selector_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)
      file = Path.join(tmp_dir, "sample.ex")

      File.write!(file, """
      defmodule Example do
        def run do
          IO.inspect(:ok)
        end
      end
      """)

      selector =
        pattern("defmodule Example do ... end")
        |> descendant("IO.inspect(value)")

      [match] = ExAST.search(file, selector)
      assert match.file == file
      assert match.line == 3
      assert match.source == "IO.inspect(:ok)"
      assert match.captures[:value] == :ok
    end

    test "ExAST.search falls back when formatter config cannot be loaded" do
      tmp_dir =
        System.tmp_dir!()
        |> Path.join("ex_ast_selector_fallback_#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      File.write!(Path.join(tmp_dir, ".formatter.exs"), "[import_deps: [:missing_dep]]")

      file = Path.join(tmp_dir, "sample.ex")

      File.write!(file, """
      defmodule Example do
        def run do
          IO.inspect(:ok)
        end
      end
      """)

      selector =
        pattern("defmodule Example do ... end")
        |> descendant("IO.inspect(value)")

      [match] = ExAST.search(file, selector)
      assert match.file == file
      assert match.line == 3
      assert match.source == "IO.inspect(:ok)"
      assert match.captures[:value] == :ok
    end
  end
end
