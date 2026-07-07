defmodule ExAST.Index.TermsTest do
  use ExUnit.Case, async: true

  import ExAST.Selector, except: [not: 1]

  alias ExAST.Index.Terms

  describe "from_ast/1" do
    test "indexes boolean and nil literals as normal-signal atom terms" do
      terms =
        quote do
          case value do
            nil -> true
            _ -> false
          end
        end
        |> Terms.from_ast()

      assert MapSet.member?(terms, "atom:nil")
      assert MapSet.member?(terms, "atom:true")
      assert MapSet.member?(terms, "atom:false")
      assert Terms.signal("atom:nil") == :normal
      assert Terms.signal("atom:true") == :normal
      assert Terms.signal("atom:false") == :normal
    end

    test "indexes small integer literals" do
      terms =
        quote do
          Enum.at(items, 0) == 1 and Enum.at(items, -1) == 1
        end
        |> Terms.from_ast()

      assert MapSet.member?(terms, "integer:-1")
      assert MapSet.member?(terms, "integer:0")
      assert MapSet.member?(terms, "integer:1")
      assert Terms.signal("integer:0") == :normal
    end

    test "indexes direct keyword argument literal terms" do
      terms =
        quote do
          if valid?, do: false, else: true
        end
        |> Terms.from_ast()

      assert MapSet.member?(terms, "call.kwarg:if/2:do:atom:false")
      assert MapSet.member?(terms, "call.kwarg:if/2:else:atom:true")
      assert Terms.signal("call.kwarg:if/2:do:atom:false") == :high
    end

    test "indexes direct call argument literal terms" do
      terms =
        quote do
          Keyword.get(opts, :name, nil)
          Map.put(map, key, true)
          Kernel.+(value, 0) == 0
        end
        |> Terms.from_ast()

      assert MapSet.member?(terms, "call.arg:Keyword.get/3:3:atom:nil")
      assert MapSet.member?(terms, "call.arg:Map.put/3:3:atom:true")
      assert MapSet.member?(terms, "call.arg:Map.put/3:3:atom:boolean")
      assert MapSet.member?(terms, "call.arg:==/2:2:integer:0")
    end

    test "indexes Sourceror-wrapped literal call arguments from source strings" do
      terms =
        """
        items |> Enum.sort() |> Enum.at(-1)
        items |> Enum.sort() |> Enum.take(-3)
        length(items) == 0
        String.length(value) != 1
        """
        |> Terms.from_source()

      assert MapSet.member?(terms, "integer:-1")
      assert MapSet.member?(terms, "integer:-3")
      assert MapSet.member?(terms, "integer:0")
      assert MapSet.member?(terms, "integer:1")
      assert MapSet.member?(terms, "call.arg:Enum.at/1:1:integer:-1")
      assert MapSet.member?(terms, "call.arg:Enum.take/1:1:integer:-3")
      assert MapSet.member?(terms, "call.arg:==/2:2:integer:0")
      assert MapSet.member?(terms, "call.arg:!=/2:2:integer:1")
      refute Enum.any?(terms, &String.starts_with?(&1, "call.local:__block__/"))
    end

    test "indexes source call arity terms for pipe-equivalent matching" do
      pipe_terms =
        quote do
          items |> Enum.dedup() |> MapSet.new()
        end
        |> Terms.from_ast()

      assert MapSet.member?(pipe_terms, "call.local:|>/2")
      assert MapSet.member?(pipe_terms, "call.remote:Enum.dedup/0")
      assert MapSet.member?(pipe_terms, "call.remote:Enum.dedup/1")
      assert MapSet.member?(pipe_terms, "call.remote:MapSet.new/0")
      assert MapSet.member?(pipe_terms, "call.remote:MapSet.new/1")

      direct_terms =
        quote do
          MapSet.new(Enum.dedup(items))
        end
        |> Terms.from_ast()

      assert MapSet.member?(direct_terms, "call.remote:Enum.dedup/1")
      assert MapSet.member?(direct_terms, "call.remote:Enum.dedup/0")
      assert MapSet.member?(direct_terms, "call.remote:MapSet.new/1")
      assert MapSet.member?(direct_terms, "call.remote:MapSet.new/0")
    end
  end

  describe "from_pattern/1" do
    test "does not index wildcard function names in def patterns as literal names" do
      terms =
        quote do
          @doc false
          defp _(_), do: _
        end
        |> Terms.from_pattern()

      refute MapSet.member?(terms, "def.name:_")
      refute MapSet.member?(terms, "def:_/1")
    end

    test "does not infer same-argument terms for pipe patterns" do
      terms =
        quote do
          Enum.filter(_, _) |> Enum.filter(_, _)
        end
        |> Terms.from_pattern()

      assert MapSet.member?(terms, "call.local:|>/2")
      refute MapSet.member?(terms, "call.local.same_args:|>/2")
    end

    test "indexes boolean, nil, and small integer literals in patterns" do
      terms =
        quote do
          case _ do
            nil -> true
            _ -> false
          end

          Kernel.+(_, 0) == 0
        end
        |> Terms.from_pattern()

      assert MapSet.member?(terms, "atom:nil")
      assert MapSet.member?(terms, "atom:true")
      assert MapSet.member?(terms, "atom:false")
      assert MapSet.member?(terms, "integer:0")
      assert MapSet.member?(terms, "call.arg:==/2:2:integer:0")
    end
  end

  describe "ExAST.Index.plan/1" do
    test "uses keyword argument literal terms as exact candidates" do
      plan =
        quote do
          if _, do: false, else: true
        end
        |> ExAST.Pattern.compile()
        |> ExAST.Index.plan()

      assert MapSet.member?(plan.required_terms, "call.kwarg:if/2:do:atom:false")
      assert MapSet.member?(plan.required_terms, "call.kwarg:if/2:else:atom:true")
    end

    test "uses cached terms from compiled patterns" do
      compiled =
        quote do
          case _ do
            _ -> true
            _ -> false
          end
        end
        |> ExAST.Pattern.compile()

      plan = ExAST.Index.plan(compiled)

      assert MapSet.member?(plan.optional_terms, "atom:true")
      assert MapSet.member?(plan.optional_terms, "atom:false")
    end

    test "uses nil and small integer terms as optional exact candidates" do
      plan =
        quote do
          Keyword.get(_, _, nil) == 0
        end
        |> ExAST.Pattern.compile()
        |> ExAST.Index.plan()

      assert MapSet.member?(plan.required_terms, "call.remote:Keyword.get/3")
      assert MapSet.member?(plan.optional_terms, "atom:nil")
      assert MapSet.member?(plan.optional_terms, "integer:0")
      assert MapSet.member?(plan.optional_terms, "call.arg:Keyword.get/3:3:atom:nil")
      assert MapSet.member?(plan.optional_terms, "call.arg:==/2:2:integer:0")
    end

    test "infers boolean call argument terms from capture predicates" do
      plan =
        pattern("Map.put(_, key, value)")
        |> where(not is_atom(^key) and not is_binary(^key) and ^value in [true, false])
        |> ExAST.Index.plan()

      assert MapSet.member?(plan.required_terms, "call.remote:Map.put/3")
      assert MapSet.member?(plan.optional_terms, "call.arg:Map.put/3:3:atom:boolean")
    end

    test "ignores nil selector predicate payloads" do
      plan =
        pattern("Regex.replace(_, _, _)")
        |> where(piped())
        |> ExAST.Index.plan()

      refute MapSet.member?(plan.required_terms, "atom:nil")
      refute MapSet.member?(plan.optional_terms, "atom:nil")
    end
  end
end
