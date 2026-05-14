# CLI Reference

## Search

```bash
mix ex_ast.search 'PATTERN' PATH [OPTIONS]
```

Search files for AST pattern matches. PATH can be a file, directory, or glob.

### Options

| Flag | Meaning |
|------|---------|
| `--count` | Print match count only |
| `--limit N` | Stop after N matches |
| `--allow-broad` | Allow patterns like `_` that match everything |
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
```

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
