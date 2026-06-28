defmodule ExAST.Index.TermsTest do
  use ExUnit.Case, async: true

  alias ExAST.Index.Terms

  describe "from_ast/1" do
    test "indexes boolean literals as low-signal atom terms" do
      terms =
        quote do
          case value do
            :ok -> true
            _ -> false
          end
        end
        |> Terms.from_ast()

      assert MapSet.member?(terms, "atom:true")
      assert MapSet.member?(terms, "atom:false")
      assert Terms.signal("atom:true") == :normal
      assert Terms.signal("atom:false") == :normal
    end
  end

  describe "from_pattern/1" do
    test "indexes boolean literals in patterns" do
      terms =
        quote do
          case _ do
            _ -> true
            _ -> false
          end
        end
        |> Terms.from_pattern()

      assert MapSet.member?(terms, "atom:true")
      assert MapSet.member?(terms, "atom:false")
    end
  end

  describe "ExAST.Index.plan/1" do
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
  end
end
