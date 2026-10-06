# CLI Reference

## Search

```bash
mix ex_ast.search 'PATTERN' PATH [OPTIONS]
```

Search files for AST pattern matches. PATH can be a file, directory, or glob.

### Options

| Flag | Meaning |
|------|---------|
| `-e`, `--pattern PATTERN` | Add a pattern to a multi-pattern batch (repeatable). See [Multiple patterns](#multiple-patterns) |
| `--count` | Print match count only |
| `--count-by-file` | Print per-file match counts, most matches first |
| `--print NAME` | Print only the value captured by `NAME`, one per match, with no file or line prefix. Every pattern must declare `NAME` |
| `-A N`, `-B N`, `-C N` | Print `N` lines after, before, or around each match, grouped under a file heading like ripgrep (`--after-context`, `--before-context`, `--context`) |
| `--color` / `--no-color` | Force colored context output on or off. By default it is colored only when writing to a terminal |
| `--limit N` | Stop after N matches |
| `--allow-broad` | Allow patterns like `_` that match everything |
| `--expand-imports` | Resolve `import Mod` to `Mod`'s real exports, scoped per module, so `map(a, b)` matches `Mod.map(_, _)`. Requires `Mod` to be loadable |
| `--format json` / `--json` | Print structured JSON output |
| `--inside PATTERN` | Only match inside ancestors matching pattern |
| `--not-inside PATTERN` | Reject matches inside ancestors matching pattern |
| `--parent PATTERN` | Direct semantic parent matches pattern |
| `--not-parent PATTERN` | Direct semantic parent does not match pattern |
| `--ancestor PATTERN` | Any semantic ancestor matches pattern |
| `--not-ancestor PATTERN` | No ancestor matches pattern |
| `--has-child PATTERN` | Has a direct child matching pattern |
| `--not-has-child PATTERN` | No direct child matches pattern |
| `--contains PATTERN` | Has a descendant matching pattern |
| `--not-contains PATTERN` | No descendant matches pattern |
| `--follows PATTERN` | Previous sibling matches pattern |
| `--not-follows PATTERN` | No previous sibling matches pattern |
| `--precedes PATTERN` | Following sibling matches pattern |
| `--not-precedes PATTERN` | No following sibling matches pattern |
| `--immediately-follows PATTERN` | Immediately previous sibling matches pattern |
| `--immediately-precedes PATTERN` | Immediately following sibling matches pattern |
| `--first` | First sibling in parent |
| `--not-first` | Not first sibling |
| `--last` | Last sibling in parent |
| `--not-last` | Not last sibling |
| `--nth N` | Nth sibling (1-based) |
| `--not-nth N` | Not nth sibling |
| `--comment TEXT` | Associated comments contain TEXT |
| `--not-comment TEXT` | No associated comments contain TEXT |
| `--comment-before TEXT` | Comment immediately before contains TEXT |
| `--comment-after TEXT` | Comment immediately after contains TEXT |
| `--comment-inside TEXT` | Comment inside range contains TEXT |
| `--comment-inline TEXT` | Inline comment on start line contains TEXT |

Comment values are substring matches. Use `/.../` for regex:

```bash
mix ex_ast.search 'def _ do ... end' --comment-inside '/TODO|FIXME/'
```

### Examples

```bash
# Find all IO.inspect calls
mix ex_ast.search 'IO.inspect(_)' lib/

# Find structs by field
mix ex_ast.search '%Step{id: "subject"}' lib/

# Only inside private functions
mix ex_ast.search --inside 'defp _ do _ end' 'Repo.get!(_, _)'

# Count matches
mix ex_ast.search --count 'dbg(_)' lib/

# Per-file match counts, most matches first
mix ex_ast.search 'IO.inspect(_)' lib/ --count-by-file

# Resolve a bare `import Enum` to its real exports
mix ex_ast.search 'Enum.map(_, _)' lib/ --expand-imports

# Print every value a config key is set to, for piping into other tools
mix ex_ast.search 'config :my_app, feature_enabled: x' config/ --print x

# Show two lines of context around each match
mix ex_ast.search 'Repo.transaction(_)' lib/ -C 2
```

### Output modes

Only one output mode applies. `--json` wins over `--print`, and `--print` wins
over `--count` and `--count-by-file`. The context flags (`-A`, `-B`, `-C`)
cannot be combined with `--count`, `--count-by-file`, `--json` or `--print`.

With context, match lines are numbered `12:`, context lines `11-`, and `--`
separates groups that don't touch:

```
lib/app/worker.ex
11-  def run(job) do
12:    Repo.transaction(fn -> process(job) end)
13-  end
```

## Multiple patterns

Pass a repeatable `-e` / `--pattern` flag to search several patterns in one
invocation. Each file is read and parsed once for the whole batch, avoiding BEAM
startup and per-file re-parsing per pattern — useful for analyzers that run many
checks over the same tree.

```bash
mix ex_ast.search -e 'IO.inspect(_)' -e 'dbg(_)' lib/
```

In this mode there is no positional pattern; remaining positional args are
paths. Combining a positional pattern with `-e` is an error.

### Per-pattern selector filters

Selector-scoping flags (`--inside`, `--not-inside`, `--parent`, `--contains`,
etc.) are *per-pattern*: a filter binds to the most recent preceding `-e`,
mirroring `grep -e`. Filters do not bleed across patterns.

```bash
mix ex_ast.search \
  -e 'App.Repo.get!(_, _)' --inside 'def handle_call(_, _, _) do _ end' \
  -e 'IO.inspect(_)' --not-inside 'test _ do _ end' \
  lib/ test/
```

Global flags (`--count`, `--json`, `--print`, `-A`/`-B`/`-C`,
`--expand-imports`, `--limit`, `--allow-broad`, paths) apply to the whole
batch. With `--print NAME`, every `-e` pattern must declare `NAME`.

### Output

Each match is tagged by its pattern string:

```
[IO.inspect(_)] lib/foo.ex:12
  IO.inspect(result)

[dbg(_)] lib/bar.ex:88
  dbg(value)

2 pattern(s), 2 match(es)
```

`--count` prints a per-pattern tally plus a total; `--json` includes the
`pattern` field on each match. Duplicate `-e` patterns raise an error, and
`--count-by-file` is not supported with `-e`.

Multi-pattern search uses one shared path list for all patterns, so per-pattern
path include/exclude is not expressible in a single call — group patterns by
shared path scope into separate invocations. Per-pattern *selector filters* do
work, since they live in each pattern's selector.

## Replace

```bash
mix ex_ast.replace 'PATTERN' 'REPLACEMENT' PATH [OPTIONS]
```

Replace AST pattern matches in files. Captures from the pattern are substituted
into the replacement by name.

### Options

Same relationship filters as `search`. Additional:

| Flag | Meaning |
|------|---------|
| `--dry-run` | Preview changes without writing files |
| `--format json` / `--json` | Print structured JSON summary |
| `--format-output` | Run the Elixir formatter on modified files |

### Examples

```bash
# Remove debug calls
mix ex_ast.replace 'dbg(expr)' 'expr' lib/

# Migrate API
mix ex_ast.replace 'Repo.get!(mod, id)' 'Repo.get!(mod, id) || raise NotFoundError' lib/

# Keep the remaining arguments with `...`
mix ex_ast.replace 'Logger.debug(msg, ...)' 'Logger.warning(msg, ...)' lib/

# Preview without writing
mix ex_ast.replace --dry-run 'use Mix.Config' 'import Config' lib/

# Preview as JSON
mix ex_ast.replace --dry-run --format json 'dbg(expr)' 'expr' lib/

# Format changed files
mix ex_ast.replace --format-output 'dbg(expr)' 'expr' lib/

# Only outside tests
mix ex_ast.replace --not-inside 'test _ do _ end' 'IO.inspect(expr)' 'expr' lib/
```

## Diff

```bash
mix ex_ast.diff FILE1 FILE2 [OPTIONS]
```

Syntax-aware diff between two Elixir files.

### Options

| Flag | Meaning |
|------|---------|
| `--summary` | Print summary lines only |
| `--no-moves` | Disable move detection |
| `--no-color` | Disable colored output |
| `--json` / `--format json` | Print edits as JSON |

### Example output

```
lib/old.ex ↔ lib/new.ex

L2 UPDATE updated function def first/0
  - def first, do: 1
  + def first, do: 10

L5 INSERT inserted function def fourth/0
  + def fourth, do: 4

2 edit(s)
```
