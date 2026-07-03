defmodule ExAST.Ident do
  @moduledoc false

  @tag :__exograph_ident__

  def tag(name) when is_binary(name), do: {@tag, name}

  def ident?({@tag, name}) when is_binary(name), do: true
  def ident?(_term), do: false

  def name({@tag, name}) when is_binary(name), do: name
  def name(atom) when is_atom(atom), do: Atom.to_string(atom)
  def name(other), do: other

  def equal?(left, right) when left == right, do: true

  def equal?(ident, atom) when is_atom(atom) do
    ident?(ident) and name(ident) == Atom.to_string(atom)
  end

  def equal?(atom, ident) when is_atom(atom), do: equal?(ident, atom)
  def equal?(_left, _right), do: false

  def display({@tag, name}) when is_binary(name), do: name
  def display(atom) when is_atom(atom), do: Atom.to_string(atom)
  def display(other), do: to_string(other)
end
