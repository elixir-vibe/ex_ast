# ExAST Agent Guidelines

This repository is part of the Elixir Vibe organization.

ExAST searches, replaces, and diffs Elixir code by AST pattern.

## Development

Use the project’s Mix aliases whenever possible.

```sh
mix deps.get
mix compile
mix test
mix format
```

Preferred full check:

```sh
mix ci
```

Current full CI alias includes:

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix credo --strict
mix dialyzer
mix test
mix ex_dna
```

## Guidelines

- Use ExAST when code structure matters; prefer it over regex for Elixir code transformations.
- Preserve Sourceror-compatible formatting and comments where possible.
- Pattern matching should be syntax-aware, not string-based.
- Keep APIs comfortable for agent tools: structured results, clear failure reasons.
- Add tests for matching edge cases, especially aliases, pins, captures, sigils, and metadata-sensitive syntax.
- Do not publish, tag, or bump versions unless explicitly requested.
