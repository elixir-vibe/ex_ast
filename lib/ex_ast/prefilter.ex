defmodule ExAST.Prefilter do
  @moduledoc false

  alias ExAST.Index
  alias ExAST.Index.Terms
  alias ExAST.Selector

  @spec may_match?(String.t(), ExAST.Pattern.pattern() | Selector.t()) :: boolean()
  def may_match?(source, pattern_or_selector) when is_binary(source) do
    pattern_or_selector
    |> required_tokens()
    |> Enum.all?(&String.contains?(source, &1))
  rescue
    _ -> true
  end

  defp required_tokens(%Selector{} = selector) do
    plan = Index.plan(selector)

    if plan.requires_source? or plan.requires_comments? do
      []
    else
      tokens_from_terms(plan.required_terms)
    end
  end

  defp required_tokens(pattern) do
    pattern
    |> Index.plan()
    |> Map.fetch!(:required_terms)
    |> tokens_from_terms()
  end

  defp tokens_from_terms(terms) do
    terms
    |> Enum.reject(&Terms.low_signal?/1)
    |> Enum.flat_map(&term_tokens/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp term_tokens("call.remote:" <> rest),
    do: [rest |> String.split(".") |> List.last() |> before_arity()]

  defp term_tokens("call.local:__block__/" <> _arity), do: []
  defp term_tokens("call.local:" <> rest), do: [before_arity(rest)]
  defp term_tokens("call.function:" <> fun), do: [fun]
  defp term_tokens("def.name:" <> _name), do: []
  defp term_tokens("def:" <> _rest), do: []
  defp term_tokens("attribute:" <> name), do: ["@#{name}"]
  defp term_tokens("struct.field:" <> field), do: [field]
  defp term_tokens("map.key:" <> key), do: [key]
  defp term_tokens("atom:" <> _atom), do: []
  defp term_tokens(_term), do: []

  defp before_arity(value) do
    case :binary.split(value, "/") do
      [name, _arity] -> name
      [name] -> name
    end
  end
end
