# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-04-27

### Added
- SELECT query builder with composable `Query -> Query` helpers
- WHERE expressions as a tagged union ADT (`Expr`)
- JOIN support: `innerJoin`, `leftJoin`, `leftJoinAs`
- Logical combinators: `and_`, `or_`, `not_`, `isNull`, `isNotNull`
- Set operators: `in_`, `notIn`
- Range / pattern operators: `between_`, `like`
- Comparison infix operators: `.==`, `.!=`, `.<`, `.<=`, `.>`, `.>=`
- `groupBy` / `having` / `orderBy` / `limit` / `offset`
- `mergeQueries` for combining query fragments (HoneySQL-style merge)
- `raw` escape hatch for unsupported SQL fragments
- Pure `format` function — explicit state threading, no `Effect`
- PostgreSQL numbered params (`$1`, `$2`, …); no string interpolation
- All identifiers double-quoted via `quoteIdent` (PostgreSQL-safe)
