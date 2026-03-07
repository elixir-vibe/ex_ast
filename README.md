# ExAST 🔬

Search and replace Elixir code by AST pattern.

Patterns are plain Elixir — variables capture, `_` is a wildcard,
structs match partially. No regex, no custom DSL.

```bash
mix ex_ast.search  'IO.inspect(_)'
mix ex_ast.replace 'IO.inspect(expr, _)' 'Logger.debug(inspect(expr))' lib/
```

## Installation

```elixir
def deps do
  [{:ex_ast, "~> 0.1", only: [:dev, :test], runtime: false}]
end
```

## Pattern syntax

Patterns are valid Elixir expressions parsed by `Code.string_to_quoted!/1`.
Three rules:

| Syntax | Meaning |
|--------|---------|
| `_` or `_name` | Wildcard — matches any node, not captured |
| `name`, `expr`, `x` | Capture — matches any node, bound by name |
| Everything else | Literal — must match exactly |

Structs and maps match **partially** — only the keys you write must be
present. `%User{role: r}` matches any `User` with a `role` field,
regardless of other fields.

Repeated variable names require the same value at every position:
`Enum.map(a, a)` only matches calls where both arguments are identical.

## Examples

### Search

```bash
# Find all IO.inspect calls (any arity)
mix ex_ast.search 'IO.inspect(_)'
mix ex_ast.search 'IO.inspect(_, _)'

# Find structs by field value
mix ex_ast.search '%Step{id: "subject"}' lib/documents/

# Find {:error, _} tuples
mix ex_ast.search '{:error, _}' lib/ test/

# Find GenServer callbacks
mix ex_ast.search 'def handle_call(_, _, _) do _ end'

# Count matches
mix ex_ast.search --count 'dbg(_)'
```

### Replace

```bash
# Remove debug calls
mix ex_ast.replace 'dbg(expr)' 'expr'
mix ex_ast.replace 'IO.inspect(expr, _)' 'expr'

# Replace struct with function call
mix ex_ast.replace '%Step{id: "subject"}' 'SharedSteps.subject_step(@opts)' lib/types/

# Migrate API
mix ex_ast.replace 'Repo.get!(mod, id)' 'Repo.get!(mod, id) || raise NotFoundError'

# Preview without writing
mix ex_ast.replace --dry-run 'use Mix.Config' 'import Config'
```

Captures from the pattern are substituted into the replacement by name.

### Programmatic API

```elixir
# Search
ExAst.search("lib/", "IO.inspect(_)")
#=> [%{file: "lib/worker.ex", line: 12, source: "IO.inspect(data)", captures: %{}}]

# Replace
ExAst.replace("lib/", "dbg(expr)", "expr")
#=> [{"lib/worker.ex", 2}]

# Low-level: single string
ExAst.Patcher.find_all(source_code, "IO.inspect(_)")
ExAst.Patcher.replace_all(source_code, "dbg(expr)", "expr")
```

## What you can match

```elixir
# Function calls
Enum.map(_, _)
Logger.info(_)
Repo.all(_)

# Definitions
def handle_call(msg, _, state) do _ end
def mount(_, _, _) do _ end

# Pipes
_ |> Repo.all()
_ |> Enum.map(_) |> Enum.filter(_)

# Tuples
{:ok, result}
{:error, reason}
{:noreply, state}

# Structs (partial match)
%User{role: :admin}
%Changeset{valid?: false}

# Maps (partial match)
%{name: name}

# Directives
use GenServer
import Ecto.Query
alias MyApp.Accounts.User

# Module attributes
@impl true
@behaviour mod

# Ecto
from(_ in _, _)
cast(_, _)
validate_required(_)

# Control flow
case _ do _ -> _ end
with {:ok, _} <- _ do _ end
fn _ -> _ end
&_/1

# Misc
raise _
dbg(_)
```

## Limitations

- **No function-name wildcards** — `def _(_) do _ end` won't match
  arbitrary function names because `_` in that position parses as a call,
  not a wildcard. Use the actual name or match the `do` block.
- **Exact list length** — `[a, b]` only matches two-element lists. No
  rest/splat syntax.
- **No multi-expression wildcards** — can't match "any number of
  statements" inside a `do` block.
- **Replacement formatting** — the replacement string is rendered by
  `Macro.to_string/1`. Run `mix format` afterward for consistent style.

## How it works

1. Source files are parsed with [Sourceror](https://hex.pm/packages/sourceror),
   preserving source positions and comments
2. The pattern string is parsed with `Code.string_to_quoted!/1`
3. Both ASTs are normalized (metadata stripped, `__block__` wrappers removed)
4. The pattern is matched against every node via depth-first traversal using
   `Sourceror.Zipper`
5. Variables in the pattern bind to the matched subtrees (captures)
6. For replacements, captures are substituted into the replacement template
   and the result is patched into the original source using
   `Sourceror.patch_string/2`, preserving formatting of unchanged code

## License

[MIT](LICENSE)
