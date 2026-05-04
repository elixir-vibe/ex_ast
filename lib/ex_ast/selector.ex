defmodule ExAST.Selector.CommentMatcher do
  @moduledoc """
  Comment text matcher used by comment predicates.
  """

  defstruct [:kind, :value, case_sensitive?: true]

  @type kind :: :text | :exact | :prefix | :suffix
  @type t :: %__MODULE__{kind: kind(), value: String.t(), case_sensitive?: boolean()}
end

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
          | :captures
          | :comment
          | :comment_before
          | :comment_after
          | :comment_inside
          | :comment_inline
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

  `where/2` supports capture guards using `^` to pin captured values,
  allowing runtime checks on matched nodes:

      pattern("Enum.take(_, count)")
      |> where(match?({:-, _, [_]}, ^count))
  """

  alias ExAST.Selector.CommentMatcher
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
    if has_pin?(expr) do
      guard_body = expand_pins(expr)

      quote do
        ExAST.Selector.where_predicate(
          unquote(selector),
          %ExAST.Selector.Predicate{
            relation: :captures,
            pattern: fn captures -> unquote(guard_body) end
          }
        )
      end
    else
      predicate = build_predicate_from_ast(expr)

      quote do
        ExAST.Selector.where_predicate(unquote(selector), unquote(Macro.escape(predicate)))
      end
    end
  end

  defp has_pin?(ast) do
    Macro.prewalk(ast, false, fn
      {:^, _, _}, _ -> {nil, true}
      node, found -> {node, found}
    end)
    |> elem(1)
  end

  defp expand_pins(ast) do
    ast
    |> unwrap_ampersand()
    |> Macro.prewalk(fn
      {:^, _, [{name, _, _}]} -> quote(do: Map.get(captures, unquote(name)))
      node -> node
    end)
  end

  defp unwrap_ampersand({:&, _, [body]}), do: body
  defp unwrap_ampersand(ast), do: ast

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

  @doc "Matches comments associated with the selected node."
  @spec comment(String.t() | Regex.t() | CommentMatcher.t()) :: Predicate.t()
  def comment(matcher), do: predicate(:comment, compile_comment_matcher(matcher))

  @doc "Matches comments immediately before the selected node."
  @spec comment_before(String.t() | Regex.t() | CommentMatcher.t()) :: Predicate.t()
  def comment_before(matcher), do: predicate(:comment_before, compile_comment_matcher(matcher))

  @doc "Matches comments immediately after the selected node."
  @spec comment_after(String.t() | Regex.t() | CommentMatcher.t()) :: Predicate.t()
  def comment_after(matcher), do: predicate(:comment_after, compile_comment_matcher(matcher))

  @doc "Matches comments inside the selected node range."
  @spec comment_inside(String.t() | Regex.t() | CommentMatcher.t()) :: Predicate.t()
  def comment_inside(matcher), do: predicate(:comment_inside, compile_comment_matcher(matcher))

  @doc "Matches inline comments on the selected node start line."
  @spec comment_inline(String.t() | Regex.t() | CommentMatcher.t()) :: Predicate.t()
  def comment_inline(matcher), do: predicate(:comment_inline, compile_comment_matcher(matcher))

  @doc "Builds a substring comment matcher."
  @spec text(String.t(), keyword()) :: CommentMatcher.t()
  def text(value, opts \\ []), do: comment_matcher(:text, value, opts)

  @doc "Builds an exact comment matcher."
  @spec exact(String.t(), keyword()) :: CommentMatcher.t()
  def exact(value, opts \\ []), do: comment_matcher(:exact, value, opts)

  @doc "Builds a comment prefix matcher."
  @spec prefix(String.t(), keyword()) :: CommentMatcher.t()
  def prefix(value, opts \\ []), do: comment_matcher(:prefix, value, opts)

  @doc "Builds a comment suffix matcher."
  @spec suffix(String.t(), keyword()) :: CommentMatcher.t()
  def suffix(value, opts \\ []), do: comment_matcher(:suffix, value, opts)

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

  defp build_predicate_from_ast({name, _, [matcher]})
       when name in [:comment, :comment_before, :comment_after, :comment_inside, :comment_inline] do
    apply(__MODULE__, name, [build_comment_matcher_from_ast(matcher)])
  end

  defp build_predicate_from_ast(%Predicate{} = predicate), do: predicate

  defp build_predicate_from_ast(expr) do
    raise ArgumentError,
          "unsupported selector predicate expression: #{Macro.to_string(expr)}"
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

  defp predicate(relation, %CommentMatcher{} = matcher)
       when relation in [
              :comment,
              :comment_before,
              :comment_after,
              :comment_inside,
              :comment_inline
            ] do
    %Predicate{relation: relation, pattern: matcher}
  end

  defp predicate(relation, %Regex{} = matcher)
       when relation in [
              :comment,
              :comment_before,
              :comment_after,
              :comment_inside,
              :comment_inline
            ] do
    %Predicate{relation: relation, pattern: matcher}
  end

  defp predicate(relation, pattern) do
    %Predicate{relation: relation, pattern: compile_pattern(pattern)}
  end

  defp build_comment_matcher_from_ast({name, _, args})
       when name in [:text, :exact, :prefix, :suffix] do
    {args, _binding} = Code.eval_quoted(args)
    apply(__MODULE__, name, args)
  end

  defp build_comment_matcher_from_ast(ast) do
    {matcher, _binding} = Code.eval_quoted(ast)
    matcher
  end

  defp compile_comment_matcher(%CommentMatcher{} = matcher), do: matcher
  defp compile_comment_matcher(%Regex{} = regex), do: regex
  defp compile_comment_matcher(value) when is_binary(value), do: text(value)

  defp comment_matcher(kind, value, opts) when is_binary(value) do
    %CommentMatcher{kind: kind, value: value, case_sensitive?: Keyword.get(opts, :case, true)}
  end

  defp compile_pattern(pattern) when is_binary(pattern), do: Code.string_to_quoted!(pattern)

  defp compile_pattern(patterns) when is_list(patterns) do
    {:__ex_ast_any_patterns__, Enum.map(patterns, &compile_pattern/1)}
  end

  defp compile_pattern(pattern), do: pattern
end
