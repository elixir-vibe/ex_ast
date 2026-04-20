# Changelog

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
- **ex_dna** added to CI checks

## 0.3.0

- Pipe awareness: `data |> Enum.map(f)` matches `Enum.map(data, f)`
- Where conditions: `--inside`, `--not-inside` filters
- Multi-node patterns: `a = Repo.get!(_, _); Repo.delete(a)`

## 0.2.0

- Initial release with search and replace
