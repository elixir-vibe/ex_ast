defmodule ExAST.CLI.JSON do
  @moduledoc false

  alias ExAST.CLI.Output

  def encode!(value) do
    value
    |> normalize()
    |> Jason.encode!(pretty: true)
  end

  def print(value) do
    value
    |> encode!()
    |> Output.puts()
  end

  def normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  def normalize(%Sourceror.Range{} = range), do: range
  def normalize(%_{} = struct), do: struct

  def normalize(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, normalize_value(key, item)} end)
  end

  def normalize(value), do: value

  defp normalize_value(:captures, captures) when is_map(captures) do
    Map.new(captures, fn {key, value} -> {key, render_ast(value)} end)
  end

  defp normalize_value(_key, value), do: normalize(value)

  defp render_ast(value) do
    Macro.to_string(value)
  rescue
    _ -> inspect(value)
  end
end
