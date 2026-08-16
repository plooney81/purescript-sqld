# Contributing to sqld

Thanks for taking a look. `sqld` is a PostgreSQL query builder for PureScript:
queries are plain data, builders are `Query -> Query`, and `format` is pure.
Contributions that keep those properties are very welcome.

By participating you agree to abide by the [Code of Conduct](CODE_OF_CONDUCT.md).

## Getting set up

You need the PureScript toolchain, Node 20+, and Docker (for the validation
harness).

```
npm install -g purescript spago
spago install
make build
```

`make` on its own lists every target with a one-line description.

## The development loop

```
make build           # compile
make test            # golden tests; also emits test-artifacts/corpus.json
make validate        # tests, then replay every query against real PostgreSQL
make validate-fast   # skip spago test, reuse the warm container
```

Narrow a validation run while iterating, or probe a query without adding a
corpus entry at all:

```
make list                          # corpus entry names
make validate-fast ONLY=join       # only entries matching "join"
make sql SQL='SELECT "u".* FROM "users" AS "u"'
```

`make sql` is the fastest way to answer "will PostgreSQL accept this?" during a
formatter change. `make pg-stop` removes the container when you are done.

## The rule that shapes most changes

Golden tests prove `format` emits the string we expected. The validation
harness proves PostgreSQL actually accepts that string. **Both must pass, and a
new feature cannot ship without a corpus entry.**

`test/Sqld/Corpus.purs` is the single corpus both harnesses consume. Each entry
is tagged with the AST constructors it exercises, and `Test.Sqld.CorpusSpec`
fails if any constructor in `Sqld.Core` has no entry.

So when you add a constructor to `Sqld.Core`:

1. The tagging functions in the corpus become non-exhaustive — the compiler
   tells you exactly where.
2. Tag the new constructor, and the coverage assertion then fails until a corpus
   entry actually exercises it.
3. Add the entry. Every table and column it references must exist in
   `test/fixtures/schema.sql` — add them there if not.
4. Run `make validate` and confirm PostgreSQL accepts the emitted SQL.

This is deliberate friction. It is why the README can claim every documented
query has been run against a real server.

## Documentation that is generated

`EXAMPLES.md` is generated from `src/Example/Cookbook.purs` — do not edit it by
hand. Change the cookbook, then:

```
make examples        # regenerate
make examples-check  # fail if stale (this is what CI runs)
```

Add a `CHANGELOG.md` entry under `## [Unreleased]` for anything user-visible.

## Style

- **`where` clauses over `let` bindings** for helper definitions.
- **Point-free composition with `<<<`** where it reads more clearly than a
  lambda; do not contort code to achieve it.
- Match the surrounding module — comment density and naming included.
- No implicit `SELECT *`; no string interpolation of literals. Values become
  numbered params, identifiers get quoted.

## Commits and pull requests

Commit messages use a [gitmoji](https://gitmoji.dev) prefix and an imperative
summary:

```
:sparkles: Window functions (OVER, PARTITION BY, frames)
:bug: An empty IN list folds to a constant, not IN ()
:recycle: Collapse the expression AST onto generic nodes
:memo: Worked example cookbook, generated and PostgreSQL-validated
:white_check_mark: Validate emitted SQL against real PostgreSQL
:art: Point-free helpers and where clauses over let bindings
```

Before opening a pull request:

- [ ] `make validate` passes locally
- [ ] `make examples-check` passes (or you regenerated `EXAMPLES.md`)
- [ ] new AST constructors have corpus entries
- [ ] `CHANGELOG.md` updated under `[Unreleased]`

CI runs the same steps against PostgreSQL 16 on every push and pull request.

## Scope

`sqld` is PostgreSQL-only and currently SELECT-only, on purpose. Proposals for
other dialects will likely be declined; proposals for other statement types
(INSERT, UPDATE, DELETE) are interesting — please open an issue to discuss the
shape before writing much code.

`raw` exists as the escape hatch for anything the builders do not cover. If you
find yourself reaching for it often for the same construct, that is a good issue
to file.
