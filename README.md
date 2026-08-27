# purescript-sqld

[![CI](https://github.com/plooney81/purescript-sqld/actions/workflows/ci.yml/badge.svg)](https://github.com/plooney81/purescript-sqld/actions/workflows/ci.yml)

A PostgreSQL SQL query builder for PureScript, inspired by [HoneySQL](https://github.com/seancorfield/honeysql). Build queries as plain data, compose them with functions, format them to a parameterised SQL string.

## Design

- **PostgreSQL only** — ships fast, does one thing well
- **Pure formatting** — `format` has no `Effect`; param state is explicitly threaded
- **No string interpolation** — literals become numbered params (`$1`, `$2`, …) automatically
- **Composable builders** — every helper is `Query -> Query`; chain with `#` or `>>>`
- **Explicit select list** — no implicit `SELECT *`; use `select [star]` when you want it
- **`raw` escape hatch** — opt out of quoting for unsupported SQL fragments

## Installation

Once published to the PureScript registry:

```
spago install sqld
```

Until then, add a path dependency in your `spago.yaml`:

```yaml
workspace:
  extraPackages:
    sqld:
      path: ../purescript-sqld
```

## Quick start

```purescript
import Sqld.Expr
import Sqld.Format (format)
import Sqld.Select

-- SELECT "id", "name" FROM "users" WHERE "id" = $1
query = format $ select' (cols ["id", "name"])
  # from "users"
  # where_ (col "id" .== int 42)

-- { sql: "SELECT \"id\", \"name\" FROM \"users\" WHERE \"id\" = $1"
-- , params: [LitInt 42] }
```

Pass `sql` and `params` directly to your PostgreSQL driver (e.g. `node-postgres`):

```javascript
await pool.query(query.sql, query.params);
```

## Examples

**[EXAMPLES.md](EXAMPLES.md)** is a worked cookbook — filtering, joins,
aggregation, grouping sets, window functions, `DISTINCT ON`, subqueries,
derived and lateral tables, common table expressions, composing fragments from
optional parameters, and when to reach for `raw`.

It is generated from [`src/Example/Cookbook.purs`](src/Example/Cookbook.purs),
and every example is replayed against a live PostgreSQL server by the
validation harness. An example that no longer compiles, or that PostgreSQL
would reject, fails CI. Run them yourself with `spago run`.

## Modules

| Module | Contents |
|---|---|
| `Sqld.Core` | Core types: `Query`, `Expr`, `Literal`, `SelectExpr`, `Distinct`, `GroupingElement`, `Cte`, `SetOperation`, `Window`, `Locking`, `JoinType`, `JoinCondition`, `emptyQuery`, `emptyWindow`, `Keyword` |
| `Sqld.Expr` | Expression helpers over the generic AST nodes — operators, literals, functions, subqueries |
| `Sqld.Select` | SELECT query builders and select-list helpers |
| `Sqld.Format` | `format`, `formatInline`, `formatPretty` |

## API

### Building a query

Start with `select'` and pipe through helpers from `Sqld.Select`. Reach for
`emptyQuery` when a query has no select list of its own — a reusable
`Query -> Query` fragment, or the right-hand side of `mergeQueries`:

| Function | Description |
|---|---|
| `select :: Array SelectExpr -> Query -> Query` | Append to the SELECT list |
| `select' :: Array SelectExpr -> Query` | Start a query from its select list, without naming `emptyQuery` |
| `distinct :: Query -> Query` | SELECT DISTINCT |
| `distinctOn :: Array Expr -> Query -> Query` | `SELECT DISTINCT ON (…)` — first row per group |
| `from :: String -> Query -> Query` | FROM table |
| `fromAs :: String -> String -> Query -> Query` | FROM with alias |
| `fromSub :: Query -> String -> Query -> Query` | FROM a derived table (subquery + alias) |
| `fromLateral :: Query -> String -> Query -> Query` | `FROM LATERAL (SELECT …) AS alias` |
| `where_ :: Expr -> Query -> Query` | Add WHERE condition (ANDs with any existing) |
| `with_ :: String -> Query -> Query -> Query` | Add a named CTE (`WITH "name" AS (…)`) |
| `withRecursive :: String -> Query -> Query -> Query` | Add a CTE that may refer to itself |
| `withCte :: Cte -> Query -> Query` | General form; use it to name a CTE's output columns |
| `innerJoin` / `leftJoin` / `rightJoin` / `fullJoin` | `:: String -> Expr -> Query -> Query` |
| `innerJoinAs` / `leftJoinAs` / `rightJoinAs` / `fullJoinAs` | `:: String -> String -> Expr -> Query -> Query` |
| `joinOn :: JoinType -> Relation -> Expr -> Query -> Query` | General `ON` form; use it to join a derived table |
| `crossJoin :: String -> Query -> Query` | `CROSS JOIN` — every row against every row, no condition |
| `joinUsing :: JoinType -> String -> Array String -> Query -> Query` | `JOIN … USING ("a", "b")` — match on shared column names |
| `naturalJoin :: JoinType -> String -> Query -> Query` | `NATURAL <kind> JOIN` — match on every shared column |
| `joinRel :: Relation -> JoinCondition -> Query -> Query` | Most general form; any relation, any join condition |
| `joinLateral :: Query -> String -> Query -> Query` | `JOIN LATERAL (…) AS alias ON (TRUE)` — a per-row subquery |
| `leftJoinLateral :: Query -> String -> Query -> Query` | As above, keeping left rows whose subquery found nothing |
| `lateral :: Query -> String -> Relation` | The `LATERAL` relation on its own, for `joinOn` or `joinRel` |
| `union` / `unionAll` | `:: Query -> Query -> Query` — the rows of both, duplicates removed / kept |
| `intersect` / `intersectAll` | `:: Query -> Query -> Query` — the rows in both |
| `except` / `exceptAll` | `:: Query -> Query -> Query` — the left query's rows, minus the right's |
| `combine :: SetOp -> Boolean -> Query -> Query -> Query` | General form; any set operator, with or without `ALL` |
| `groupBy :: Array Expr -> Query -> Query` | GROUP BY (appends, like `select`) |
| `groupBySets :: Array (Array Expr) -> Query -> Query` | `GROUP BY GROUPING SETS ((…), …)` — one grouping per set named |
| `groupByCube :: Array Expr -> Query -> Query` | `GROUP BY CUBE (…)` — every combination of the expressions |
| `groupByRollup :: Array Expr -> Query -> Query` | `GROUP BY ROLLUP (…)` — every prefix: subtotals down one hierarchy |
| `groupByElements :: Array GroupingElement -> Query -> Query` | General form; appends any grouping elements |
| `having :: Expr -> Query -> Query` | HAVING |
| `orderBy :: Array OrderExpr -> Query -> Query` | ORDER BY |
| `limit :: Int -> Query -> Query` | `LIMIT n` (parameterised) |
| `limitExpr :: Expr -> Query -> Query` | `LIMIT` with an arbitrary expression |
| `limitAll :: Query -> Query` | `LIMIT ALL` |
| `offset :: Int -> Query -> Query` | `OFFSET n` (parameterised) |
| `offsetExpr :: Expr -> Query -> Query` | `OFFSET` with an arbitrary expression |
| `forUpdate` / `forNoKeyUpdate` / `forShare` / `forKeyShare` | `:: Query -> Query` — add a `FOR …` row-locking clause |
| `lockRows :: LockStrength -> Query -> Query` | General form; appends a locking clause of any strength |
| `lockOf :: Array String -> Query -> Query` | `OF "a", "b"` — restrict the clause to those `FROM` items |
| `noWait :: Query -> Query` | `NOWAIT` — fail rather than wait for a locked row |
| `skipLocked :: Query -> Query` | `SKIP LOCKED` — leave locked rows out of the result |
| `mergeQueries :: Query -> Query -> Query` | Merge two queries; right side wins for scalars |

### SELECT list helpers

From `Sqld.Select`:

| Constructor | Example | SQL |
|---|---|---|
| `star` | `select [star]` | `SELECT *` |
| `cols :: Array String -> Array SelectExpr` | `cols ["u.id", "name"]` | `"u"."id", "name"` |
| `tcols :: String -> Array String -> Array SelectExpr` | `tcols "u" ["id", "name"]` | `"u"."id", "u"."name"` |
| `expr :: Expr -> SelectExpr` | `expr (avg (col "age"))` | `AVG("age")` |
| `exprs :: Array Expr -> Array SelectExpr` | `exprs [col "id", avg (col "age")]` | `"id", AVG("age")` |
| `as :: Expr -> String -> SelectExpr` | `as (raw "COUNT(*)") "n"` | `COUNT(*) AS "n"` |
| `colAs :: String -> String -> SelectExpr` | `colAs "created_at" "ts"` | `"created_at" AS "ts"` |
| `tcolAs :: String -> String -> String -> SelectExpr` | `tcolAs "u" "created_at" "ts"` | `"u"."created_at" AS "ts"` |
| `starFrom :: String -> SelectExpr` | `starFrom "u"` | `"u".*` |

### Mixed select lists

A PureScript array is homogeneous, so a select list combining plain columns
with aliased expressions is built by concatenating:

```purescript
select (cols ["department"] <> [as countStar "headcount"])
-- SELECT "department", COUNT(*) AS "headcount"
```

`select` is also additive, so the list can be built up in stages — useful when
a fragment contributes columns of its own:

```purescript
select' (cols ["department"])
  # select [as countStar "headcount"]
```

Keeping `SelectExpr` distinct from `Expr` is deliberate: it is what stops
`as` and `star` from type-checking in a `WHERE` clause, where they are not
valid SQL.

### DISTINCT

`distinct` drops duplicate rows. `distinctOn` is PostgreSQL's own, and is the
shortest way to say "one row per group" — it keeps the first row of each group
of the given expressions:

```purescript
select' (cols ["department"]) # distinct # from "users"
-- SELECT DISTINCT "department" FROM "users"

select' (cols ["user_id", "total"])
  # distinctOn [col "user_id"]
  # from "orders"
  # orderBy [asc (col "user_id"), desc (col "placed_at")]
-- SELECT DISTINCT ON ("user_id") "user_id", "total" FROM "orders"
--   ORDER BY "user_id" ASC, "placed_at" DESC
```

Which row is "first" is whatever the `ORDER BY` says, and PostgreSQL requires
its leading expressions to match the ones given to `distinctOn` — a rule it
enforces itself (`42P10`) rather than one the type expresses. For the same
reason, avoid an expression carrying a parameter in both places: the two
occurrences get different parameter numbers, and PostgreSQL matches them as
written.

The two builders share one field, because a `SELECT` is one or the other and
never both — whichever is applied last wins, and `mergeQueries` takes the
right-hand side's. `distinctOn []` falls back to plain `DISTINCT`, since
`DISTINCT ON ()` is not something PostgreSQL parses. `ALL` has no explicit
spelling: it is the default, and adds nothing.

The `DISTINCT ON` expressions come before the select list in the emitted SQL,
so their parameters are numbered first.

### Expressions

From `Sqld.Expr`:

| Constructor | Example | SQL |
|---|---|---|
| `col :: String -> Expr` | `col "name"` | `"name"` |
| `col` with a dot | `col "u.id"` | `"u"."id"` |
| `tcol :: String -> String -> Expr` | `tcol "u" "id"` | `"u"."id"` (never splits on dots) |
| `int / str / num / bool` | `int 42` | `$1` |
| `null` | `null` | `$1` (NULL param) |
| `raw :: String -> Expr` | `raw "NOW()"` | `NOW()` |
| `.== .!= .< .<= .> .>=` | `col "age" .> int 18` | `"age" > $1` |
| `and :: Array Expr -> Expr` | `and [e1, e2]` | `(e1 AND e2)` |
| `or :: Array Expr -> Expr` | `or [e1, e2]` | `(e1 OR e2)` |
| `not :: Expr -> Expr` | `not e` | `NOT e` |
| `isNull / isNotNull` | `isNull (col "deleted_at")` | `"deleted_at" IS NULL` |
| `in_ :: Expr -> Array Expr -> Expr` | `in_ (col "id") [int 1, int 2]` | `"id" IN ($1, $2)` |
| `in_` with an empty list | `in_ (col "id") []` | `FALSE` |
| `notIn` | `notIn (col "s") [str "x"]` | `"s" NOT IN ($1)` |
| `notIn` with an empty list | `notIn (col "s") []` | `TRUE` |
| `between` | `between (col "n") (int 1) (int 10)` | `"n" BETWEEN $1 AND $2` |
| `like / ilike` | `like (col "email") "%@acme.com"` | `"email" LIKE $1` |
| `notLike / notILike` | `notLike (col "email") "%@spam.com"` | `"email" NOT LIKE $1` |

### Generic nodes

The AST keeps only a handful of expression constructors. `App`, `BinOp`, `Cast`
and `Sub` cover most of PostgreSQL's expression grammar between them, so a
feature usually needs no new AST node — and anything without a named helper is
still reachable without falling back to `raw`:

| Constructor | Example | SQL |
|---|---|---|
| `app :: String -> Array Expr -> Expr` | `app "LOWER" [col "email"]` | `LOWER("email")` |
| `binOp :: String -> Expr -> Expr -> Expr` | `binOp "@>" (col "tags") (raw "ARRAY['a']")` | `"tags" @> ARRAY['a']` |
| `unary :: String -> Expr -> Expr` | `unary "-" (col "n")` | `- "n"` |
| `postfix :: String -> Expr -> Expr` | `postfix "IS TRUE" (col "ok")` | `"ok" IS TRUE` |
| `cast :: Expr -> String -> Expr` | `cast (col "id") "text"` | `"id"::text` |
| `row :: Array Expr -> Expr` | `row [int 1, int 2]` | `(1, 2)` |
| `sub :: Query -> Expr` | `sub totals` | `(SELECT …)` |
| `exists / notExists` | `exists orders` | `EXISTS (SELECT …)` |
| `inSub / notInSub` | `inSub (col "id") orders` | `"id" IN (SELECT …)` |

Common aggregates and functions are provided as one-line wrappers over `app`:
`count`, `countStar`, `sum_`, `avg`, `min_`, `max_`, `coalesce`, `lower`,
`upper`.

### Grouping sets

`groupBy` gives one level of detail. `GROUPING SETS`, `CUBE` and `ROLLUP` give
several from one pass over the table — the groups, their subtotals, and the
grand total, as extra rows of the same result:

```purescript
select' (cols ["department", "active"] <> [as countStar "headcount"])
  # from "users"
  # groupByRollup [col "department", col "active"]
-- GROUP BY ROLLUP ("department", "active")
--   -- groups by ("department", "active"), then ("department"), then ()

select' (cols ["department"] <> [as countStar "headcount"])
  # from "users"
  # groupBySets [[col "department"], []]
-- GROUP BY GROUPING SETS (("department"), ())
```

`ROLLUP (a, b)` groups by every prefix — `(a, b)`, `(a)`, `()` — which is the
subtotals down one hierarchy: a country's cities, never a city across
countries. `CUBE (a, b)` gives every combination instead, adding `(b)`.
`groupBySets` names the groupings one by one, and `[]` among them is the empty
grouping set, `()`: one group holding every row, which is the grand total.

The clause is a list of elements rather than a flat list of expressions, so the
plain and multi-grouping forms sit side by side as they do in SQL. All four
builders append, so a later call adds to the clause rather than replacing it —
the same thing `mergeQueries` has always done with `GROUP BY`:

```purescript
groupBy [col "department"] >>> groupByRollup [col "active"]
-- GROUP BY "department", ROLLUP ("active")
```

A subtotal row carries `NULL` in the columns it rolled up, which is the same
`NULL` a row missing that value carries. `GROUPING(…)` tells them apart — 1
where the column was rolled up, 0 where it was grouped by — and needs no
builder of its own, since `app "GROUPING" [col "department"]` reaches it.

`groupBySets []`, `groupByCube []` and `groupByRollup []` add nothing:
`CUBE ()` is not something PostgreSQL parses, and an empty list arises
naturally when the grouping is driven by user input. `groupBySets [[]]` is the
grand total, and is a different thing.

### Aggregate FILTER

`filterWhere` restricts one aggregate to the rows its predicate keeps, while
the aggregates beside it still see the whole group:

```purescript
select' (cols ["department"] <>
          [ as (countStar `filterWhere` (col "active" .== bool true)) "active_count"
          , as countStar "total"
          ])
  # from "users"
  # groupBy [col "department"]
-- SELECT "department",
--        COUNT(*) FILTER (WHERE "active" = $1) AS "active_count",
--        COUNT(*) AS "total"
-- FROM "users" GROUP BY "department"
```

| Constructor | Example | SQL |
|---|---|---|
| `filterWhere :: Expr -> Expr -> Expr` | ``countStar `filterWhere` (col "active")`` | `COUNT(*) FILTER (WHERE "active")` |

That is the conditional aggregate `SUM(CASE WHEN … THEN 1 ELSE 0 END)` spells
the long way round: a `WHERE` clause would narrow every column of the query at
once, where this narrows one and leaves its neighbours the whole group to
count.

`FILTER` binds to the aggregate call, so it is an atom the precedence printer
never brackets — ``binOp "-" countStar (countStar `filterWhere` p)`` emits
`COUNT(*) - COUNT(*) FILTER (WHERE …)` — and it precedes `OVER` when the two
meet:

```purescript
(sum_ (col "total") `filterWhere` (col "status" .== str "paid"))
  `over` partitionBy' [col "user_id"]
-- SUM("total") FILTER (WHERE "status" = $1) OVER (PARTITION BY "user_id")
```

That is the order PostgreSQL's grammar fixes: the modifier belongs to the call,
the window to what is done with its result. Writing the two the other way round
builds and the database rejects it, as it does a `FILTER` on a scalar function
— `App` covers every function in `pg_proc` and which of them aggregate is
PostgreSQL's to say, so neither is a mistake the type can catch. Parameters in
the predicate are numbered where the predicate is emitted, which in a select
list is ahead of the `WHERE` clause's. `WITHIN GROUP`, the other aggregate
modifier, is not supported.

### Window functions

`over` evaluates an aggregate — or a window-only function such as `rowNumber`,
`rank` or `lag` — across rows related to the current one, without collapsing
them the way `groupBy` does:

```purescript
rowNumber `over`
  ( partitionBy' [col "department"]
      # orderWindow [desc (col "age")]
  )
-- ROW_NUMBER() OVER (PARTITION BY "department" ORDER BY "age" DESC)
```

A window is built the way a query is. `partitionBy'` and `orderWindow'` start
one, as `select'` starts a query, and `partitionBy`, `orderWindow` and
`withFrame` pipe onto it with `#`. Every field is optional, and
``e `over` emptyWindow`` emits `OVER ()`, which is valid SQL.

Windows are values, so name one that several columns share and add to it:

```purescript
byUser :: Window
byUser = partitionBy' [col "user_id"] # orderWindow [asc (col "placed_at")]

sum_ (col "total") `over` (byUser # withFrame (rows unboundedPreceding currentRow))
-- SUM("total") OVER (PARTITION BY "user_id" ORDER BY "placed_at" ASC
--                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
```

| Constructor | Example | SQL |
|---|---|---|
| `over :: Expr -> Window -> Expr` | ``countStar `over` emptyWindow`` | `COUNT(*) OVER ()` |
| `partitionBy' :: Array Expr -> Window` | `partitionBy' [col "department"]` | `PARTITION BY "department"` |
| `orderWindow' :: Array OrderExpr -> Window` | `orderWindow' [desc (col "age")]` | `ORDER BY "age" DESC` |
| `partitionBy` / `orderWindow` | `byUser # orderWindow [asc (col "placed_at")]` | adds to an existing window |
| `withFrame :: Frame -> Window -> Window` | `withFrame (rows unboundedPreceding currentRow)` | `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` |
| `rowNumber` / `rank` / `denseRank` | `rank` | `RANK()` |
| `lag` / `lead :: Expr -> Int -> Expr` | `lag (col "total") 1` | `LAG("total", $1)` |
| `rows` / `range` / `groups` | `rows (preceding 3) currentRow` | `ROWS BETWEEN 3 PRECEDING AND CURRENT ROW` |
| `frameBetween :: FrameMode -> FrameBound -> FrameBound -> Frame` | `frameBetween Range currentRow unboundedFollowing` | `RANGE BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING` |
| `frameFrom :: FrameMode -> FrameBound -> Frame` | `frameFrom Rows unboundedPreceding` | `ROWS UNBOUNDED PRECEDING` |
| `unboundedPreceding` / `currentRow` / `unboundedFollowing` | `currentRow` | `CURRENT ROW` |
| `preceding` / `following :: Int -> FrameBound` | `preceding 3` | `3 PRECEDING` |

`orderWindow` is the one name that does not match its SQL keyword: `orderBy`
already belongs to `Sqld.Select`, and a second one here would collide in any
module importing both. There is no `withFrame'`, because a frame over unordered
rows frames nothing in particular — and in `RANGE` or `GROUPS` mode PostgreSQL
rejects one outright. `Window` is an ordinary record (`partitionBy`, `orderBy`,
`frame`), so record update reaches the fields directly if you prefer it; the
builders are setters over exactly those three.

Frame offsets are emitted literally rather than as parameters, so a frame
carries no bindings; a window's `PARTITION BY` and `ORDER BY` expressions do,
and they are numbered where they appear, which in a select list is ahead of the
`WHERE` clause's.

`OVER` binds tighter than any operator, so a window function is an atom that
never needs bracketing. PostgreSQL allows one in `SELECT` and `ORDER BY` only,
and rejects it in `WHERE`, `GROUP BY` and `HAVING`; the type does not express
that, so it is the database that reports the mistake. Named windows
(`WINDOW w AS (…)`) are not supported.

### Joins

A join is a relation and a condition, and SQL ties the two together: `ON` and
`USING` take a join kind, `NATURAL` takes a kind but no expression, and `CROSS`
takes neither. `JoinCondition` pairs them for that reason, so the combinations
PostgreSQL has no syntax for are ones the builders cannot produce:

```purescript
select' [star] # from "orders" # joinUsing InnerJoin "profiles" ["user_id"]
-- SELECT * FROM "orders" JOIN "profiles" USING ("user_id")

select' [star] # from "users" # naturalJoin LeftJoin "departments"
-- SELECT * FROM "users" NATURAL LEFT JOIN "departments"

select' [star] # from "users" # crossJoin "departments"
-- SELECT * FROM "users" CROSS JOIN "departments"
```

`USING` names identifiers rather than values, so its columns are quoted rather
than bound as parameters; it also collapses each matched pair into a single
output column, which `ON` does not. `NATURAL` leaves the column list to the
schema — every name the two relations share — so a column added to either table
silently changes what the query means.

`crossJoin`, `joinUsing` and `naturalJoin` take a table name. For an aliased or
derived join target, `joinRel` takes any relation with any condition:

```purescript
select' [star] # from "users" # joinRel (relAs "departments" "d") Cross
-- SELECT * FROM "users" CROSS JOIN "departments" AS "d"
```

`joinUsing` with an empty column list falls back to `ON (TRUE)`: `USING ()` is
not something PostgreSQL parses, and no columns to match on is what `and []`
already means.

### Derived tables

A subquery in `FROM`. The alias is a plain `String` rather than a `Maybe`,
because PostgreSQL rejects a `FROM` subquery without one:

```purescript
recent = select' [star]
  # from "orders"
  # where_ (col "status" .== str "paid")

select' [starFrom "recent"]
  # fromSub recent "recent"
  # where_ (col "recent.total" .> int 100)
-- SELECT "recent".* FROM (SELECT * FROM "orders" WHERE "status" = $1) AS "recent"
--   WHERE "recent"."total" > $2
```

Parameters are numbered in the order they appear in the emitted SQL, so a
derived table's bindings come before the outer query's. Use `joinOn` with
`derived` to join against one:

```purescript
select' [star]
  # fromAs "users" "u"
  # joinOn InnerJoin (derived totals "t") (col "u.id" .== col "t.user_id")
```

### Lateral joins

A derived table is evaluated on its own, so it cannot reference the relations
beside it. `LATERAL` lifts that restriction, and with it comes the per-row
shape: the three most recent orders of *each* user, in one join rather than a
correlated subquery per column.

```purescript
select' (cols ["u.name", "recent.total"])
  # fromAs "users" "u"
  # joinLateral
      ( select' (cols ["total"])
          # from "orders"
          # where_ (col "orders.user_id" .== col "u.id")
          # orderBy [desc (col "placed_at")]
          # limit 3
      )
      "recent"
-- SELECT "u"."name", "recent"."total" FROM "users" AS "u"
--   JOIN LATERAL (SELECT "total" FROM "orders" WHERE "orders"."user_id" = "u"."id"
--     ORDER BY "placed_at" DESC LIMIT 3) AS "recent" ON (TRUE)
```

The correlation inside the subquery is the whole of the matching, so there is
nothing left for a condition to say and `joinLateral` joins `ON (TRUE)`.
`leftJoinLateral` is the outer form, and the difference is what happens when
the subquery finds nothing: the inner one drops the row it was pairing with,
the outer keeps it with nulls — users who have never ordered survive the join
above only under `leftJoinLateral`.

Those two are the whole of it, which is why neither takes a `JoinType`.
PostgreSQL rejects a lateral reference from the right operand of a `RIGHT` or
`FULL` join (`42P10`), so a join kind here would be two spellings that work and
two that never run.

For the rest, `lateral` gives the relation on its own: `joinOn` for the rarer
lateral join that does carry a condition, `joinRel … Cross` for the
`CROSS JOIN LATERAL` spelling, which is the same join `joinLateral` gives.

Which relations a lateral one may reference are those to its left, meaning the
order the joins were added in. PostgreSQL rejects a reference to any other, and
does so itself rather than the types ruling it out. `fromLateral` puts one
first in `FROM`, where there is nothing to its left to reference; parameters are
numbered as ever in emitted-SQL order, so a lateral relation's bindings come
before its own `ON` clause's, and both before the outer query's.

### Set operations

The query you pipe from is the left operand, so a chain reads in the order it
is emitted:

```purescript
select' (cols ["id"]) # from "users"
  # union (select' (cols ["user_id"]) # from "orders")
-- (SELECT "id" FROM "users") UNION (SELECT "user_id" FROM "orders")
```

Both operands are bracketed. That makes a chain of mixed operators mean what it
reads like, whatever PostgreSQL's own precedence between `UNION` and
`INTERSECT` happens to be, and it leaves each operand its own `ORDER BY` and
`LIMIT`:

```purescript
select' (cols ["id"]) # from "users" # orderBy [asc (col "id")] # limit 5
  # unionAll (select' (cols ["user_id"]) # from "orders" # limit 3)
-- (SELECT "id" FROM "users" ORDER BY "id" ASC LIMIT 5)
--   UNION ALL (SELECT "user_id" FROM "orders" LIMIT 3)
```

An `orderBy`, `limit` or `offset` applied *after* the operation falls outside
the brackets, so it applies to the combined result — as it does in SQL. So does
a `with_`, whose parameters are numbered ahead of both operands'; parameters
within the operands are numbered left to right.

A set operation is a query like any other, so it nests wherever one can:
`fromSub`, `sub`, `inSub` and a CTE body all take one. `combine` is the general
form, and the only builders that add to a set operation are `with_`, `orderBy`,
`limit` and `offset` — the result carries no select list or `FROM` of its own.

### Common table expressions

`with_` names an intermediate result set. A later CTE may reference an earlier
one, and the outer query treats each as an ordinary relation:

```purescript
select' [starFrom "recent"]
  # with_ "recent" (select' [star] # from "orders" # where_ (col "status" .== str "paid"))
  # from "recent"
  # where_ (col "recent.total" .> int 100)
-- WITH "recent" AS (SELECT * FROM "orders" WHERE "status" = $1)
--   SELECT "recent".* FROM "recent" WHERE "recent"."total" > $2
```

A `WITH` clause precedes every other clause in the emitted SQL, so a CTE's
parameters are numbered before the outer query's.

`withRecursive` lets a CTE refer to itself. `RECURSIVE` is a property of the
whole clause in SQL rather than of one CTE, so a single recursive entry makes
the clause recursive and the others need no change. Use `withCte` with
`cteColumns` to name a CTE's output columns:

```purescript
select' [star]
  # withCte (cte "counting" body # cteColumns ["n"] # cteRecursive)
  # from "counting"
-- WITH RECURSIVE "counting" ("n") AS (…) SELECT * FROM "counting"
```

The two halves of a recursive CTE are joined by `unionAll` — an anchor term,
then a recursive term that reads from the CTE being defined; see
[Recursive CTEs](EXAMPLES.md#recursive-ctes) for a worked example.
`MATERIALIZED` / `NOT MATERIALIZED` hints are not supported.

### Operator precedence

`format` follows PostgreSQL's precedence table and brackets only where the
meaning depends on it:

```purescript
binOp "*" (binOp "+" (col "age") (int 1)) (int 2)
-- ("age" + 1) * 2      -- bracketed: + binds looser than *

binOp "+" (col "a") (binOp "*" (col "b") (int 2))
-- "a" + "b" * 2        -- not bracketed: precedence already agrees

binOp "-" (col "a") (binOp "-" (col "b") (col "c"))
-- "a" - ("b" - "c")    -- bracketed: operators are left-associative
```

`raw` is exempt — its contents are opaque, so its bracketing is yours to get
right.

### ORDER BY

```purescript
orderBy [asc (col "name"), desc (col "created_at")]
-- ORDER BY "name" ASC, "created_at" DESC
```

### Row locking

`forUpdate` locks the rows a query returns against any other transaction
reading them for update, modifying them or deleting them. `skipLocked` leaves
out the rows another transaction already holds, rather than waiting behind
them — which is what makes the two together a work queue:

```purescript
select' (cols ["id", "total"])
  # from "orders"
  # where_ (col "status" .== str "pending")
  # orderBy [asc (col "placed_at")]
  # limit 10
  # forUpdate
  # skipLocked
-- SELECT "id", "total" FROM "orders" WHERE "status" = $1
-- ORDER BY "placed_at" ASC LIMIT 10
-- FOR UPDATE SKIP LOCKED
```

Two workers running that at once claim disjoint batches, because the rows one
has locked are gone from the other's result rather than merely unlocked — so
`limit` bounds what a worker takes rather than what it sees.

| Builder | SQL | Locks out |
|---|---|---|
| `forUpdate` | `FOR UPDATE` | Any other lock, update or delete |
| `forNoKeyUpdate` | `FOR NO KEY UPDATE` | As above, but permits a foreign key reference |
| `forShare` | `FOR SHARE` | Updates and deletes; other `FOR SHARE` holders are fine |
| `forKeyShare` | `FOR KEY SHARE` | Deletes and updates to a key column |

`lockOf` restricts a clause to some of the query's `FROM` items rather than all
of them, naming them the way the query does — an aliased relation by its alias:

```purescript
select' [starFrom "o"]
  # fromAs "orders" "o"
  # innerJoin "users" (tcol "o" "user_id" .== tcol "users" "id")
  # forUpdate
  # lockOf ["o"]
-- SELECT "o".* FROM "orders" AS "o"
-- JOIN "users" ON ("o"."user_id" = "users"."id")
-- FOR UPDATE OF "o"
```

The builders are additive, so more than one clause can be applied — `forUpdate
# lockOf ["orders"] # forShare # lockOf ["users"]` locks the order for writing
and holds the user it belongs to against change. `lockOf`, `noWait` and
`skipLocked` refine the clause most recently added, and do nothing at all to a
query with no locking clause: they are modifiers rather than clauses, and there
is no strength for a bare one to assume. `noWait` and `skipLocked` share a
field, since SQL admits one or the other and never both, so the later call
replaces the earlier.

The clause is emitted last, after `LIMIT` and `OFFSET`, and carries no
parameters. This library emits statements and does not manage sessions, so the
lock is held by whatever transaction runs the SQL — outside one, a `FOR UPDATE`
locks nothing for longer than the statement itself. PostgreSQL rejects a
locking clause on a query that also uses `DISTINCT`, `GROUP BY`, `HAVING`, a
window function or a set operation, and rejects one naming a relation that is
not in the `FROM` list; those are rules it enforces itself rather than ones the
types express.

### Formatting

```purescript
-- Parameterised — use this when passing to a driver
format :: Query -> { sql :: String, params :: Array Literal }

-- Inlined — use this for logging and debugging only, never for user input
formatInline :: Query -> String
```

## Composing fragments

```purescript
baseUsers :: Query -> Query
baseUsers = select [star] >>> from "users"

activeOnly :: Query -> Query
activeOnly = where_ (col "active" .== bool true)

paginate :: Int -> Int -> Query -> Query
paginate size page = limit size >>> offset (size * page)

result = format $ baseUsers >>> activeOnly >>> paginate 20 0 $ emptyQuery
-- SELECT * FROM "users" WHERE "active" = $1 LIMIT 20 OFFSET 0
```

Use `mergeQueries` to combine fragments built independently:

```purescript
adminFilter = emptyQuery # where_ (col "role" .== str "admin")
result = format (mergeQueries baseUsers adminFilter)
```

## Testing

`make help` lists every development target. The common ones:

```
make test            # golden tests; also emits test-artifacts/corpus.json
make validate        # tests + validate every query against real PostgreSQL
make validate-fast   # validate only, reusing the corpus and a warm container
```

### PostgreSQL validation

Golden tests prove sqld emits the string we expected. They do not prove
PostgreSQL accepts it. A second harness closes that gap by replaying every
corpus query against a real server.

`make validate` starts a throwaway Postgres container, runs `spago test`, then
feeds each query to the server with `PREPARE`. Because `PREPARE` runs full parse
*analysis* — not just a syntax check — the harness catches bad syntax, unknown
columns, invalid `GROUP BY`, and operator type mismatches. Both formatter
outputs are validated: the parameterised form from `format` and the debug form
from `formatInline`.

The container is left running between invocations, so `make validate-fast` is
the quick inner loop. `make pg-stop` tears it down.

To narrow a run, or to probe a query without adding a corpus entry:

```
make list                                    # corpus entry names
make validate-fast ONLY=join                 # just the entries matching "join"
make sql SQL='SELECT "u".* FROM "users" AS "u"'   # ad-hoc query
```

`make sql` is the fastest way to answer "will PostgreSQL accept this?" while
working on a formatter change.

Against an existing server, skip the Makefile and drive the validator directly:

```
DATABASE_URL=postgres://user:pass@host:5432/sqld_validate node scripts/validate-sql.mjs
```

It accepts the same `--only`, `--sql` and `--list` flags; `--help` lists them.

The schema in `test/fixtures/schema.sql` drops and recreates `public`, so the
validator refuses to run unless the database name looks disposable. Override
with `SQLD_ALLOW_ANY_DB=1` only if you are certain.

The same steps run in CI on every push and pull request.

### Coverage

`test/Sqld/Corpus.purs` is the single corpus both harnesses consume. Each entry
is tagged with the AST constructors it exercises, and `Test.Sqld.CorpusSpec`
fails if any constructor in `Sqld.Core` has no entry — so a new feature cannot
ship without SQL that PostgreSQL has actually accepted. Adding a constructor
makes the tagging functions non-exhaustive, which the compiler reports, and the
new tag then fails the coverage assertion until a corpus entry exists.

Every table and column the corpus references must exist in
`test/fixtures/schema.sql`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the development loop, the corpus
coverage rule a new feature has to satisfy, and the commit conventions.
Participation is covered by the [Code of Conduct](CODE_OF_CONDUCT.md).

To report a suspected injection or quoting-escape issue, follow
[SECURITY.md](SECURITY.md) rather than opening a public issue.

## License

MIT — see [LICENSE](LICENSE).
