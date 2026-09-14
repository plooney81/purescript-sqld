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

The suite takes the `spec-node` runner's options after `--`, which is the
quickest loop while one test is red:

```
spago test -- --example "window"    # only tests whose full name contains it
spago test -- --only-failures       # only what failed on the last run
spago test -- -n                    # the above, stopping at the first failure
```

The last run is recorded in `.spec-results`, which is ignored by git.

## Warnings are errors

`spago.yaml` sets `strict: true` on both `package.build` and `package.test`, so
any compiler warning in `src/` or `test/` fails the build — an unused import, a
shadowed name, a binding introduced and never used.

The formatters already break loudly on their own: they carry no catch-all case,
so a constructor added to `Sqld.Core` leaves them non-exhaustive, and because
they are monomorphic that is a type error rather than a warning. This flag
extends the same idea to everything the compiler would otherwise only mention
in passing, which is the class that accumulates across refactors.

Fix the warning rather than working around it. If one genuinely has to be
tolerated, `censorProjectWarnings` in `spago.yaml` is the escape hatch — record
why in a comment beside it. Nothing is censored today.

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

## When the generated queries fail

`make validate` also replays two hundred randomly generated queries
(`test/Sqld/Generate.purs`), from a fresh seed each run. A failure there looks
different from a corpus failure: it is a query nobody wrote, and it may not
recur on the next run.

The seed is the whole of what a reproduction takes, and the validator prints it:

```
SQLD_GEN_SEED=12345 make validate                       # the same run again
SQLD_GEN_SEED=12345 SQLD_GEN_SHRINK=1 make validate     # cut down to size
```

With `SQLD_GEN_SHRINK=1` the suite emits shrink candidates alongside each query
and the validator reports the smallest one that still fails — a line or two
rather than a screenful. Every shrink is type-preserving by construction, so the
smaller query fails for the same reason the larger one did.

Then decide which side is wrong:

- **sqld is wrong.** Fix it, and add the shrunk query to `test/Sqld/Corpus.purs`
  as a regression entry — the generator will not reliably find it again, and the
  corpus runs every time. `cast-negative-literal` and the two `nonassoc-`
  entries all arrived this way.
- **The generator is wrong**, because it built SQL PostgreSQL was never going to
  accept — a `FOR UPDATE` on an outer join, an ungrouped column. Tighten the
  generator so it cannot produce that shape, and say why in a comment: those
  comments are the accumulated record of PostgreSQL's rules about which clauses
  may sit together.

## Documentation that is generated

`EXAMPLES.md` is generated from `src/Example/Cookbook.purs` — do not edit it by
hand. Change the cookbook, then:

```
make examples        # regenerate
make examples-check  # fail if stale (this is what CI runs)
```

`COVERAGE.md` is generated from PostgreSQL's regression suite by
`make coverage` — also do not edit it by hand. It is the answer to "how much of
PostgreSQL do we support?", and unlike a checklist neither side of it is
maintained here: adding a constructor and the corpus entry the coverage rule
already demands moves the number by itself. It needs `npm install libpg-query`
and a PostgreSQL source tree, so it runs on demand rather than in CI:

```
make coverage PG_SOURCE=/path/to/postgres
```

Regenerate it when a change lands that the number should reflect. The
prerequisites are documented at the top of `scripts/coverage-report.mjs`.

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

- [ ] `make validate` passes locally (a compiler warning fails it)
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
