# Pattern Language

Patterns are valid Elixir expressions given as strings or `quote` blocks.

## Rules

| Syntax | Meaning |
|--------|---------|
| `_` or `_name` | Wildcard — matches any node, not captured |
| `name`, `expr`, `x` | Capture — matches any node, bound by name |
| `...` | Ellipsis — matches a variable-length remainder in calls, lists, tuples, blocks, maps, and structs |
| Everything else | Literal — must match exactly |

Repeated variable names require the same value at every position:

```elixir
# Only matches when both arguments are the same
source = """
{x, x}
{x, y}
"""

ExAST.Patcher.find_all(source, "{a, a}")
#=> matches line 1 only
```

## Definition names and arity

Use `name`, `fun`, or `function` to capture a definition name. Add `/N` to
constrain the definition by arity, or `/_` to accept any arity:

```elixir
"def name/2 do ... end"   # any two-argument def, capturing its name
"def _/0 do ... end"      # any zero-argument def, without a capture
"defp name/_ do ... end"  # any private def, capturing its name
```

Like parenthesized definition patterns, arity patterns must include a matching
body clause when the source definition has one.

## Wildcard callees

A wildcard can stand in for the name of a local or remote call:

```elixir
"_(...)"          # any local call
"_._(...)"        # any remote call
"_.section(...)"  # section/any-arity on any module
"Repo._(...)"     # any call on Repo
```

`_(...)` only matches calls; definitions, control-flow forms, and operators are
excluded.

## Pipes

Pipes are desugared before matching — write the pattern in either form:

```elixir
# Both patterns match both forms:
source = """
Enum.map(users, fn u -> u.name end)
users |> Enum.map(fn u -> u.name end)
"""

ExAST.Patcher.find_all(source, "Enum.map(_, _)")
#=> 2 matches

ExAST.Patcher.find_all(source, "_ |> Enum.map(_)")
#=> 2 matches (same results)
```

Arity checks use the normalized call. For example, `x |> Map.get(key, default)`
matches `Map.get(_, _, _)`, not `Map.get(_, _)`.

## Ellipsis

`...` absorbs a variable-length portion of calls, lists, tuples, and blocks:

```elixir
"IO.inspect(...)"             # any call arity
"foo(first, ...)"             # one or more args; capture the first
"def run(_) do ... end"       # any function body

"[...]"                       # any list, including empty
"[first, ...]"                # capture the leading item
"[..., last]"                 # capture the trailing item
"[first, ..., last]"          # capture both list edges

"{...}"                       # any tuple arity
"{:ok, ...}"                  # any tuple beginning with :ok
"{first, ..., last}"          # capture both tuple edges
```

It can also make the remainder explicit in map and struct patterns:

```elixir
"%{...}"
"%{..., role: :admin}"
"%User{...}"
```

## Structs and maps

Partial matching — only specified keys must be present:

```elixir
source = """
%User{name: "Alice", age: 30, role: :admin}
%{name: "Alice", age: 30, role: :admin}
"""

ExAST.Patcher.find_all(source, "%User{role: role}")
#=> [%{captures: %{role: :admin}}]

ExAST.Patcher.find_all(source, "%{role: role}")
#=> [%{captures: %{role: :admin}}]

# Explicit `...` is accepted but not required for subset matching:
ExAST.Patcher.find_all(source, "%{..., role: role}")
#=> [%{captures: %{role: :admin}}]
```

## Multi-node patterns

Separate statements with `;` to match contiguous sequences within a block:

```elixir
source = """
a = Repo.get!(User, 1)
Logger.info(a)
Repo.delete(a)
"""

ExAST.Patcher.find_all(source, "a = Repo.get!(_, _); Repo.delete(a)")
#=> matches lines 1 and 3 — captures are consistent across statements
```

## Imports and aliases

Alias expansion is syntax-aware, so canonical remote-call patterns match aliased
call sites:

```elixir
source = """
alias AshPhoenix.Form
Form.for_update(form, :update)
"""

ExAST.Patcher.find_all(source, "AshPhoenix.Form.for_update(_, _)")
#=> matches the aliased call
```

Imported calls can also match their canonical module when the import is explicit:

```elixir
source = """
import Ecto.Query, only: [from: 2]
from(u in User, where: u.id == 1)
"""

ExAST.Patcher.find_all(source, "Ecto.Query.from(_, _)")
#=> matches the imported call
```

## Module attributes

Attribute names are captureable — the `@name` inside `@name(expr)` matches like a variable, not a literal:

```elixir
source = """
@env Application.get_env(:app, :key)
@port 4000
@db_url Application.get_env(:app, :db_url)
"""

ExAST.Patcher.find_all(source, "@name Application.get_env(_, _)")
#=> [%{captures: %{name: :env}}, %{captures: %{name: :db_url}}]
```

Use `@_` to wildcard the name.

## Recipes

Common patterns that solve real problems without needing queries or guards:

```elixir
# Negative literal — flag potential bugs
"Enum.take(_, -_)"

# Specific atom in a tuple
"{:ok, val}"

# Same value in two positions (always-true comparison)
"{a, a}"

# String literal
"Logger.info(\"starting\")"

# Any module attribute read at compile time
"@_ Application.get_env(_, _)"

# Pipe chain (matches both pipe and direct form)
"Enum.filter(_, _) |> Enum.map(_)"
```
