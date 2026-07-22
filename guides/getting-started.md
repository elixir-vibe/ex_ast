# Getting Started

## Installation

Add ExAST as a dev dependency:

```elixir
def deps do
  [{:ex_ast, "~> 0.13", only: [:dev, :test], runtime: false}]
end
```

## First search

Find every `IO.inspect` call in your project:

```bash
mix ex_ast.search 'IO.inspect(_)' lib/
```

Patterns are plain Elixir syntax — `_` is a wildcard, variables capture:

```bash
# Any arity
mix ex_ast.search 'IO.inspect(...)' lib/

# Capture the argument
mix ex_ast.search 'IO.inspect(expr)' lib/

# Specific two-arg calls
mix ex_ast.search 'IO.inspect(_, _)' lib/
```

## First replace

Remove all `dbg` calls — the captured `expr` substitutes into the replacement:

```bash
mix ex_ast.replace 'dbg(expr)' 'expr' lib/
```

Preview without writing files:

```bash
mix ex_ast.replace --dry-run 'use Mix.Config' 'import Config' lib/
```

Emit structured JSON for tools and agents:

```bash
mix ex_ast.search 'IO.inspect(expr)' lib/ --format json
mix ex_ast.replace --dry-run 'dbg(expr)' 'expr' lib/ --format json
```

## Programmatic API

Everything the CLI does is available as functions:

```elixir
# Search files
ExAST.search("lib/", "IO.inspect(_)")
#=> [%{file: "lib/worker.ex", line: 12, source: "IO.inspect(data)", captures: %{}}]

# Replace in files
ExAST.replace("lib/", "dbg(expr)", "expr")
#=> [{"lib/worker.ex", 2}]

# Plan replacements without applying them
plan = ExAST.rewrite_plan(source_code, "dbg(expr)", "expr")
#=> %ExAST.Rewriter.Plan{replacements: [...], conflicts: []}

# Low-level: work with source strings
ExAST.Patcher.find_all(source_code, "IO.inspect(_)")
#=> [%{node: ..., range: ..., captures: %{}, source: "IO.inspect(data)"}]

ExAST.Patcher.replace_all(source_code, "dbg(expr)", "expr")
#=> "source with dbg calls removed"
```

For large project searches, ExAST uses conservative text prefilters and scans
files in parallel by default. Pass `concurrency: n` to tune file-level search
parallelism.

## What's next

- [Pattern Language](pattern-language.md) — full syntax reference
- [Querying](querying.md) — relationship filters, selectors, capture guards
- [Indexing and Code Intelligence](indexing.md) — structural terms, selector plans, comments, symbols
- [CLI Reference](cli.md) — command-line flags and usage
- [Diff](diff.md) — syntax-aware code diffing
