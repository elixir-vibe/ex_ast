# ExAST 🔬

Search, replace, and diff Elixir code by AST pattern.

Patterns are plain Elixir — variables capture, `_` is a wildcard,
structs match partially, pipes are normalized. No regex, no custom DSL.

```bash
mix ex_ast.search  'IO.inspect(_)'
mix ex_ast.replace 'IO.inspect(expr, _)' 'Logger.debug(inspect(expr))' lib/
mix ex_ast.diff lib/old.ex lib/new.ex
```

## Installation

```elixir
def deps do
  [{:ex_ast, "~> 0.6", only: [:dev, :test], runtime: false}]
end
```

## Pattern syntax

Patterns are valid Elixir expressions, given as strings or `quote` blocks.
Three rules:

| Syntax | Meaning |
|--------|---------|
| `_` or `_name` | Wildcard — matches any node, not captured |
| `name`, `expr`, `x` | Capture — matches any node, bound by name |
| `...` | Ellipsis — matches zero or more nodes (args, list items, block body) |
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

### CLI relationship filters

Filter matches by their surrounding context with `--inside` and `--not-inside`:

```bash
# Only inside private functions
mix ex_ast.search --inside 'defp _ do _ end' 'Repo.get!(_, _)'

# Exclude test blocks
mix ex_ast.search --not-inside 'test _ do _ end' 'IO.inspect(_)'

# Both at once
mix ex_ast.search --inside 'def _ do _ end' --not-inside 'if _ do _ end' 'IO.inspect(_)'
```

Search and replace also support CSS-like relationship predicates:

```bash
# Direct semantic parent only — excludes nested calls inside if/case/fn blocks
mix ex_ast.search 'IO.inspect(expr)' --parent 'def _ do ... end'

# Any semantic ancestor
mix ex_ast.search 'IO.inspect(expr)' --ancestor 'def _ do ... end'

# Find functions that contain a transaction but no debug output
mix ex_ast.search 'def name do ... end' \
  --has 'Repo.transaction(_)' \
  --not-has 'IO.inspect(_)'

# Replace only direct function-body debug calls
mix ex_ast.replace 'IO.inspect(expr)' 'Logger.debug(inspect(expr))' lib/ \
  --parent 'def _ do ... end'

# Replace calls only in functions matching broader context predicates
mix ex_ast.replace 'Repo.get!(schema, id)' 'Repo.fetch!(schema, id)' lib/ \
  --ancestor 'def _ do ... end' \
  --not-ancestor 'test _ do ... end'
```

Available CLI filters:

| Flag | Meaning |
|------|---------|
| `--parent`, `--not-parent` | Direct semantic parent |
| `--ancestor`, `--not-ancestor` | Any semantic ancestor |
| `--inside`, `--not-inside` | Aliases for ancestor filters |
| `--has-child`, `--not-has-child` | Direct semantic child |
| `--has-descendant`, `--not-has-descendant` | Any semantic descendant |
| `--has`, `--not-has` | Aliases for descendant filters |

### Selectors

Use `ExAST.Selector` when a match depends on CSS-like AST relationships:

```elixir
import ExAST.Selector

selector =
  pattern("defmodule _ do ... end")
  |> descendant("def _ do ... end")
  |> child("IO.inspect(_)")

ExAST.search("lib/", selector)
```

Use `where/2` with predicates to keep or reject the selected node without
changing what gets returned:

```elixir
import ExAST.Selector

selector =
  pattern("def _ do ... end")
  |> where(has_descendant("Repo.transaction(_)"))
  |> where(not(has_descendant("IO.inspect(_)")))
```

Available relationships and predicates:

| Function | Meaning |
|----------|---------|
| `child/2` | Select direct semantic children matching the pattern |
| `descendant/2` | Select nested semantic descendants matching the pattern |
| `where/2` | Add a predicate filter without changing the selected node |
| `parent/1` / `parent/2` | Match/apply a direct semantic parent predicate |
| `ancestor/1` / `ancestor/2` | Match/apply a semantic ancestor predicate |
| `has_child/1` / `has_child/2` | Match/apply a direct semantic child predicate |
| `has_descendant/1`, `has/1` | Match a nested descendant predicate |
| `has_descendant/2`, `has/2` | Apply a nested descendant predicate |
| `not/1` | Negate a predicate for `where/2` |

`where/2` accepts predicate expressions and rewrites `not(...)` the way an Ecto-style
DSL would, so you can use bare `not(...)` directly.

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

### Diff

Syntax-aware diff between two Elixir files. Unlike text-based diffs,
it understands Elixir structure — functions are matched by name and
arity, reorders are reported as moves, and changes are classified by
kind (function, call, map, keyword, assignment).

```bash
# Compare two files
mix ex_ast.diff lib/old.ex lib/new.ex

# Only print summary lines
mix ex_ast.diff --summary lib/old.ex lib/new.ex

# Disable move detection
mix ex_ast.diff --no-moves lib/old.ex lib/new.ex

# Print edits as Elixir terms
mix ex_ast.diff --json lib/old.ex lib/new.ex
```

Example output:

```
lib/old.ex ↔ lib/new.ex

L2 MOVE moved function def first/0

L3 MOVE moved function def second/0

L2 UPDATE updated function def first/0
  - def first, do: 1
  + def first, do: 10

L5 INSERT inserted function def fourth/0
  + def fourth, do: 4

4 edit(s)
```

What it detects:

- **Function updates** — body or guard changes, with old/new source
- **Function inserts/deletes** — matched by `{name, arity}`
- **Function reorders** — reported as `:move` edits
- **Call updates** — local and remote calls matched by name/arity
- **Map/struct/keyword changes** — key-based matching
- **Pipeline changes** — pipes are normalized, stages matched individually
- **Assignments** — `=` bindings tracked as distinct semantic nodes

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

# Low-level: source string
ExAST.Patcher.find_all(source_code, "IO.inspect(_)")
ExAST.Patcher.find_all(source_code, "IO.inspect(_)", inside: "def _ do _ end")
ExAST.Patcher.replace_all(source_code, "dbg(expr)", "expr")

# Low-level: AST or zipper (returns AST instead of string)
ast = Sourceror.parse_string!(source_code)
ExAST.Patcher.find_all(ast, "IO.inspect(_)")
ExAST.Patcher.replace_all(ast, "IO.inspect(expr)", "dbg(expr)")  #=> Macro.t()

zipper = Sourceror.Zipper.zip(ast)
ExAST.Patcher.find_all(zipper, "IO.inspect(_)")

# Quoted expressions instead of strings
ExAST.Patcher.find_all(source_code, quote(do: IO.inspect(_)))
ExAST.Patcher.replace_all(ast, quote(do: IO.inspect(expr)), quote(do: dbg(expr)))

# ~p sigil for compile-time pattern parsing
import ExAST.Sigil
ExAST.Patcher.find_all(source_code, ~p"IO.inspect(...)")

# Syntax-aware diff
result = ExAST.diff(old_source, new_source)
result.edits
#=> [%ExAST.Diff.Edit{op: :update, kind: :function, summary: "...", ...}]

result = ExAST.diff(old_source, new_source, include_moves: false)
ExAST.diff_files("lib/old.ex", "lib/new.ex")
```

Each edit is an `%ExAST.Diff.Edit{}` struct with:

| Field | Description |
|-------|-------------|
| `op` | `:insert`, `:delete`, `:update`, or `:move` |
| `kind` | `:function`, `:call`, `:remote_call`, `:map`, `:struct`, `:keyword`, `:assignment`, `:module` |
| `summary` | Human-readable description |
| `old_range` / `new_range` | Source positions (`%Sourceror.Range{}`) |
| `old_id` / `new_id` | Internal node IDs from the annotated tree |
| `meta` | `%{old: "...", new: "..."}` with rendered source for updates |

## What you can match

```elixir
# Function calls (any arity with ...)
Enum.map(_, _)
Logger.info(...)
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
- **Alias expansion is local syntax-aware, not semantic** — `alias AshPhoenix.Form`
  lets `Form.for_update(...)` match `AshPhoenix.Form.for_update(...)` within the
  same matched AST, but ExAST does not expand macros or resolve imports the way
  the compiler does.
- **Exact list length** — `[a, b]` only matches two-element lists. Use
  `[a, b, ...]` to match two-or-more, or `[...]` for any length.
- **No multi-expression wildcards in sequences** — `...` matches a
  block body but can't be used inside `;`-separated multi-node patterns.
- **Multi-node requires contiguity** — `a = Repo.get!(_, _); Repo.delete(a)`
  only matches when the two statements are adjacent. Intervening statements
  break the match.
- **Replacement formatting** — the replacement string is rendered by
  `Macro.to_string/1`. Run `mix format` afterward for consistent style.
- **Diff is structural, not semantic** — macros are not expanded.
  Moves are only detected for functions within the same module body.

## How it works

### Search & Replace

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

### Diff

1. Both source strings are parsed with Sourceror and annotated into
   a tree of nodes, each with a stable ID, kind, label, normalized hash,
   source range, and parent/child relationships
2. **Anchor phase** — functions are matched by `{name, arity}` across
   trees; their parent container nodes are mapped transitively; the root
   nodes are always mapped
3. **Semantic matching** — remaining unmatched nodes are scored by kind,
   label, signature, parent mapping, and subtree size similarity, then
   greedily matched to the best candidate
4. **Child recovery** — keyed children (map fields, keyword entries)
   are matched by key; ordered children under modules/functions are matched
   by compatibility
5. **Classification** — each mapping pair is checked for content changes
   (hash mismatch → `:update`); unmatched left nodes → `:delete`;
   unmatched right nodes → `:insert`; matched functions whose sibling
   order changed → `:move`
6. Edits are sorted by source position and deduplicated

The algorithm is inspired by [GumTree](https://github.com/GumTreeDiff/gumtree),
adapted for Elixir's specific AST shape — `do` blocks, keyword lists,
pipe normalization, and Sourceror's comment-preserving metadata.

## License

[MIT](LICENSE)
