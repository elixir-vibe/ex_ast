defmodule ExAST.Selector.Predicate do
  @moduledoc """
  Predicate used by `ExAST.Selector.where/2`.

  Build predicates with `ExAST.Selector.parent/1`, `ancestor/1`,
  `has_child/1`, `has_descendant/1`, or `has/1`. Negate them with
  `ExAST.Selector.not/1`.
  """

  defstruct [:relation, :pattern, negated?: false]

  @type relation :: :parent | :ancestor | :has_child | :has_descendant
  @type t :: %__MODULE__{
          relation: relation(),
          pattern: ExAST.Pattern.pattern(),
          negated?: boolean()
        }
end

defmodule ExAST.Selector do
  import Kernel, except: [not: 1]

  @moduledoc """
  CSS-like AST selector builder.

  Selectors are built from a starting pattern and relationship steps:

      import ExAST.Selector

      pattern("defmodule _ do ... end")
      |> descendant("def _ do ... end")
      |> child("IO.inspect(_)")

  The final step is the selected node. Use `where/2` with predicates such as
  `has_child/1`, `has_descendant/1`, `parent/1`, and `ancestor/1` to filter the
  selected node without changing it.

      pattern("def _ do ... end")
      |> where(has_descendant("Repo.transaction(_)"))
      |> where(not(has_descendant("IO.inspect(_)")))

  `where/2` also accepts quoted boolean predicate expressions, so you can use
  `Kernel.not/1` without excluding it from imports:

      pattern("def _ do ... end")
      |> where(not has_descendant("IO.inspect(_)"))
  """

  alias ExAST.Selector.Predicate

  defstruct steps: [], filters: []

  @type relation :: :self | :child | :descendant
  @type step :: {relation(), ExAST.Pattern.pattern()}
  @type t :: %__MODULE__{steps: [step()], filters: [Predicate.t()]}

  @doc "Starts a selector at `pattern`."
  @spec pattern(ExAST.Pattern.pattern()) :: t()
  def pattern(pattern), do: %__MODULE__{steps: [{:self, pattern}]}

  @doc "Alias for `pattern/1`."
  @spec selector(ExAST.Pattern.pattern()) :: t()
  def selector(pattern), do: pattern(pattern)

  @doc "Selects direct semantic children matching `pattern`."
  @spec child(t(), ExAST.Pattern.pattern()) :: t()
  def child(%__MODULE__{} = selector, pattern), do: add_step(selector, :child, pattern)

  @doc "Selects semantic descendants matching `pattern`."
  @spec descendant(t(), ExAST.Pattern.pattern()) :: t()
  def descendant(%__MODULE__{} = selector, pattern), do: add_step(selector, :descendant, pattern)

  @doc "Adds a predicate filter without changing the selected node."
  defmacro where(selector, expr) do
    predicate = build_predicate_from_ast(expr)

    quote do
      ExAST.Selector.where_predicate(unquote(selector), unquote(Macro.escape(predicate)))
    end
  end

  @doc false
  @spec where_predicate(t(), Predicate.t()) :: t()
  def where_predicate(%__MODULE__{} = selector, %Predicate{} = predicate),
    do: add_filter(selector, predicate)

  @doc "Builds or applies a direct semantic parent predicate."
  @spec parent(ExAST.Pattern.pattern()) :: Predicate.t()
  @spec parent(t(), ExAST.Pattern.pattern()) :: t()
  def parent(pattern), do: predicate(:parent, pattern)
  def parent(%__MODULE__{} = selector, pattern), do: where_predicate(selector, parent(pattern))

  @doc "Builds or applies a semantic ancestor predicate."
  @spec ancestor(ExAST.Pattern.pattern()) :: Predicate.t()
  @spec ancestor(t(), ExAST.Pattern.pattern()) :: t()
  def ancestor(pattern), do: predicate(:ancestor, pattern)

  def ancestor(%__MODULE__{} = selector, pattern),
    do: where_predicate(selector, ancestor(pattern))

  @doc "Builds or applies a direct semantic child predicate."
  @spec has_child(ExAST.Pattern.pattern()) :: Predicate.t()
  @spec has_child(t(), ExAST.Pattern.pattern()) :: t()
  def has_child(pattern), do: predicate(:has_child, pattern)

  def has_child(%__MODULE__{} = selector, pattern),
    do: where_predicate(selector, has_child(pattern))

  @doc "Builds or applies a semantic descendant predicate."
  @spec has_descendant(ExAST.Pattern.pattern()) :: Predicate.t()
  @spec has_descendant(t(), ExAST.Pattern.pattern()) :: t()
  def has_descendant(pattern), do: predicate(:has_descendant, pattern)

  def has_descendant(%__MODULE__{} = selector, pattern),
    do: where_predicate(selector, has_descendant(pattern))

  @doc "Alias for `has_descendant/1` and `has_descendant/2`."
  @spec has(ExAST.Pattern.pattern()) :: Predicate.t()
  @spec has(t(), ExAST.Pattern.pattern()) :: t()
  def has(pattern), do: has_descendant(pattern)
  def has(%__MODULE__{} = selector, pattern), do: has_descendant(selector, pattern)

  @doc "Negates a predicate for use with `where/2`."
  @spec not Predicate.t() :: Predicate.t()
  def not (%Predicate{} = predicate), do: %{predicate | negated?: Kernel.not(predicate.negated?)}

  defp add_step(%__MODULE__{steps: steps} = selector, relation, pattern) do
    %{selector | steps: steps ++ [{relation, pattern}]}
  end

  defp build_predicate_from_ast({:not, _, [expr]}),
    do: not build_predicate_from_ast(unwrap_block(expr))

  defp build_predicate_from_ast({name, _, [pattern]})
       when name in [:parent, :ancestor, :has_child] do
    apply(__MODULE__, name, [pattern])
  end

  defp build_predicate_from_ast({name, _, [pattern]}) when name in [:has_descendant, :has] do
    apply(__MODULE__, :has_descendant, [pattern])
  end

  defp build_predicate_from_ast(%Predicate{} = predicate), do: predicate

  defp build_predicate_from_ast(ast) do
    raise ArgumentError,
          "unsupported selector predicate expression: #{Macro.to_string(ast)}"
  end

  defp unwrap_block({:__block__, _, [expr]}), do: expr
  defp unwrap_block(expr), do: expr

  defp add_filter(%__MODULE__{filters: filters} = selector, %Predicate{} = predicate) do
    %{selector | filters: filters ++ [predicate]}
  end

  defp predicate(relation, pattern) do
    %Predicate{relation: relation, pattern: pattern}
  end
end
