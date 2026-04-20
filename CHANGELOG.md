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

## 0.3.0

- Pipe awareness: `data |> Enum.map(f)` matches `Enum.map(data, f)`
- Where conditions: `--inside`, `--not-inside` filters
- Multi-node patterns: `a = Repo.get!(_, _); Repo.delete(a)`

## 0.2.0

- Initial release with search and replace
