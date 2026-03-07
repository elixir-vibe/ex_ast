# ex_ast — Elixir AST Search & Replace

Search and replace Elixir code by structure, not text. Patterns are valid Elixir syntax.

## Pattern Language

Bare variables = captures, `_`/`_name` = wildcards, everything else = literal match.
Structs and maps match **partially** (only specified keys must be present).

```elixir
IO.inspect(expr)                  # capture arg as "expr"
IO.inspect(_)                     # wildcard
Enum.map(input, fun)              # capture both args
%Step{id: "subject"}              # partial struct, literal value
%Step{id: name, fields: fields}   # partial struct with captures
{:ok, result}                     # tuple capture
def handle_call(msg, _, state)    # function head
_ |> IO.inspect(_)                # pipe pattern
use GenServer                     # directive
@behaviour mod                    # module attribute
```

Repeated variable name = must match same value:
```
Enum.map(a, a)   # only matches when both args are identical
```

## Replace with Captures

Captures from the pattern flow into the replacement template by name:

```bash
ex_ast replace 'IO.inspect(expr, _opts)' 'expr'
ex_ast replace '%Step{id: "subject", fields: fields}' 'SharedSteps.subject_step(fields)'
ex_ast replace 'Repo.get!(mod, id)' 'Repo.get!(mod, id) || raise NotFoundError'
```

## Implementation

### Dependencies

- `sourceror` — AST parsing with source positions, zipper traversal, `patch_string` for surgical edits

### Modules

```
lib/ex_ast.ex                      # Public API
lib/ex_ast/pattern.ex              # AST matching with captures
lib/ex_ast/patcher.ex              # Capture substitution + source patching
lib/mix/tasks/ex_ast.search.ex     # mix ex_ast.search
lib/mix/tasks/ex_ast.replace.ex    # mix ex_ast.replace
```

### ExAst.Pattern

Core matching logic. Both source and pattern are parsed, then normalized:
- `Sourceror.strip_meta` removes positions
- `normalize` unwraps `{:__block__, _, [x]}` → `x` (Sourceror artifact)
- Meta fields become `nil` for comparison

Matching rules:
1. `{name, nil, nil}` where `name` is atom not starting with `_` → **capture** (bind to name, or verify same value if already bound)
2. `{:_, nil, nil}` or `{:_name, nil, nil}` → **wildcard**
3. `{:%, nil, [name, {:%{}, nil, kvs}]}` → **partial struct/map** (pattern keys must be subset of node keys)
4. Dot-calls, 3-tuples, 2-tuples, lists → structural recursion
5. Literals → exact equality

### ExAst.Patcher

1. Walk source AST with Sourceror.Zipper
2. At each node, try `ExAst.Pattern.match(node, pattern)`
3. On match: get `Sourceror.get_range(node)`, substitute captures into replacement template, collect patch
4. Apply all patches via `Sourceror.patch_string(source, patches)`

Substitution: walk replacement AST, replace `{name, _, nil}` capture references with their bound values from the match, then `Macro.to_string` the result.

### Mix Tasks

```bash
# Search — grep-like output
mix ex_ast.search 'IO.inspect(_)' [path]
# Output: file:line:  matched_code

# Replace
mix ex_ast.replace 'IO.inspect(expr, _)' 'Logger.debug(inspect(expr))' [path]
mix ex_ast.replace --dry-run 'dbg(expr)' 'expr'
```

Default path: `lib/` for search, explicit for replace.

### Verified Patterns (from prototyping)

All of these work with Sourceror's search_pattern + our custom matching:
- Function calls: `IO.inspect(_)`, `Enum.map(_, _)`, `Logger.info(_)`
- Definitions: `def handle_call(_, _, _)`, `def mount(_, _, _)`
- Pipes: `_ |> IO.inspect(_)`, `_ |> Repo.all()`
- Tuples: `{:ok, _}`, `{:error, _}`, `{:noreply, _}`
- Structs (partial): `%Step{id: "subject"}`, `%Field{kind: :enum}`
- Directives: `use _`, `import _`, `alias _`
- Attributes: `@behaviour _`, `@impl true`
- Ecto: `from(_ in _, _)`, `cast(_, _)`, `validate_required(_)`
- LiveView: `def handle_event(_, _, _)`, `assign(_, _)`
- Tests: `assert {:ok, _} = _`, `assert _ == _`
- Control: `case _ do _ -> _ end`, `with {:ok, _} <- _ do _ end`
- Anonymous: `fn _ -> _ end`, `&_/1`

### Known Limitations (v1)

- `_` as function name in `def _(x)` won't act as wildcard (parsed as call, not variable)
- List matching is exact-length (no "rest" / splat)
- No multi-expression wildcards (can't match "any number of statements in a do block")
- Replacement indentation follows Macro.to_string, may need `mix format` after
