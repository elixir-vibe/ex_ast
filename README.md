# ExAST 🔬

Search and replace Elixir code by AST pattern.

Patterns are plain Elixir — variables capture, `_` is a wildcard,
structs match partially, pipes are normalized. No regex, no custom DSL.

```bash
mix ex_ast.search  'IO.inspect(_)'
mix ex_ast.replace 'IO.inspect(expr, _)' 'Logger.debug(inspect(expr))' lib/
```

## Installation

```elixir
def deps do
  [{:ex_ast, "~> 0.2", only: [:dev, :test], runtime: false}]
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

### Pipe awareness

Pipes are desugared before matching — `data |> Enum.map(f)` and
`Enum.map(data, f)` are treated as equivalent. You can write the
pattern in either form and it will match both:

```bash
# Matches both `Enum.map(data, f)` and `data |> Enum.map(f)`
mix ex_ast.search 'Enum.map(_, _)'
```

### Multi-node patterns

Separate statements with `;` to match contiguous sequences within a block:

```bash
# Find get-then-delete patterns
mix ex_ast.search 'a = Repo.get!(_, _); Repo.delete(a)'

# Captures are consistent across statements —
# `a` must refer to the same variable in both
```

### Where conditions

Filter matches by their surrounding context with `--inside` and `--not-inside`:

```bash
# Only inside private functions
mix ex_ast.search --inside 'defp _ do _ end' 'Repo.get!(_, _)'

# Exclude test blocks
mix ex_ast.search --not-inside 'test _ do _ end' 'IO.inspect(_)'

# Both at once
mix ex_ast.search --inside 'def _ do _ end' --not-inside 'if _ do _ end' 'IO.inspect(_)'
```

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

# Find piped calls (matches both piped and direct)
mix ex_ast.search 'Enum.map(_, _)'

# Find get-then-delete across sequential statements
mix ex_ast.search 'a = Repo.get!(_, _); Repo.delete(a)'

# Only inside private functions
mix ex_ast.search --inside 'defp _ do _ end' 'Repo.get!(_, _)'
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

# Only replace outside tests
mix ex_ast.replace --not-inside 'test _ do _ end' 'IO.inspect(expr)' 'expr'
```

Captures from the pattern are substituted into the replacement by name.

### Programmatic API

```elixir
# Search
ExAST.search("lib/", "IO.inspect(_)")
#=> [%{file: "lib/worker.ex", line: 12, source: "IO.inspect(data)", captures: %{}}]

# Search with where conditions
ExAST.search("lib/", "Repo.get!(_, _)", inside: "defp _ do _ end")

# Replace
ExAST.replace("lib/", "dbg(expr)", "expr")
#=> [{"lib/worker.ex", 2}]

# Replace with context filter
ExAST.replace("lib/", "IO.inspect(expr)", "expr", not_inside: "test _ do _ end")

# Low-level: single string
ExAST.Patcher.find_all(source_code, "IO.inspect(_)")
ExAST.Patcher.find_all(source_code, "IO.inspect(_)", inside: "def _ do _ end")
ExAST.Patcher.replace_all(source_code, "dbg(expr)", "expr")
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

# Pipes (normalized — matches both forms)
_ |> Repo.all()
Enum.map(data, f)           # also matches: data |> Enum.map(f)

# Multi-node sequences
a = Repo.get!(_, _); Repo.delete(a)
x = compute(_); Logger.info(x)

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
- **Multi-node requires contiguity** — `a = Repo.get!(_, _); Repo.delete(a)`
  only matches when the two statements are adjacent. Intervening statements
  break the match.
- **Replacement formatting** — the replacement string is rendered by
  `Macro.to_string/1`. Run `mix format` afterward for consistent style.

## How it works

1. Source files are parsed with [Sourceror](https://hex.pm/packages/sourceror),
   preserving source positions and comments
2. The pattern string is parsed with `Code.string_to_quoted!/1`
3. Both ASTs are normalized (metadata stripped, `__block__` wrappers removed,
   pipes desugared)
4. The pattern is matched against every node via depth-first traversal using
   `Sourceror.Zipper`
5. Variables in the pattern bind to the matched subtrees (captures)
6. For multi-node patterns, block bodies are scanned for contiguous
   subsequences matching all pattern statements with consistent captures
7. Where conditions (`inside`/`not_inside`) filter matches by checking
   whether any ancestor node matches the given pattern
8. For replacements, captures are substituted into the replacement template
   and the result is patched into the original source using
   `Sourceror.patch_string/2`, preserving formatting of unchanged code

## License

[MIT](LICENSE)
