# Querying

Patterns match shape. Queries add context — "find X only when it's inside Y"
or "find X but only if the captured value is a specific atom."

## Relationship filters

Filter matches by their surrounding context:

```elixir
# Only inside private functions
ExAST.search("lib/", "Repo.get!(_, _)", inside: "defp _ do _ end")

# Exclude test blocks
ExAST.search("lib/", "IO.inspect(_)", not_inside: "test _ do _ end")
```

Available options: `:inside`, `:not_inside`. Also available as CLI flags:

```bash
mix ex_ast.search --inside 'defp _ do _ end' 'Repo.get!(_, _)' lib/
mix ex_ast.search --not-inside 'test _ do _ end' 'IO.inspect(_)' lib/
```

## Query API

Use `ExAST.Query` when a match depends on AST relationships:

```elixir
import ExAST.Query

# Find functions that have a transaction but no debug output
query =
  from("def _ do ... end")
  |> where(contains("Repo.transaction(_)"))
  |> where(not contains("IO.inspect(...)"))

ExAST.search("lib/", query)
```

### Navigation

Move through the tree with `find/2` (descendants) and `find_child/2` (direct children):

```elixir
# Find IO.inspect calls inside any module
from("defmodule _ do ... end")
|> find("IO.inspect(_)")

# Find direct function definitions (not nested ones)
from("defmodule _ do ... end")
|> find_child("def _ do ... end")
```

### Predicates

Filter the current selection without changing it:

| Predicate | Meaning |
|-----------|---------|
| `contains(pattern)` | Has a descendant matching pattern |
| `has_child(pattern)` | Has a direct child matching pattern |
| `inside(pattern)` | Is inside an ancestor matching pattern |
| `parent(pattern)` | Has a direct parent matching pattern |
| `follows(pattern)` | Has a previous sibling matching pattern |
| `precedes(pattern)` | Has a following sibling matching pattern |
| `immediately_follows(pattern)` | Immediately after a matching sibling |
| `immediately_precedes(pattern)` | Immediately before a matching sibling |
| `first()` | First sibling in its parent |
| `last()` | Last sibling in its parent |
| `nth(n)` | nth sibling (1-based) |
| `any([...])` | Any nested predicate matches |
| `all([...])` | All nested predicates match |

The direct children of a call with a block (`do`, `else`, `after`, `rescue`,
`catch`) are the statements of those blocks, whether written as `do ... end` or
`do:`. The rest of the call is not a child: an `if` condition, a `def` head, or
`for` generators and options such as `into:`. For any other call, the children
are its arguments.

Combine with `not`, `and`, `or`:

```elixir
from("IO.inspect(value)")
|> where(inside("def _ do ... end"))
|> where(not parent("if _ do ... end"))
```

### Alternative patterns

Pass a list to match multiple shapes:

```elixir
from(["def _ do ... end", "defp _ do ... end"])
```

## Capture guards

Use `^` inside `where/2` to filter on captured values — similar to Ecto's pin syntax:

```elixir
import ExAST.Query
alias ExAST.Patcher
```

### When to use capture guards

Most filtering can be done with patterns alone (see [Pattern Language](pattern-language.md#recipes)).
Reach for capture guards when you need to:

- Compare two captures to each other
- Filter by specific atom or literal values
- Check the structural type of a captured node

### Multi-capture comparison

```elixir
source = """
x == x
x == y
"""

query = from("left == right") |> where(^left == ^right)
Patcher.find_all(source, query)
#=> matches "x == x" only
```

### Specific atom values

```elixir
source = """
def handle(:click, socket), do: socket
def handle(:keydown, socket), do: socket
def handle(:submit, socket), do: socket
"""

query =
  from("def handle(event, _) do ... end")
  |> where(^event == :click or ^event == :keydown)

Patcher.find_all(source, query)
#=> matches :click and :keydown only
```

### Structural type checks

```elixir
source = """
Enum.map(users, fn u -> u.name end) |> Enum.filter(fn u -> u.active? end)
Enum.filter(users, fn u -> u.active? end)
"""

# Find Enum.filter where the first arg is itself a pipe expression
query =
  from("Enum.filter(expr, _)")
  |> where(match?({{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _, _}, ^expr))

Patcher.find_all(source, query)
#=> matches line 1 only — the one fed by Enum.map
```

Any Elixir expression works inside `where` — `match?/2`, `is_atom/1`, comparisons,
function calls. The `^name` references are replaced with the corresponding
captured AST node at match time.

## Selector introspection and verification

Selectors expose source/comment requirements and direct verification helpers:

```elixir
selector =
  from("def _ do ... end")
  |> where(comment_before("public API"))

ExAST.Selector.requires_source?(selector)
#=> true

ExAST.Selector.requires_comments?(selector)
#=> true

ExAST.Selector.find_all(source, selector)
ExAST.Selector.match?(source, selector)
```

For candidate indexing and code intelligence metadata, see
[Indexing and Code Intelligence](indexing.md).

## Broad queries

`from("_")` matches every AST node. Project-wide searches refuse those
unless you pass a `limit` or opt in explicitly:

```elixir
ExAST.search("lib/", from("_"), limit: 100)
ExAST.search("lib/", from("_"), allow_broad: true)
```

## Lower-level API

`ExAST.Selector` provides the same functionality with CSS-like naming:

```elixir
import ExAST.Selector

pattern("defmodule _ do ... end")
|> descendant("def _ do ... end")
|> child("IO.inspect(_)")
```
