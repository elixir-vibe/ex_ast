# Changelog

## 0.8.1

### Fixed

- CLI commands now handle closed stdout pipes cleanly, so commands like
  `mix ex_ast.search ... | head` no longer emit EPIPE writer crash messages.

## 0.8.0

### Added

- **Comment predicates** — queries can now filter by associated source comments
  with `comment/1`, `comment_before/1`, `comment_after/1`, `comment_inside/1`,
  and `comment_inline/1`. Comment matchers accept strings, regexes, and explicit
  text matchers like `prefix/2`, `suffix/2`, and `text/2`. CLI comment filters
  detect `/.../` and `~r/.../` regex syntax.

## 0.7.0

### Added

- **SQL-like query API** via `ExAST.Query`: `from/1`, `where/2`, `find/2`,
  `find_child/2`, `contains/1`, `inside/1`, sibling predicates
  (`follows/1`, `precedes/1`, `immediately_follows/1`,
  `immediately_precedes/1`), positional predicates (`first/0`, `last/0`,
  `nth/1`), and boolean predicate combinators (`any/1`, `all/1`).
- **Selector alternatives** — query starts can now accept a list of alternative
  patterns, e.g. `from(["def _ do ... end", "defp _ do ... end"])`.
- **Search limits and broad-query guard** — `ExAST.search/3` and
  `mix ex_ast.search` now support `limit: n` / `--limit n` and refuse
  unbounded `from("_")` searches unless `allow_broad: true` / `--allow-broad`
  is passed.
- **Query-style CLI flags** — `mix ex_ast.search` and `mix ex_ast.replace` now
  support `--contains`, sibling filters (`--follows`, `--precedes`,
  `--immediately-follows`, `--immediately-precedes`), and position filters
  (`--first`, `--last`, `--nth`).

### Fixed

- **Selector negation now works Ecto-style without import hacks** — `where(not ...)`
  is rewritten by the selector DSL, so users no longer need
  `import Kernel, except: [not: 1]`.
- **Search result rendering** no longer fails when the current project formatter
  config references unavailable `import_deps`.
- **Selector descendant traversal** now walks nested AST shapes reliably,
  fixing missed matches for remote calls nested inside assignments and control flow.
- **Alias-aware matching** expands local `alias` directives so canonical remote-call
  patterns like `AshPhoenix.Form.for_update(...)` match alias-based call sites like
  `Form.for_update(...)`.
- **Grouped alias handling** now supports real-world forms such as
  `alias Phoenix.Socket.{Broadcast, Message, Reply}`.
- **Alias collection** no longer misclassifies ordinary variables named `alias`
  as alias directives.

## 0.6.0

### Added

- **CSS-like AST selectors** — build relationship-aware selectors with
  `ExAST.Selector`:
  ```elixir
  import ExAST.Selector

  pattern("defmodule _ do ... end")
  |> descendant("def _ do ... end")
  |> child("IO.inspect(_)")
  ```
- **Selector predicates** — filter selected nodes with `where/2` and
  Ecto-style `not/1`: `parent/1`, `ancestor/1`, `has_child/1`,
  `has_descendant/1`, and `has/1`.
- **CLI relationship filters** for `mix ex_ast.search` and
  `mix ex_ast.replace`: `--parent`, `--ancestor`, `--has-child`,
  `--has-descendant`, `--has`, and corresponding `--not-*` flags.

## 0.5.0

### Added

- **Ellipsis (`...`)** — matches zero or more nodes in function args, lists,
  and block bodies: `IO.inspect(...)`, `foo(first, ..., last)`,
  `def run(_) do ... end`
- **`~p` sigil** — compile-time pattern parsing via `import ExAST.Sigil`

## 0.4.0

### Added

- **Syntax-aware diff** — `ExAST.diff/3`, `ExAST.diff_files/3`, `ExAST.apply_diff/1`
  - GumTree-inspired AST matching: functions matched by name/arity, nodes by kind/label/signature
  - Edit classification: `:insert`, `:delete`, `:update`, `:move`
  - Function reorder detection reported as `:move` edits
  - Child suppression: edits covered by a parent update/insert/delete are rolled up
  - Inline line-level diffs within updated nodes (Myers algorithm via `List.myers_difference`)
  - Patch application: `ExAST.apply_diff/1` produces patched source from a diff result
- **`mix ex_ast.diff`** CLI task
  - Colored output with `-`/`+` markers (red/green, auto-detected)
  - `--no-color`, `--no-moves`, `--summary`, `--json` flags
  - Human-readable labels (`def create/1` instead of `{:def, :create, 1}`)
- **AST and zipper input** — `Patcher.find_all/3` and `Patcher.replace_all/4`
  now accept source strings, `Sourceror.Zipper`, or raw AST as input.
  Source-string variants return strings, AST/zipper variants return AST.
- **Quoted expressions as patterns** — patterns and replacements can be
  strings or quoted expressions:
  ```elixir
  Patcher.find_all(source, quote(do: IO.inspect(_)))
  Patcher.replace_all(ast, quote(do: IO.inspect(expr)), quote(do: dbg(expr)))
  ```
  `inside`/`not_inside` options also accept quoted.
- **Ellipsis (`...`)** — matches zero or more nodes in args, lists, and
  block bodies. `IO.inspect(...)` matches any arity,
  `foo(first, ..., last)` captures surrounding args,
  `def run(_) do ... end` matches any body.
- **`~p` sigil** — compile-time pattern parsing via `import ExAST.Sigil`:
  `~p"IO.inspect(...)"` returns parsed AST with no runtime overhead.
- **ex_dna** added to CI checks

## 0.3.0

- Pipe awareness: `data |> Enum.map(f)` matches `Enum.map(data, f)`
- Where conditions: `--inside`, `--not-inside` filters
- Multi-node patterns: `a = Repo.get!(_, _); Repo.delete(a)`

## 0.2.0

- Initial release with search and replace
