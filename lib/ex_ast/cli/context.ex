defmodule ExAST.CLI.Context do
  @moduledoc false

  alias ExAST.CLI.Output
  alias ExAST.Pattern

  @span_style [:bright]
  @capture_styles [[:red, :bright], [:yellow, :bright], [:cyan, :bright], [:blue, :bright]]

  def print(results, window, color?) do
    results
    |> Enum.chunk_by(& &1.file)
    |> Enum.with_index()
    |> Enum.each(fn {[%{file: file} | _] = matches, index} ->
      if index > 0, do: Output.puts()
      print_file(file, matches, window, color?)
    end)
  end

  defp print_file(file, matches, {before, after_}, color?) do
    source = File.read!(file)
    lines = source_lines(source)
    ast = if color?, do: parse(source)

    styles =
      matches
      |> Enum.flat_map(&match_styles(&1, ast, lines))
      |> Enum.sort_by(fn {_range, style} -> style != @span_style end)
      |> Enum.flat_map(&line_columns/1)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Output.puts(IO.ANSI.format_fragment([:magenta, file, :reset], color?))

    matches
    |> Enum.map(fn match ->
      {{first, _}, {last, _}} = span_range(match)
      {max(first - before, 1), min(last + after_, tuple_size(lines))}
    end)
    |> Enum.sort()
    |> merge_groups()
    |> Enum.with_index()
    |> Enum.each(fn {group, index} ->
      if index > 0, do: Output.puts("--")
      print_group(group, lines, styles, color?)
    end)
  end

  defp source_lines(source) do
    lines = String.split(source, "\n")
    lines = if String.ends_with?(source, "\n"), do: Enum.drop(lines, -1), else: lines
    List.to_tuple(lines)
  end

  defp parse(source) do
    case Sourceror.parse_string(source) do
      {:ok, ast} -> {ast, Pattern.collect_aliases(ast)}
      {:error, _} -> nil
    end
  end

  defp match_styles(match, ast, lines) do
    span = span_range(match)
    [{span, @span_style} | capture_styles(match, span, ast, lines)]
  end

  defp capture_styles(_match, _span, nil, _lines), do: []

  defp capture_styles(%{captures: captures}, span, {ast, aliases}, lines) do
    candidates = nodes_within(ast, span, aliases, lines)

    captures
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.zip(Stream.cycle(@capture_styles))
    |> Enum.flat_map(fn {{_name, value}, style} ->
      for {range, normalized} <- candidates, normalized == value, do: {range, style}
    end)
  end

  defp span_range(%{range: %{start: start, end: end_}, line: line}) do
    {{start[:line] || line, start[:column] || 1},
     {end_[:line] || line, end_[:column] || :infinity}}
  end

  defp span_range(%{line: line}), do: {{line, 1}, {line, :infinity}}

  defp nodes_within(term, span, aliases, lines) do
    case node_range(term, lines) do
      nil ->
        Enum.flat_map(children(term), &nodes_within(&1, span, aliases, lines))

      range ->
        cond do
          disjoint?(range, span) ->
            []

          within?(range, span) ->
            [
              {range, Pattern.normalize_node(term, aliases)}
              | Enum.flat_map(children(term), &nodes_within(&1, span, aliases, lines))
            ]

          true ->
            Enum.flat_map(children(term), &nodes_within(&1, span, aliases, lines))
        end
    end
  end

  defp children({form, _meta, args}) when is_list(args), do: [form | args]
  defp children({left, right}), do: [left, right]
  defp children(list) when is_list(list), do: list
  defp children(_term), do: []

  # Sourceror ends a bare `true`, `false` or `nil` one column after the literal.
  defp node_range({:__block__, _meta, [literal]} = node, lines)
       when literal in [true, false, nil] do
    with {{line, column} = start, _end} = range <- sourceror_range(node) do
      text = Atom.to_string(literal)
      length = String.length(text)

      if lines |> elem(line - 1) |> String.slice(column - 1, length) == text,
        do: {start, {line, column + length}},
        else: range
    end
  end

  defp node_range({_form, meta, _args} = node, _lines) when is_list(meta),
    do: sourceror_range(node)

  defp node_range({left, right}, lines),
    do: join_ranges(node_range(left, lines), node_range(right, lines))

  defp node_range([_ | _] = list, lines),
    do: join_ranges(node_range(hd(list), lines), node_range(List.last(list), lines))

  defp node_range(_term, _lines), do: nil

  defp sourceror_range(node) do
    case Sourceror.get_range(node) do
      %{start: start, end: end_} -> {{start[:line], start[:column]}, {end_[:line], end_[:column]}}
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp join_ranges({start, _}, {_, end_}), do: {start, end_}
  defp join_ranges(_first, _last), do: nil

  defp within?({start, end_}, {span_start, span_end}),
    do: start >= span_start and end_ <= span_end

  defp disjoint?({start, end_}, {span_start, span_end}),
    do: end_ <= span_start or start >= span_end

  defp line_columns({{{first, from}, {last, to}}, style}) do
    for line <- first..last do
      {line,
       {if(line == first, do: from, else: 1), if(line == last, do: to, else: :infinity), style}}
    end
  end

  defp merge_groups(groups) do
    groups
    |> Enum.reduce([], fn
      {first, last}, [{prev_first, prev_last} | rest] when first <= prev_last + 1 ->
        [{prev_first, max(last, prev_last)} | rest]

      group, acc ->
        [group | acc]
    end)
    |> Enum.reverse()
  end

  defp print_group({first, last}, lines, styles, color?) do
    for number <- first..last do
      text = elem(lines, number - 1)

      line =
        case Map.fetch(styles, number) do
          {:ok, columns} -> [":" | highlight(text, columns)]
          :error -> ["-", text]
        end

      Output.puts(IO.ANSI.format_fragment([:green, "#{number}", :reset | line], color?))
    end
  end

  defp highlight(text, columns) do
    text
    |> String.graphemes()
    |> Enum.with_index(1)
    |> Enum.chunk_by(fn {_char, column} -> style_at(column, columns) end)
    |> Enum.map(fn [{_char, column} | _] = chunk ->
      chunk_text = Enum.map_join(chunk, &elem(&1, 0))

      case style_at(column, columns) do
        nil -> chunk_text
        style -> style ++ [chunk_text, :reset]
      end
    end)
  end

  # Later entries win, so a capture's color overrides the span style around it.
  defp style_at(column, columns) do
    Enum.reduce(columns, nil, fn {from, to, style}, acc ->
      if column >= from and column < to, do: style, else: acc
    end)
  end
end
