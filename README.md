# ExAST 🔬

Search, replace, and diff Elixir code by AST pattern.

Patterns are plain Elixir — variables capture, `_` is a wildcard,
structs match partially, pipes are normalized. No regex, no custom DSL.

```bash
mix ex_ast.search  'IO.inspect(_)'
mix ex_ast.replace 'IO.inspect(expr, _)' 'Logger.debug(inspect(expr))' lib/
mix ex_ast.diff lib/old.ex lib/new.ex
```

## Why

Regex can't tell `IO.inspect(data)` from `IO.inspect(data, label: "debug")`.
Text diff doesn't know a function moved vs changed. ExAST works on the AST —
patterns match structure, not strings.

## Quick examples

```elixir
# Negative literals — flag potential bugs
ExAST.Patcher.find_all(source, "Enum.take(_, -_)")

# Always-true comparisons
ExAST.Patcher.find_all(source, "{a, a}")

# Compile-time config reads
ExAST.Patcher.find_all(source, "@name Application.get_env(_, _)")

# Batch analyzer checks in one scan
ExAST.Patcher.find_many(source,
  get_env: "@_ Application.get_env(_, _)",
  dbg_call: "dbg(expr)"
)

# Preview rewrites before applying patches
ExAST.rewrite_plan(source, "dbg(expr)", "expr")
#=> %ExAST.Rewriter.Plan{replacements: [...], conflicts: []}

# Specific atom values
import ExAST.Query
from("def handle_event(event, _, _) do ... end")
|> where(^event == :click or ^event == :keydown)

# Functions with transaction but no debug output
from("def _ do ... end")
|> where(contains("Repo.transaction(_)"))
|> where(not contains("IO.inspect(...)"))
```

## Installation

```elixir
def deps do
  [{:ex_ast, "~> 0.11", only: [:dev, :test], runtime: false}]
end
```

## Documentation

| Guide | Content |
|-------|---------|
| [Getting Started](https://hexdocs.pm/ex_ast/getting-started.html) | Install, first search, first replace |
| [Pattern Language](https://hexdocs.pm/ex_ast/pattern-language.html) | Syntax, wildcards, captures, ellipsis, pipes, recipes |
| [Querying](https://hexdocs.pm/ex_ast/querying.html) | Relationship filters, selectors, capture guards |
| [Indexing and Code Intelligence](https://hexdocs.pm/ex_ast/indexing.html) | Structural terms, selector plans, comments, symbols |
| [CLI Reference](https://hexdocs.pm/ex_ast/cli.html) | Command-line flags and usage |
| [Diff](https://hexdocs.pm/ex_ast/diff.html) | Syntax-aware code diffing |
| [API Reference](https://hexdocs.pm/ex_ast/api-reference.html) | Module documentation |

## What you can match

```elixir
# Function calls (any arity with ...)
Enum.map(_, _)
Logger.info(...)

# Definitions
def handle_call(msg, _, state) do _ end

# Pipes (matches both forms)
Enum.map(data, f)           # also matches: data |> Enum.map(f)

# Multi-node sequences
a = Repo.get!(_, _); Repo.delete(a)

# Tuples, structs, maps
{:ok, result}
%User{role: :admin}
%{name: name}

# Directives and attributes
use GenServer
@env Application.get_env(_, _)

# Control flow
case _ do _ -> _ end
fn _ -> _ end
```

## Code intelligence APIs

ExAST can expose advisory metadata for external indexes while remaining the
semantic verifier:

```elixir
import ExAST.Query

selector =
  from("def _ do ... end")
  |> where(contains("Repo.transaction(_)"))

ExAST.Index.plan(selector)
#=> %ExAST.Index.Plan{required_terms: ..., requires_source?: false}

ExAST.Symbols.definitions(source)
ExAST.Symbols.references(source)
ExAST.Comments.extract(source)
ExAST.Comments.associated(source, range, :before)

ExAST.Symbols.qualified_name({Enum, :map, 2})
#=> "Enum.map/2"
```

Symbols keep stable string names for indexing and expose optional `mfa` tuples
when a BEAM module can be safely resolved.

Use these terms and facts to retrieve candidates, then verify with
`ExAST.Selector.find_all/3` or `ExAST.Selector.match?/3`.

## Limitations

- Alias/import expansion is syntax-aware, not full semantic macro expansion
- Multi-node patterns require contiguous statements
- Replacement formatting uses `Macro.to_string/1`; pass `format: true` or run `mix format` after

## License

[MIT](LICENSE)
