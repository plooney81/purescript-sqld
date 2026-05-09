# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-05-08

### Added
- `Sqld.Expr` module — expression constructors, literals, comparison operators, and logical combinators
- `Sqld.Select` module — SELECT query builders and select-list helpers
- `cols :: Array String -> Array SelectExpr` — convenience helper for selecting a list of plain column names
- `expr :: Expr -> SelectExpr` — wraps an `Expr` into a `SelectExpr` for use in a select list
- SELECT query builder with composable `Query -> Query` helpers
- WHERE expressions as a tagged union ADT (`Expr`)
- JOIN support: `innerJoin`, `leftJoin`, `leftJoinAs`
- Logical combinators: `and`, `or`, `not`, `isNull`, `isNotNull`
- Set operators: `in_`, `notIn`
- Range / pattern operators: `between`, `like`
- Comparison infix operators: `.==`, `.!=`, `.<`, `.<=`, `.>`, `.>=`
- `groupBy` / `having` / `orderBy` / `limit` / `offset`
- `mergeQueries` for combining query fragments
- `raw` escape hatch for unsupported SQL fragments
- Pure `format` function — explicit state threading, no `Effect`
- `formatInline` — substitutes all values directly into the SQL string (for debugging and logging only)
- PostgreSQL numbered params (`$1`, `$2`, …); no string interpolation
- All identifiers double-quoted via `quoteIdent` (PostgreSQL-safe)
