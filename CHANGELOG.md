# Changelog

## Unreleased

### Fixed

- Source term extraction now also indexes the pipe operator itself for piped
  source calls, preserving exact candidate retrieval for pipe-pattern queries.
- Source term extraction now recognizes Sourceror-wrapped integer literals in
  call-argument terms and no longer indexes wrapper `__block__` nodes as calls.
- Pattern term extraction no longer requires impossible pipe same-argument terms
  or literal wildcard function names in `def` patterns.
- Term extraction now indexes direct keyword literal argument terms, including
  atom-free tagged keyword keys.

## 0.12.8

### Fixed

- Source term extraction now indexes pipe-equivalent call arities so normalized
  direct-call patterns can retrieve piped-call candidates from external indexes.

## 0.12.7

### Fixed

- Tagged identifier term extraction now tolerates map and struct update tails without crashing.

## 0.12.6

### Added

- Added tagged identifier support for atom-free indexed ASTs, including pattern matching, candidate terms, and symbol extraction.

## 0.12.5

### Fixed

- Bare imports no longer rewrite every local call while matching canonical remote-call patterns.
- Explicit multi-arity imports such as `import Foo, only: [bar: 1, bar: 2]` now resolve all listed arities.

## 0.12.4

### Added

- Index explicit `nil` and small integer literals as candidate terms.
- Index direct call argument literal terms, including boolean argument-class terms for `true`/`false`.
- Infer boolean call-argument candidate terms from selector capture predicates that only accept boolean literal captures.

### Fixed

- Selector predicates with metadata-only `nil` payloads no longer contribute `atom:nil` candidate terms.

## 0.12.3

### Fixed

- Boolean literals are now included as low-signal index terms so structural candidate filtering can narrow patterns that explicitly match `true` or `false`.

## 0.12.2

### Fixed

- `ExAST.search/3`, `ExAST.Patcher.find_all/3`, and CLI search now include
  explicitly passed `.exs` files, `.exs` globs, and `.exs` files found during
  directory scans.
- `ExAST.Patcher.find_all/3` now keeps walking after a match, so matching pipe
  stages nested inside later matching pipe stages are reported.

## 0.12.1

### Changed

- `ExAST.Patcher.find_many/3` now batches simple single-step selectors with
  single-node patterns, reducing repeated selector traversals while preserving
  tagged results.

### Fixed

- `ExAST.Patcher.find_many/3` now passes source comments to selector filters for
  source-string input, matching `find_all/3` behavior.

## 0.12.0

### Added

- JSON output for `mix ex_ast.search`, `mix ex_ast.replace`, and
  `mix ex_ast.diff` via `--format json` / `--json`, backed by `Jason.Encoder`
  protocol implementations for ExAST result structs.
- `%ExAST.CompiledPattern{}` metadata for compiled patterns, including
  candidate signatures, structural terms, and broad/multi-node flags.
- `ExAST.Pattern.compile_ast/1` for callers that need the normalized pattern AST.
- `ExAST.rewrite_plan/4` and `ExAST.Rewriter` for inspecting replacement plans
  before applying patches, with overlapping-replacement conflict detection.
- File-level parallelism for unbounded `ExAST.search/3` and `search_many/3`,
  configurable with `:concurrency`.
- Conservative source-text prefiltering using index terms to avoid parsing files
  that cannot match a pattern.
- `ExAST.Comments.associated/3` for retrieving comments related to a source
  range (`:before`, `:after`, `:inside`, `:inline`, or aggregate `:comment`).
- Import-aware call matching for imported functions such as
  `import Ecto.Query, only: [from: 2]` matching `Ecto.Query.from(_, _)`.
- Reach, ExSlop, and ExDNA-backed static analysis hardening in CI via an
  isolated `tools/reach_runner` project.

### Changed

- `ExAST.Pattern.compile/1` now returns `%ExAST.CompiledPattern{}` instead of a
  raw normalized AST. Use `ExAST.Pattern.compile_ast/1` for the old AST shape.
- `ExAST.search/3` results now include the matched `:range`.
- `ExAST.replace/4` now plans rewrites before applying them and supports
  `format: true`; the CLI exposes this as `--format-output`.
- Syntax-aware diffing now treats same-body function renames as function updates
  rather than delete+insert pairs.
- `mix ci` now includes explicit ExSlop smell analysis and Reach smell/dead-code
  checks in addition to existing compile, format, Credo, Dialyzer, tests, and
  ExDNA checks.

## 0.11.2

### Fixed

- Wildcard `_` and `_name` now match function names in `def`/`defp` patterns
  with arguments. Previously `defp _(_), do: _` would not match
  `defp helper(x), do: x + 1` because the wildcard in head position couldn't
  match the atom `:helper` when arguments were present.

## 0.11.1

### Added

- `piped()` selector predicate — matches only when the selected node is a pipe
  expression (`|>`). Since ExAST normalizes pipes during matching, there was
  previously no way to distinguish piped from direct call forms. Use
  `where(piped())` to match only piped calls, or `where(not piped())` for
  direct calls only.

## 0.11.0

### Added

- `ExAST.Index.plan/1`, `ExAST.Index.terms/1`, and structural index plan
  structs for building external candidate indexes while keeping ExAST as the
  semantic verifier.
- `ExAST.Index.Terms.from_source/1`, `from_ast/1`, `from_pattern/1`, and term
  signal classification helpers.
- `ExAST.Selector.requires_source?/1`, `requires_comments?/1`, `find_all/3`,
  and `match?/3` for source-aware selector planning and verification.
- `ExAST.Comments.extract/1` and `ExAST.Comments.text/1` for comment extraction
  with source position metadata.
- `ExAST.Symbols.definitions/1` and `ExAST.Symbols.references/1` for syntactic
  definition/reference extraction.
- Symbol helpers for stable qualified names and optional BEAM-native MFA tuples:
  `ExAST.Symbols.qualified_name/1`, `mfa/1`, and `matches?/2`.
- Indexing and code intelligence guide.

## 0.10.1

### Fixed

- Restored pipe-aware pattern matching after the `0.10.0` candidate prefilter
  optimization. Piped calls such as `data |> Enum.map(fun)` now match direct
  call patterns like `Enum.map(_, _)` again.

## 0.10.0

### Added

- `ExAST.Patcher.find_many/3` for running multiple named AST pattern checks in a
  single traversal where possible, returning matches tagged with `:pattern`.
- `ExAST.search_many/3` for searching files with multiple named patterns while
  preserving `search/3` options such as `:limit`.

### Changed

- Optimized repeated single-node pattern matching by compiling patterns once,
  normalizing candidate nodes once per traversal, and using conservative call
  signature prefilters for common local, remote, piped, and nested call patterns.

## 0.9.1

### Changed

- Restructured documentation: short README with topic-based guides
  (Getting Started, Pattern Language, Querying, CLI Reference, Diff)

## 0.9.0

### Added

- **Capture guards** — `where/2` now accepts `^pin` syntax to filter on captured
  values, similar to Ecto's parameter references:
  ```elixir
  from("Enum.take(_, count)")
  |> where(match?({:-, _, [_]}, ^count))
  ```
  Supports `match?/2` for structural checks, plain comparisons
  (`^event == :click`), multi-capture expressions (`^left == ^right`),
  and composition with existing structural predicates.

- **Source text in match results** — `Patcher.find_all/3` now includes a
  `:source` field with the matched source snippet. `nil` for AST/zipper input.

- **Module attribute pattern matching** — attribute names are now captureable:
  ```elixir
  Patcher.find_all(source, "@name Application.get_env(_, _)")
  ```
  Previously `@env Application.get_env(...)` would not match a pattern with
  a different attribute name, even as a capture variable.

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
