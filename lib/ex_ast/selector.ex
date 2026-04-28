defmodule ExAST.Selector.Predicate do
  @moduledoc """
  Predicate used by `ExAST.Selector.where/2`.

  Build predicates with `ExAST.Selector.parent/1`, `ancestor/1`,
  `has_child/1`, `has_descendant/1`, or `has/1`. Negate them with
  `ExAST.Selector.not/1`.
  """

  defstruct [:relation, :pattern, negated?: false]

  @type relation ::
          :parent
          | :ancestor
          | :has_child
          | :has_descendant
          | :any
          | :all
          | :follows
          | :precedes
          | :immediately_follows
          | :immediately_precedes
          | :first
          | :last
          | :nth
  @type t :: %__MODULE__{
          relation: relation(),
          pattern: ExAST.Pattern.pattern() | [t()] | pos_integer() | nil,
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
  @type step :: {relation(), ExAST.Pattern.pattern() | [ExAST.Pattern.pattern()]}
  @type t :: %__MODULE__{steps: [step()], filters: [Predicate.t()]}

  @doc "Starts a selector at `pattern`."
  @spec pattern(ExAST.Pattern.pattern() | [ExAST.Pattern.pattern()]) :: t()
  def pattern(pattern), do: %__MODULE__{steps: [{:self, compile_pattern(pattern)}]}

  @doc "Alias for `pattern/1`."
  @spec selector(ExAST.Pattern.pattern() | [ExAST.Pattern.pattern()]) :: t()
  def selector(pattern), do: pattern(pattern)

  @doc "SQL-like alias for `pattern/1`."
  @spec from(ExAST.Pattern.pattern() | [ExAST.Pattern.pattern()]) :: t()
  def from(pattern), do: pattern(pattern)

  @doc "Selects direct semantic children matching `pattern`."
  @spec child(t(), ExAST.Pattern.pattern() | [ExAST.Pattern.pattern()]) :: t()
  def child(%__MODULE__{} = selector, pattern),
    do: add_step(selector, :child, compile_pattern(pattern))

  @doc "Selects semantic descendants matching `pattern`."
  @spec descendant(t(), ExAST.Pattern.pattern() | [ExAST.Pattern.pattern()]) :: t()
  def descendant(%__MODULE__{} = selector, pattern),
    do: add_step(selector, :descendant, compile_pattern(pattern))

  @doc "SQL-like alias for `descendant/2`."
  @spec find(t(), ExAST.Pattern.pattern() | [ExAST.Pattern.pattern()]) :: t()
  def find(%__MODULE__{} = selector, pattern), do: descendant(selector, pattern)

  @doc "SQL-like alias for `child/2`."
  @spec find_child(t(), ExAST.Pattern.pattern() | [ExAST.Pattern.pattern()]) :: t()
  def find_child(%__MODULE__{} = selector, pattern), do: child(selector, pattern)

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

  @doc "SQL-like alias for `ancestor/1` and `ancestor/2`."
  @spec inside(ExAST.Pattern.pattern()) :: Predicate.t()
  @spec inside(t(), ExAST.Pattern.pattern()) :: t()
  def inside(pattern), do: ancestor(pattern)
  def inside(%__MODULE__{} = selector, pattern), do: ancestor(selector, pattern)

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

  @doc "SQL-like alias for `has_descendant/1` and `has_descendant/2`."
  @spec contains(ExAST.Pattern.pattern()) :: Predicate.t()
  @spec contains(t(), ExAST.Pattern.pattern()) :: t()
  def contains(pattern), do: has_descendant(pattern)
  def contains(%__MODULE__{} = selector, pattern), do: has_descendant(selector, pattern)

  @doc "Matches when a previous sibling matches `pattern`."
  @spec follows(ExAST.Pattern.pattern()) :: Predicate.t()
  def follows(pattern), do: predicate(:follows, pattern)

  @doc "Matches when a following sibling matches `pattern`."
  @spec precedes(ExAST.Pattern.pattern()) :: Predicate.t()
  def precedes(pattern), do: predicate(:precedes, pattern)

  @doc "Matches when the immediately previous sibling matches `pattern`."
  @spec immediately_follows(ExAST.Pattern.pattern()) :: Predicate.t()
  def immediately_follows(pattern), do: predicate(:immediately_follows, pattern)

  @doc "Matches when the immediately following sibling matches `pattern`."
  @spec immediately_precedes(ExAST.Pattern.pattern()) :: Predicate.t()
  def immediately_precedes(pattern), do: predicate(:immediately_precedes, pattern)

  @doc "Matches the first semantic child in its parent."
  @spec first() :: Predicate.t()
  def first, do: predicate(:first, nil)

  @doc "Matches the last semantic child in its parent."
  @spec last() :: Predicate.t()
  def last, do: predicate(:last, nil)

  @doc "Matches the nth semantic child in its parent, using 1-based indexing."
  @spec nth(pos_integer()) :: Predicate.t()
  def nth(index) when is_integer(index) and index > 0, do: predicate(:nth, index)

  @doc "Matches when any nested predicate matches."
  @spec any([Predicate.t()]) :: Predicate.t()
  def any(predicates) when is_list(predicates), do: predicate(:any, predicates)

  @doc "Matches when all nested predicates match."
  @spec all([Predicate.t()]) :: Predicate.t()
  def all(predicates) when is_list(predicates), do: predicate(:all, predicates)

  @doc "Negates a predicate for use with `where/2`."
  @spec not Predicate.t() :: Predicate.t()
  def not (%Predicate{} = predicate), do: %{predicate | negated?: Kernel.not(predicate.negated?)}

  defp add_step(%__MODULE__{steps: steps} = selector, relation, pattern) do
    %{selector | steps: steps ++ [{relation, pattern}]}
  end

  defp build_predicate_from_ast({:not, _, [expr]}),
    do: not build_predicate_from_ast(unwrap_block(expr))

  defp build_predicate_from_ast({:or, _, [left, right]}),
    do: any([build_predicate_from_ast(left), build_predicate_from_ast(right)])

  defp build_predicate_from_ast({:and, _, [left, right]}),
    do: all([build_predicate_from_ast(left), build_predicate_from_ast(right)])

  defp build_predicate_from_ast({:any, _, [predicates]}),
    do: any(Enum.map(list_ast_to_list(predicates), &build_predicate_from_ast/1))

  defp build_predicate_from_ast({:all, _, [predicates]}),
    do: all(Enum.map(list_ast_to_list(predicates), &build_predicate_from_ast/1))

  defp build_predicate_from_ast({name, _, []}) when name in [:first, :last] do
    apply(__MODULE__, name, [])
  end

  defp build_predicate_from_ast({:nth, _, [index]}) when is_integer(index), do: nth(index)

  defp build_predicate_from_ast({name, _, [pattern]})
       when name in [
              :parent,
              :ancestor,
              :inside,
              :has_child,
              :has_descendant,
              :has,
              :contains,
              :follows,
              :precedes,
              :immediately_follows,
              :immediately_precedes
            ] do
    apply(__MODULE__, name, [pattern])
  end

  defp build_predicate_from_ast(%Predicate{} = predicate), do: predicate

  defp build_predicate_from_ast(ast) do
    raise ArgumentError,
          "unsupported selector predicate expression: #{Macro.to_string(ast)}"
  end

  defp list_ast_to_list(list) when is_list(list), do: list

  defp list_ast_to_list(ast) do
    raise ArgumentError, "expected predicate list, got: #{Macro.to_string(ast)}"
  end

  defp unwrap_block({:__block__, _, [expr]}), do: expr
  defp unwrap_block(expr), do: expr

  defp add_filter(%__MODULE__{filters: filters} = selector, %Predicate{} = predicate) do
    %{selector | filters: filters ++ [predicate]}
  end

  defp predicate(relation, patterns) when relation in [:any, :all] do
    %Predicate{relation: relation, pattern: patterns}
  end

  defp predicate(relation, nil) when relation in [:first, :last] do
    %Predicate{relation: relation, pattern: nil}
  end

  defp predicate(:nth = relation, index) when is_integer(index) do
    %Predicate{relation: relation, pattern: index}
  end

  defp predicate(relation, pattern) do
    %Predicate{relation: relation, pattern: compile_pattern(pattern)}
  end

  defp compile_pattern(pattern) when is_binary(pattern), do: Code.string_to_quoted!(pattern)

  defp compile_pattern(patterns) when is_list(patterns) do
    {:__ex_ast_any_patterns__, Enum.map(patterns, &compile_pattern/1)}
  end

  defp compile_pattern(pattern), do: pattern
end
