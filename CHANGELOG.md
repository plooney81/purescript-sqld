# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- `Sqld.Expr` module — expression constructors, literals, comparison operators, and logical combinators
- `Sqld.Select` module — SELECT query builders and select-list helpers
- `cols :: Array String -> Array SelectExpr` — convenience helper for selecting a list of plain column names
- `expr :: Expr -> SelectExpr` — wraps an `Expr` into a `SelectExpr` for use in a select list
- `colAs :: String -> String -> SelectExpr` — column reference with inline alias (`"col" AS "alias"`)
- `tcolAs :: String -> String -> String -> SelectExpr` — table-qualified column reference with inline alias (`"t"."col" AS "alias"`)
- SELECT query builder with composable `Query -> Query` helpers
- WHERE expressions as a tagged union ADT (`Expr`)
- JOIN support: `innerJoin`, `leftJoin`, `leftJoinAs`
- Logical combinators: `and`, `or`, `not`, `isNull`, `isNotNull`
- Set operators: `in_`, `notIn`
- Range / pattern operators: `between`, `like`, `ilike`
- Comparison infix operators: `.==`, `.!=`, `.<`, `.<=`, `.>`, `.>=`
- `groupBy` / `having` / `orderBy` / `limit` / `offset`
- `mergeQueries` for combining query fragments
- `raw` escape hatch for unsupported SQL fragments
- Pure `format` function — explicit state threading, no `Effect`
- `formatInline` — substitutes all values directly into the SQL string (for debugging and logging only)
- `formatPretty` — like `formatInline`, with each clause on its own line
- PostgreSQL numbered params (`$1`, `$2`, …); no string interpolation
- All identifiers double-quoted via `quoteIdent` (PostgreSQL-safe)
- Example module
- PostgreSQL validation harness — every query in the corpus is replayed against a real server via `PREPARE`. Because `PREPARE` runs full parse *analysis* rather than a syntax check alone, unknown columns, invalid `GROUP BY`, and operator type mismatches fail alongside malformed SQL. Both formatter outputs are validated: the parameterised form from `format` and the debug form from `formatInline`
- `Test.Sqld.Corpus` — one canonical corpus of queries, consumed by both the golden tests and the PostgreSQL harness, with each entry tagged by the AST constructors it exercises
- Coverage ratchet — `Test.Sqld.CorpusSpec` fails if any `Sqld.Core` constructor has no corpus entry, so a new feature cannot ship without SQL that PostgreSQL has accepted
- `test/fixtures/schema.sql` — fixture tables the corpus references
- `scripts/validate-sql.mjs` — the validator, supporting `--only <pattern>`, `--sql <query>` for ad-hoc probes, and `--list`
- `scripts/pg-validate-local.sh` — local runs against a throwaway Docker PostgreSQL container
- `Makefile` — `make validate`, `validate-fast`, `sql`, `list`, `pg-stop`, and a self-documenting `make help`
- CI runs the harness against a `postgres:16` service container on every push and pull request

### Changed
- `select` is now additive — calling it multiple times appends to the select list rather than replacing it
- Table aliases now render with explicit `AS` keyword (`FROM "users" AS "u"` instead of `FROM "users" "u"`)
- Implicit `SELECT *` removed — use `select [star]` explicitly
