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
- Derived tables — `fromSub :: Query -> String -> Query -> Query` for `FROM (SELECT …) AS alias`, and `derived :: Query -> String -> Relation` for joining against one. The alias is a plain `String`, not a `Maybe`, because PostgreSQL rejects a `FROM` subquery without one. Parameters are numbered in emitted-SQL order, so a derived table's bindings precede the outer query's
- `rightJoin`, `rightJoinAs`, `fullJoin`, `fullJoinAs`, `innerJoinAs` — `RightJoin` and `FullJoin` existed in the AST and formatter but had no builders
- `joinOn :: JoinType -> Relation -> Expr -> Query -> Query` — the general join form, and the way to join a derived table
- `fromRel :: Relation -> Query -> Query` — the general FROM form
- `starFrom :: String -> SelectExpr` — `"t".*`, previously documented in the README but never implemented
- `tcols :: String -> Array String -> Array SelectExpr` — columns sharing one table qualifier
- `select' :: Array SelectExpr -> Query` — starts a query from its select list, so the common case need not name `emptyQuery`. `select` stays additive, so later calls append. Use `emptyQuery` directly for reusable `Query -> Query` fragments, or a query with no select list of its own
- `exprs :: Array Expr -> Array SelectExpr` — the plural of `expr`, for a run of bare expressions. Mixed select lists concatenate: `cols ["department"] <> [as countStar "headcount"]`. `SelectExpr` stays distinct from `Expr` on purpose — it is what keeps `as` and `star` from type-checking in a `WHERE` clause
- `notLike` / `notILike`
- Function wrappers over `app`: `count`, `countStar`, `sum_`, `avg`, `min_`, `max_`, `coalesce`, `lower`, `upper`
- `EXAMPLES.md` — a worked cookbook of 19 examples covering filtering, joins, aggregation, subqueries, derived tables, composition and the `raw` escape hatch. Generated from `Example.Cookbook` by `scripts/build-examples.mjs`, which slices the PureScript out of the source file rather than from a copy, so the code shown is the code that ran. Every example is also a corpus entry, so PostgreSQL validates it; CI fails if the file is stale or the examples drift from the source
- `Example.Cookbook` — the examples as real `Query` values; `spago run` prints each with its SQL
- PostgreSQL validation harness — every query in the corpus is replayed against a real server via `PREPARE`. Because `PREPARE` runs full parse *analysis* rather than a syntax check alone, unknown columns, invalid `GROUP BY`, and operator type mismatches fail alongside malformed SQL. Both formatter outputs are validated: the parameterised form from `format` and the debug form from `formatInline`
- `Test.Sqld.Corpus` — one canonical corpus of queries, consumed by both the golden tests and the PostgreSQL harness, with each entry tagged by the AST constructors it exercises
- Coverage ratchet — `Test.Sqld.CorpusSpec` fails if any `Sqld.Core` constructor has no corpus entry, so a new feature cannot ship without SQL that PostgreSQL has accepted
- `test/fixtures/schema.sql` — fixture tables the corpus references
- `scripts/validate-sql.mjs` — the validator, supporting `--only <pattern>`, `--sql <query>` for ad-hoc probes, and `--list`
- `scripts/pg-validate-local.sh` — local runs against a throwaway Docker PostgreSQL container
- `Makefile` — `make validate`, `validate-fast`, `sql`, `list`, `pg-stop`, and a self-documenting `make help`
- CI runs the harness against a `postgres:16` service container on every push and pull request

### Changed
- `col` splits on a dot, so `col "u.id"` is `tcol "u" "id"` and renders `"u"."id"`. Previously the whole string was quoted as a single identifier, which produced SQL PostgreSQL rejects — two golden tests were asserting exactly that, green, because they were never in the validation corpus. `tcol` and `colRef` never split, for identifiers that genuinely contain a dot
- `Relation` is now a sum type (`Table String (Maybe String)` / `Derived Query String`) rather than a record, so `FROM` and join targets can hold a subquery. `rel` and `relAs` are unchanged; code constructing the record literal directly must switch to them
- `formatRelation` now threads bindings, since a derived table carries parameters of its own
- Expression AST collapsed onto generic nodes — `Eq`, `Neq`, `Lt`, `Lte`, `Gt`, `Gte`, `Like`, `ILike`, `In` and `NotIn` are replaced by `BinOp String Expr Expr`; `Not` by `Unary`; `IsNull` and `IsNotNull` by `Postfix`. The `Sqld.Expr` surface is unchanged — `.==`, `like`, `isNull` and friends now build the generic nodes — so builder code needs no edits; only code pattern-matching on `Sqld.Core.Expr` directly is affected
- `format` now resolves operator precedence, bracketing sub-expressions only where the meaning depends on it. `raw` is exempt: its contents are opaque, so its bracketing remains the caller's responsibility
- `select` is now additive — calling it multiple times appends to the select list rather than replacing it
- Table aliases now render with explicit `AS` keyword (`FROM "users" AS "u"` instead of `FROM "users" "u"`)
- Implicit `SELECT *` removed — use `select [star]` explicitly
