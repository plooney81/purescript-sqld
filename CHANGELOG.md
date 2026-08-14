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
- Generic AST nodes covering most of PostgreSQL's expression grammar: `App` (any function in `pg_proc`), `BinOp` (any operator in `pg_operator`), `Unary`, `Postfix`, `Cast` (`expr::type`), `Row`, and `Sub` (subqueries in expression position)
- `app`, `binOp`, `unary`, `postfix`, `cast`, `row`, `sub` — direct access to the generic nodes, so unsupported SQL no longer requires `raw`
- Subquery helpers: `exists`, `notExists`, `inSub`, `notInSub`, and `sub` for scalar subqueries. Parameter numbering threads through subqueries in left-to-right order
- `notLike` / `notILike`
- Function wrappers over `app`: `count`, `countStar`, `sum_`, `avg`, `min_`, `max_`, `coalesce`, `lower`, `upper`
- PostgreSQL validation harness — every query in the corpus is replayed against a real server via `PREPARE`. Because `PREPARE` runs full parse *analysis* rather than a syntax check alone, unknown columns, invalid `GROUP BY`, and operator type mismatches fail alongside malformed SQL. Both formatter outputs are validated: the parameterised form from `format` and the debug form from `formatInline`
- `Test.Sqld.Corpus` — one canonical corpus of queries, consumed by both the golden tests and the PostgreSQL harness, with each entry tagged by the AST constructors it exercises
- Coverage ratchet — `Test.Sqld.CorpusSpec` fails if any `Sqld.Core` constructor has no corpus entry, so a new feature cannot ship without SQL that PostgreSQL has accepted
- `test/fixtures/schema.sql` — fixture tables the corpus references
- `scripts/validate-sql.mjs` — the validator, supporting `--only <pattern>`, `--sql <query>` for ad-hoc probes, and `--list`
- `scripts/pg-validate-local.sh` — local runs against a throwaway Docker PostgreSQL container
- `Makefile` — `make validate`, `validate-fast`, `sql`, `list`, `pg-stop`, and a self-documenting `make help`
- CI runs the harness against a `postgres:16` service container on every push and pull request

### Changed
- Expression AST collapsed onto generic nodes — `Eq`, `Neq`, `Lt`, `Lte`, `Gt`, `Gte`, `Like`, `ILike`, `In` and `NotIn` are replaced by `BinOp String Expr Expr`; `Not` by `Unary`; `IsNull` and `IsNotNull` by `Postfix`. The `Sqld.Expr` surface is unchanged — `.==`, `like`, `isNull` and friends now build the generic nodes — so builder code needs no edits; only code pattern-matching on `Sqld.Core.Expr` directly is affected
- `format` now resolves operator precedence, bracketing sub-expressions only where the meaning depends on it. `raw` is exempt: its contents are opaque, so its bracketing remains the caller's responsibility
- `select` is now additive — calling it multiple times appends to the select list rather than replacing it
- Table aliases now render with explicit `AS` keyword (`FROM "users" AS "u"` instead of `FROM "users" "u"`)
- Implicit `SELECT *` removed — use `select [star]` explicitly
