defmodule ExAST.TaggedIdentTest do
  use ExUnit.Case, async: true

  alias ExAST.Ident
  alias ExAST.Index.Terms
  alias ExAST.Pattern

  defp ident(name), do: Ident.tag(name)

  test "patterns match tagged remote calls without interning source identifiers" do
    node =
      {{:., [], [{:__aliases__, [], [ident("Repo")]}, ident("get!")]}, [],
       [ident("User"), {:id, [], nil}]}

    assert {:ok, %{}} = Pattern.match(node, "Repo.get!(_, _)")
    assert :error = Pattern.match(node, "Other.get!(_, _)")
  end

  test "patterns match tagged definitions" do
    node =
      {:def, [],
       [{ident("handle_call"), [], [ident("msg"), ident("from"), ident("state")]}, [do: :ok]]}

    assert {:ok, %{}} = Pattern.match(node, "def handle_call(_, _, _) do ... end")
    assert :error = Pattern.match(node, "def handle_event(_, _, _) do ... end")
  end

  test "index terms are emitted from tagged identifiers" do
    ast =
      {:defmodule, [],
       [
         {:__aliases__, [], [ident("MyApp"), ident("Accounts")]},
         [
           do:
             {:def, [],
              [
                {ident("handle_call"), [], [ident("msg"), ident("from"), ident("state")]},
                [
                  do:
                    {:%, [],
                     [
                       {:__aliases__, [], [ident("User")]},
                       {:%{}, [], [{ident("name"), ident("msg")}]}
                     ]}
                ]
              ]}
         ]
       ]}

    terms = Terms.from_ast(ast)

    assert "module:MyApp.Accounts" in terms
    assert "alias:MyApp.Accounts" in terms
    assert "def:handle_call/3" in terms
    assert "def.name:handle_call" in terms
    assert "struct:User" in terms
    assert "struct.field:name" in terms
  end

  test "index terms ignore tagged map and struct update tails" do
    ast =
      {:__block__, [],
       [
         {:%{}, [], [{:|, [], [ident("base"), [{ident("name"), ident("value")}]]}]},
         {:%, [],
          [
            {:__aliases__, [], [ident("User")]},
            {:%{}, [], [{:|, [], [ident("user"), [{ident("name"), ident("value")}]]}]}
          ]}
       ]}

    terms = Terms.from_ast(ast)

    assert "node:map" in terms
    assert "node:struct" in terms
    assert "struct:User" in terms
  end

  test "remote call terms include tagged module and function names" do
    ast =
      {{:., [], [{:__aliases__, [], [ident("Repo")]}, ident("get!")]}, [],
       [ident("User"), ident("id")]}

    terms = Terms.from_ast(ast)

    assert "call.remote:Repo.get!/2" in terms
    assert "call.module:Repo" in terms
    assert "call.function:get!" in terms
  end
end
