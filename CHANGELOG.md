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
- Common table expressions — `with_ :: String -> Query -> Query -> Query` for `WITH "name" AS (SELECT …)`, and `withRecursive` for a CTE that may refer to itself. `RECURSIVE` is a property of the whole `WITH` clause rather than of one CTE, so a single recursive entry makes the clause recursive and the others need no change. `withCte :: Cte -> Query -> Query` is the general form, taking a `Cte` built with `cte`, `cteColumns` (the optional output column list, `WITH "t" ("a", "b") AS (…)`) and `cteRecursive`. Multiple CTEs comma-separate within one `WITH`, and a later one may reference an earlier one. `Query` gains a `with` field, which `mergeQueries` concatenates. Parameters are numbered in emitted-SQL order, so a CTE's bindings precede the outer query's. The two halves of a recursive CTE are joined with `unionAll`; `MATERIALIZED` / `NOT MATERIALIZED` hints are not supported
- Set operations — `union`, `unionAll`, `intersect`, `intersectAll`, `except` and `exceptAll`, all `:: Query -> Query -> Query`, with `combine :: SetOp -> Boolean -> Query -> Query -> Query` as the general form. The query being piped from is the left operand, so a chain reads in the order it is emitted. Both operands are bracketed, so a chain of mixed operators is unambiguous whatever PostgreSQL's own precedence between `UNION` and `INTERSECT` is, and each operand keeps its own `ORDER BY` and `LIMIT`. An `orderBy`, `limit`, `offset` or `with_` applied after the operation falls outside the brackets and so applies to the combined result, which is what SQL means by them; parameters are numbered in emitted-SQL order, left to right across both operands and after any CTE's. A set operation is a `Query`, so it nests wherever one can — `fromSub`, `sub`, `inSub` and a CTE body all take one, which is what makes an idiomatic recursive CTE expressible
- `SetOperation` — two result sets and the operator combining them. A `newtype` for the same reason as `Cte`: it closes a cycle through `Query`. `Query` gains a `setOp` field, which `mergeQueries` treats as a scalar. When it is set the operands supply the rows, so that query's own select list, `FROM`, joins, `WHERE`, `GROUP BY` and `HAVING` have nothing to emit — the builders start one from `emptyQuery`, so they stay empty
- Window functions — `over :: Expr -> Window -> Expr` puts any expression over a window, `OVER (PARTITION BY … ORDER BY … <frame>)`, with `rowNumber`, `rank`, `denseRank`, `lag` and `lead` as the window-only functions and any aggregate usable over a window too. A window is built the way a query is: `partitionBy'` and `orderWindow'` start one as `select'` starts a query, and `partitionBy`, `orderWindow` and `withFrame` are plain `Window -> Window` functions that pipe on with `#`. `Window` is a record synonym (`partitionBy`, `orderBy`, `frame`) with `emptyWindow` as its base, so record update reaches the fields directly too; every field is optional and an empty window emits `OVER ()`. `orderWindow` carries that name rather than `orderBy` because `Sqld.Select` already exports one, and the two would collide in a module importing both. Frames come from `rows`, `range` and `groups`, with `frameBetween` and the one-bound `frameFrom` as the general forms, over the bounds `unboundedPreceding`, `preceding n`, `currentRow`, `following n` and `unboundedFollowing`. Frame offsets are emitted literally rather than as parameters, so a frame carries no bindings; a window's expressions do, numbered in emitted-SQL order. `OVER` binds tighter than any operator, so a window function is an atom the precedence printer never brackets. PostgreSQL allows one in `SELECT` and `ORDER BY` alone and rejects it elsewhere, which the harness confirms rather than the type system. Named windows (`WINDOW w AS (…)`) are not supported
- `Cte` — a named intermediate result set. A `newtype` around its record rather than a record synonym, because a CTE holds a `Query` and a `Query` holds CTEs
- `rightJoin`, `rightJoinAs`, `fullJoin`, `fullJoinAs`, `innerJoinAs` — `RightJoin` and `FullJoin` existed in the AST and formatter but had no builders
- `joinOn :: JoinType -> Relation -> Expr -> Query -> Query` — the general join form, and the way to join a derived table
- `fromRel :: Relation -> Query -> Query` — the general FROM form
- `starFrom :: String -> SelectExpr` — `"t".*`, previously documented in the README but never implemented
- `tcols :: String -> Array String -> Array SelectExpr` — columns sharing one table qualifier
- `select' :: Array SelectExpr -> Query` — starts a query from its select list, so the common case need not name `emptyQuery`. `select` stays additive, so later calls append. Use `emptyQuery` directly for reusable `Query -> Query` fragments, or a query with no select list of its own
- `exprs :: Array Expr -> Array SelectExpr` — the plural of `expr`, for a run of bare expressions. Mixed select lists concatenate: `cols ["department"] <> [as countStar "headcount"]`. `SelectExpr` stays distinct from `Expr` on purpose — it is what keeps `as` and `star` from type-checking in a `WHERE` clause
- `notLike` / `notILike`
- Function wrappers over `app`: `count`, `countStar`, `sum_`, `avg`, `min_`, `max_`, `coalesce`, `lower`, `upper`
- `EXAMPLES.md` — a worked cookbook of 23 examples covering filtering, joins, aggregation, window functions, subqueries, derived tables, set operations, common table expressions, composition and the `raw` escape hatch. Generated from `Example.Cookbook` by `scripts/build-examples.mjs`, which slices the PureScript out of the source file rather than from a copy, so the code shown is the code that ran. Every example is also a corpus entry, so PostgreSQL validates it; CI fails if the file is stale or the examples drift from the source
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

### Fixed
- `formatPretty` breaks nested subqueries across lines instead of collapsing them onto one. A scalar subquery, `IN (SELECT …)`, `EXISTS (…)` or derived table now gets an indented block of its own, one level per level of nesting — which is the case pretty-printing exists for. Layout is threaded through the formatter as a `Layout` (`Inline` or `Pretty depth`) rather than a bare separator string, so `formatExpr` and `formatRelation` take an extra argument; `format` and `formatInline` are byte-for-byte unchanged, and only whitespace differs in what `formatPretty` emits. Indent width is fixed at two spaces by design
- `in_` with an empty candidate list folds to `FALSE`, and `notIn` to `TRUE`, instead of emitting `IN ()` / `NOT IN ()` — a syntax error PostgreSQL rejects at execution time rather than at the call site. An empty list arises naturally when a filter is driven by user input. The fold happens in `Sqld.Expr`, so `Row []` stays representable for anyone building the AST directly, and the constant is a bare keyword, so it needs no bracketing under `AND` / `OR` / `NOT`. Non-empty lists and `inSub` / `notInSub` are unchanged
