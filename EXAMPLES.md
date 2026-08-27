# sqld by example

<!-- Generated from src/Example/Cookbook.purs by scripts/build-examples.mjs. Do not edit by hand. -->

Every example below is a real `Query` that compiles, and every SQL block is
what that code actually produced. The validation harness replays each one
against a live PostgreSQL server, so nothing here can be a query PostgreSQL
would reject.

The SQL blocks show literals inline for readability. `format` emits the same
query with each literal replaced by a numbered parameter and returns the
bindings alongside it — that parameterised form is shown in small text under
each example, and is what you pass to your driver.

Regenerate with `make examples`.

## Contents

- [Basic filtering](#basic-filtering)
- [Combining conditions](#combining-conditions)
- [NULL handling](#null-handling)
- [Pattern matching and ranges](#pattern-matching-and-ranges)
- [Joins](#joins)
- [Right joins](#right-joins)
- [Full joins](#full-joins)
- [Cross joins](#cross-joins)
- [Joining on shared column names](#joining-on-shared-column-names)
- [Natural joins](#natural-joins)
- [Aggregation](#aggregation)
- [Subtotals with ROLLUP, CUBE and GROUPING SETS](#subtotals-with-rollup-cube-and-grouping-sets)
- [Conditional aggregates with FILTER](#conditional-aggregates-with-filter)
- [Window functions](#window-functions)
- [DISTINCT](#distinct)
- [DISTINCT ON](#distinct-on)
- [Functions, casts and arbitrary operators](#functions-casts-and-arbitrary-operators)
- [EXISTS](#exists)
- [NOT EXISTS](#not-exists)
- [IN (SELECT …)](#in-select)
- [Scalar subqueries](#scalar-subqueries)
- [Derived tables](#derived-tables)
- [Joining a derived table](#joining-a-derived-table)
- [Lateral joins](#lateral-joins)
- [Set operations](#set-operations)
- [Common table expressions](#common-table-expressions)
- [Recursive CTEs](#recursive-ctes)
- [Pagination](#pagination)
- [Claiming work from a queue](#claiming-work-from-a-queue)
- [Composing fragments](#composing-fragments)
- [Merging independent queries](#merging-independent-queries)
- [The raw escape hatch](#the-raw-escape-hatch)

---

## Basic filtering

Name the columns you want, filter with `where_`. Literals never reach the
SQL string — they become numbered parameters, so there is nothing to escape.

```purescript
basicFiltering :: Query
basicFiltering =
  select' (cols [ "id", "name", "email" ])
    # from "users"
    # where_ (col "active" .== bool true)
```

```sql
SELECT "id", "name", "email"
FROM "users"
WHERE "active" = TRUE
```

Bound parameters: `$1` = `true`

<sub>Parameterised: <code>SELECT "id", "name", "email" FROM "users" WHERE "active" = $1</code></sub>

---

## Combining conditions

`and` and `or` nest freely and bracket themselves, so the emitted SQL means
what the structure says. Calling `where_` twice ANDs rather than replaces.

```purescript
combiningConditions :: Query
combiningConditions =
  select' [ star ]
    # from "users"
    # where_
        ( and
            [ or [ col "department" .== str "engineering", col "department" .== str "design" ]
            , not (col "active" .== bool false)
            , col "age" .>= int 18
            ]
        )
```

```sql
SELECT *
FROM "users"
WHERE (("department" = 'engineering' OR "department" = 'design') AND NOT "active" = FALSE AND "age" >= 18)
```

Bound parameters: `$1` = `"engineering"`, `$2` = `"design"`, `$3` = `false`, `$4` = `18`

<sub>Parameterised: <code>SELECT * FROM "users" WHERE (("department" = $1 OR "department" = $2) AND NOT "active" = $3 AND "age" >= $4)</code></sub>

---

## NULL handling

`isNull` / `isNotNull` emit real `IS NULL` tests rather than `= NULL`, which
is never true in SQL. `coalesce` supplies a fallback.

```purescript
nullHandling :: Query
nullHandling =
  select' (cols [ "id" ] <> [ as (coalesce [ col "email", str "(none)" ]) "email" ])
    # from "users"
    # where_ (and [ isNotNull (col "name"), isNull (col "department") ])
```

```sql
SELECT "id", COALESCE("email", '(none)') AS "email"
FROM "users"
WHERE ("name" IS NOT NULL AND "department" IS NULL)
```

Bound parameters: `$1` = `"(none)"`

<sub>Parameterised: <code>SELECT "id", COALESCE("email", $1) AS "email" FROM "users" WHERE ("name" IS NOT NULL AND "department" IS NULL)</code></sub>

---

## Pattern matching and ranges

`like` is case-sensitive, `ilike` is not. `between` is inclusive at both ends.

```purescript
patternMatching :: Query
patternMatching =
  select' [ star ]
    # from "users"
    # where_
        ( and
            [ ilike (col "email") "%@example.com"
            , between (col "age") (int 18) (int 65)
            , in_ (col "department") [ str "engineering", str "sales" ]
            ]
        )
```

```sql
SELECT *
FROM "users"
WHERE ("email" ILIKE '%@example.com' AND "age" BETWEEN 18 AND 65 AND "department" IN ('engineering', 'sales'))
```

Bound parameters: `$1` = `"%@example.com"`, `$2` = `18`, `$3` = `65`, `$4` = `"engineering"`, `$5` = `"sales"`

<sub>Parameterised: <code>SELECT * FROM "users" WHERE ("email" ILIKE $1 AND "age" BETWEEN $2 AND $3 AND "department" IN ($4, $5))</code></sub>

---

## Joins

Every join kind takes an alias variant. The `ON` condition is an ordinary
expression, so anything you can put in a `WHERE` works here too.

Column names may be dot-qualified: `col "u.id"` is `tcol "u" "id"`, which
keeps a select list close to the SQL it produces.

```purescript
joins :: Query
joins =
  select' (cols [ "u.name", "p.bio" ])
    # fromAs "users" "u"
    # leftJoinAs "profiles" "p" (col "u.id" .== col "p.user_id")
    # innerJoinAs "orders" "o" (and [ col "u.id" .== col "o.user_id", col "o.status" .== str "paid" ])
```

```sql
SELECT "u"."name", "p"."bio"
FROM "users" AS "u"
LEFT JOIN "profiles" AS "p" ON ("u"."id" = "p"."user_id")
JOIN "orders" AS "o" ON (("u"."id" = "o"."user_id" AND "o"."status" = 'paid'))
```

Bound parameters: `$1` = `"paid"`

<sub>Parameterised: <code>SELECT "u"."name", "p"."bio" FROM "users" AS "u" LEFT JOIN "profiles" AS "p" ON ("u"."id" = "p"."user_id") JOIN "orders" AS "o" ON (("u"."id" = "o"."user_id" AND "o"."status" = $1))</code></sub>

---

## Right joins

Keeps every row of the right-hand relation. `starFrom` selects every column
of one relation.

```purescript
rightJoinExample :: Query
rightJoinExample =
  select' [ starFrom "profiles" ]
    # from "users"
    # rightJoin "profiles" (col "users.id" .== col "profiles.user_id")
```

```sql
SELECT "profiles".*
FROM "users"
RIGHT JOIN "profiles" ON ("users"."id" = "profiles"."user_id")
```

<sub>Parameterised: <code>SELECT "profiles".* FROM "users" RIGHT JOIN "profiles" ON ("users"."id" = "profiles"."user_id")</code></sub>

---

## Full joins

Keeps unmatched rows from both sides.

```purescript
fullJoinExample :: Query
fullJoinExample =
  select' (cols [ "u.name", "p.bio" ])
    # fromAs "users" "u"
    # fullJoinAs "profiles" "p" (col "u.id" .== col "p.user_id")
```

```sql
SELECT "u"."name", "p"."bio"
FROM "users" AS "u"
FULL JOIN "profiles" AS "p" ON ("u"."id" = "p"."user_id")
```

<sub>Parameterised: <code>SELECT "u"."name", "p"."bio" FROM "users" AS "u" FULL JOIN "profiles" AS "p" ON ("u"."id" = "p"."user_id")</code></sub>

---

## Cross joins

Every row of one relation against every row of the other. `crossJoin` takes
no condition, and the AST has none to give it: `CROSS JOIN … ON (…)` is not
SQL, so it is not a query this library can build.

```purescript
crossJoinExample :: Query
crossJoinExample =
  select' (cols [ "users.name", "departments.building" ])
    # from "users"
    # crossJoin "departments"
```

```sql
SELECT "users"."name", "departments"."building"
FROM "users"
CROSS JOIN "departments"
```

<sub>Parameterised: <code>SELECT "users"."name", "departments"."building" FROM "users" CROSS JOIN "departments"</code></sub>

---

## Joining on shared column names

`USING` matches columns of the same name in both relations and collapses
each pair into one output column — which is why `"user_id"` below is
unambiguous, where the equivalent `ON` would leave two of it.

```purescript
joinUsingExample :: Query
joinUsingExample =
  select' (cols [ "user_id", "status", "bio" ])
    # from "orders"
    # joinUsing InnerJoin "profiles" [ "user_id" ]
```

```sql
SELECT "user_id", "status", "bio"
FROM "orders"
JOIN "profiles" USING ("user_id")
```

<sub>Parameterised: <code>SELECT "user_id", "status", "bio" FROM "orders" JOIN "profiles" USING ("user_id")</code></sub>

---

## Natural joins

`NATURAL` is `USING` with the column list left to the schema: it matches on
every name the two relations share. Convenient, and worth weighing against
the fact that a column added to either table silently changes the result.

```purescript
naturalJoinExample :: Query
naturalJoinExample =
  select' (cols [ "name", "building" ])
    # from "users"
    # naturalJoin LeftJoin "departments"
```

```sql
SELECT "name", "building"
FROM "users"
NATURAL LEFT JOIN "departments"
```

<sub>Parameterised: <code>SELECT "name", "building" FROM "users" NATURAL LEFT JOIN "departments"</code></sub>

---

## Aggregation

`countStar` is `COUNT(*)`; `having` filters the groups. Ordering by an output
alias works exactly as it does in SQL.

```purescript
aggregation :: Query
aggregation =
  select'
    ( cols [ "department" ] <>
        [ as countStar "headcount"
        , as (count (col "email")) "with_email"
        , as (avg (col "age")) "mean_age"
        ]
    )
    # from "users"
    # where_ (col "active" .== bool true)
    # groupBy [ col "department" ]
    # having (countStar .> int 3)
    # orderBy [ desc (col "headcount") ]
```

```sql
SELECT "department", COUNT(*) AS "headcount", COUNT("email") AS "with_email", AVG("age") AS "mean_age"
FROM "users"
WHERE "active" = TRUE
GROUP BY "department"
HAVING COUNT(*) > 3
ORDER BY "headcount" DESC
```

Bound parameters: `$1` = `true`, `$2` = `3`

<sub>Parameterised: <code>SELECT "department", COUNT(*) AS "headcount", COUNT("email") AS "with_email", AVG("age") AS "mean_age" FROM "users" WHERE "active" = $1 GROUP BY "department" HAVING COUNT(*) > $2 ORDER BY "headcount" DESC</code></sub>

---

## Subtotals with ROLLUP, CUBE and GROUPING SETS

A plain `groupBy` gives one level of detail. `groupByRollup` gives every
prefix of its expressions — `(department, active)`, then `(department)`, then
`()` — so the groups, the per-department subtotals and the grand total all
come back from one pass over the table. `groupByCube` gives every combination
rather than every prefix, and `groupBySets` names the groupings one by one,
where `[]` is that grand total.

A subtotal row carries `NULL` in the columns it rolled up, which is the same
`NULL` a user with no department has. `GROUPING(…)` tells the two apart: 1
where the column was rolled up, 0 where it was grouped by. It needs no
builder of its own, because `app` already reaches any function.

```purescript
subtotals :: Query
subtotals =
  select'
    ( cols [ "department", "active" ] <>
        [ as countStar "headcount"
        , as (app "GROUPING" [ col "department" ]) "is_total"
        ]
    )
    # from "users"
    # groupByRollup [ col "department", col "active" ]
    # orderBy [ asc (col "department"), asc (col "active") ]
```

```sql
SELECT "department", "active", COUNT(*) AS "headcount", GROUPING("department") AS "is_total"
FROM "users"
GROUP BY ROLLUP ("department", "active")
ORDER BY "department" ASC, "active" ASC
```

<sub>Parameterised: <code>SELECT "department", "active", COUNT(*) AS "headcount", GROUPING("department") AS "is_total" FROM "users" GROUP BY ROLLUP ("department", "active") ORDER BY "department" ASC, "active" ASC</code></sub>

---

## Conditional aggregates with FILTER

`filterWhere` restricts one aggregate to the rows its predicate keeps, while
the aggregates beside it still see the whole group. So the subset and the
total it came out of arrive together, from one pass over the table — where a
`where_` would have narrowed every column at once, and the older
`SUM(CASE WHEN … THEN 1 ELSE 0 END)` says the same thing at several times the
length.

`FILTER` binds to the aggregate call itself. That makes it an atom needing no
brackets in a larger expression, and it is why it precedes `OVER` when the
two meet: the modifier belongs to the call, the window to what is done with
its result.

```purescript
conditionalAggregates :: Query
conditionalAggregates =
  select'
    ( cols [ "department" ] <>
        [ as (countStar `filterWhere` (col "active" .== bool true)) "active_count"
        , as countStar "headcount"
        , as (avg (col "age") `filterWhere` (col "age" .>= int 21)) "mean_adult_age"
        ]
    )
    # from "users"
    # groupBy [ col "department" ]
    # orderBy [ desc (col "active_count") ]
```

```sql
SELECT "department", COUNT(*) FILTER (WHERE "active" = TRUE) AS "active_count", COUNT(*) AS "headcount", AVG("age") FILTER (WHERE "age" >= 21) AS "mean_adult_age"
FROM "users"
GROUP BY "department"
ORDER BY "active_count" DESC
```

Bound parameters: `$1` = `true`, `$2` = `21`

<sub>Parameterised: <code>SELECT "department", COUNT(*) FILTER (WHERE "active" = $1) AS "active_count", COUNT(*) AS "headcount", AVG("age") FILTER (WHERE "age" >= $2) AS "mean_adult_age" FROM "users" GROUP BY "department" ORDER BY "active_count" DESC</code></sub>

---

## Window functions

`over` evaluates an aggregate — or a window-only function such as
`rowNumber`, `rank` or `lag` — across a set of rows related to the current
one, without collapsing them the way `groupBy` does. Every row survives, and
each carries its own answer.

A window is built the way a query is: `partitionBy'` and `orderWindow'` start
one the way `select'` starts a query, and `partitionBy`, `orderWindow` and
`withFrame` pipe onto it with `#`. So a window used once is written inline,
and one shared by several columns gets a name — `byUser` here, which
`chronological` and `runningTotal` extend. `withFrame` is what turns an
ordered sum into a running one: every row from the start of the partition up
to the current one.

```purescript
windowFunctions :: Query
windowFunctions =
  select'
    ( cols [ "user_id", "placed_at", "total" ] <>
        [ as (rowNumber `over` (partitionBy' [ col "user_id" ] # orderWindow [ desc (col "total") ])) "biggest_first"
        , as (lag (col "total") 1 `over` chronological) "previous_total"
        , as (sum_ (col "total") `over` runningTotal) "running_total"
        ]
    )
    # from "orders"
    # where_ (col "status" .== str "paid")

byUser :: Window
byUser = partitionBy' [ col "user_id" ]

chronological :: Window
chronological = byUser # orderWindow [ asc (col "placed_at") ]

runningTotal :: Window
runningTotal = chronological # withFrame (rows unboundedPreceding currentRow)
```

```sql
SELECT "user_id", "placed_at", "total", ROW_NUMBER() OVER (PARTITION BY "user_id" ORDER BY "total" DESC) AS "biggest_first", LAG("total", 1) OVER (PARTITION BY "user_id" ORDER BY "placed_at" ASC) AS "previous_total", SUM("total") OVER (PARTITION BY "user_id" ORDER BY "placed_at" ASC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "running_total"
FROM "orders"
WHERE "status" = 'paid'
```

Bound parameters: `$1` = `1`, `$2` = `"paid"`

<sub>Parameterised: <code>SELECT "user_id", "placed_at", "total", ROW_NUMBER() OVER (PARTITION BY "user_id" ORDER BY "total" DESC) AS "biggest_first", LAG("total", $1) OVER (PARTITION BY "user_id" ORDER BY "placed_at" ASC) AS "previous_total", SUM("total") OVER (PARTITION BY "user_id" ORDER BY "placed_at" ASC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "running_total" FROM "orders" WHERE "status" = $2</code></sub>

---

## DISTINCT

Duplicate rows collapse to one, compared across the whole select list — here,
the departments with at least one active user.

```purescript
distinctExample :: Query
distinctExample =
  select' (cols [ "department" ])
    # distinct
    # from "users"
    # where_ (col "active" .== bool true)
    # orderBy [ asc (col "department") ]
```

```sql
SELECT DISTINCT "department"
FROM "users"
WHERE "active" = TRUE
ORDER BY "department" ASC
```

Bound parameters: `$1` = `true`

<sub>Parameterised: <code>SELECT DISTINCT "department" FROM "users" WHERE "active" = $1 ORDER BY "department" ASC</code></sub>

---

## DISTINCT ON

PostgreSQL's own, and the shortest way to say "one row per group": it keeps
the first row of each group of the named expressions, where "first" is
whatever the `orderBy` says — so this is each user's most recent paid order,
without a window function or a self-join.

PostgreSQL requires the leading `orderBy` expressions to match the ones given
to `distinctOn`, a rule it enforces itself and that the validation harness
holds this example to. `distinct` and `distinctOn` share one field, because a
`SELECT` is one or the other and never both: whichever is applied last wins.

```purescript
distinctOnExample :: Query
distinctOnExample =
  select' (cols [ "user_id", "status", "total", "placed_at" ])
    # distinctOn [ col "user_id" ]
    # from "orders"
    # where_ (col "status" .== str "paid")
    # orderBy [ asc (col "user_id"), desc (col "placed_at") ]
```

```sql
SELECT DISTINCT ON ("user_id") "user_id", "status", "total", "placed_at"
FROM "orders"
WHERE "status" = 'paid'
ORDER BY "user_id" ASC, "placed_at" DESC
```

Bound parameters: `$1` = `"paid"`

<sub>Parameterised: <code>SELECT DISTINCT ON ("user_id") "user_id", "status", "total", "placed_at" FROM "orders" WHERE "status" = $1 ORDER BY "user_id" ASC, "placed_at" DESC</code></sub>

---

## Functions, casts and arbitrary operators

`app` reaches any function PostgreSQL knows, `binOp` any operator, and `cast`
any type — so an unsupported feature rarely means falling back to `raw`.
Brackets appear only where precedence demands them.

```purescript
functionsAndCasts :: Query
functionsAndCasts =
  select'
    [ as (binOp "||" (col "name") (col "department")) "label"
    , as (cast (col "id") "text") "id_text"
    ]
    # from "users"
    # where_ (binOp "*" (binOp "+" (col "age") (int 1)) (int 2) .> int 40)
```

```sql
SELECT "name" || "department" AS "label", "id"::text AS "id_text"
FROM "users"
WHERE ("age" + 1) * 2 > 40
```

Bound parameters: `$1` = `1`, `$2` = `2`, `$3` = `40`

<sub>Parameterised: <code>SELECT "name" || "department" AS "label", "id"::text AS "id_text" FROM "users" WHERE ("age" + $1) * $2 > $3</code></sub>

---

## EXISTS

Correlate a subquery against the outer query to test for related rows
without joining and de-duplicating.

```purescript
existsExample :: Query
existsExample =
  select' [ star ]
    # fromAs "users" "u"
    # where_
        ( exists
            ( select' [ expr (raw "1") ]
                # from "orders"
                # where_ (and [ col "orders.user_id" .== col "u.id", col "orders.status" .== str "paid" ])
            )
        )
```

```sql
SELECT *
FROM "users" AS "u"
WHERE EXISTS (
  SELECT 1
  FROM "orders"
  WHERE ("orders"."user_id" = "u"."id" AND "orders"."status" = 'paid')
)
```

Bound parameters: `$1` = `"paid"`

<sub>Parameterised: <code>SELECT * FROM "users" AS "u" WHERE EXISTS (SELECT 1 FROM "orders" WHERE ("orders"."user_id" = "u"."id" AND "orders"."status" = $1))</code></sub>

---

## NOT EXISTS

The natural way to ask "rows with nothing related" — here, users who have
never ordered.

```purescript
notExistsExample :: Query
notExistsExample =
  select' (tcols "u" [ "id", "name" ])
    # fromAs "users" "u"
    # where_
        ( notExists
            ( select' [ expr (raw "1") ]
                # from "orders"
                # where_ (col "orders.user_id" .== col "u.id")
            )
        )
```

```sql
SELECT "u"."id", "u"."name"
FROM "users" AS "u"
WHERE NOT EXISTS (
  SELECT 1
  FROM "orders"
  WHERE "orders"."user_id" = "u"."id"
)
```

<sub>Parameterised: <code>SELECT "u"."id", "u"."name" FROM "users" AS "u" WHERE NOT EXISTS (SELECT 1 FROM "orders" WHERE "orders"."user_id" = "u"."id")</code></sub>

---

## IN (SELECT …)

`inSub` takes a whole query as the right operand. Parameters inside it are
numbered in step with the outer query.

```purescript
subqueryIn :: Query
subqueryIn =
  select' [ star ]
    # from "users"
    # where_
        ( inSub (col "id")
            ( select' (cols [ "user_id" ])
                # from "orders"
                # where_ (col "total" .> num 100.0)
            )
        )
```

```sql
SELECT *
FROM "users"
WHERE "id" IN (
  SELECT "user_id"
  FROM "orders"
  WHERE "total" > 100.0
)
```

Bound parameters: `$1` = `100`

<sub>Parameterised: <code>SELECT * FROM "users" WHERE "id" IN (SELECT "user_id" FROM "orders" WHERE "total" > $1)</code></sub>

---

## Scalar subqueries

A subquery in the select list, correlated against the outer row.

```purescript
scalarSubquery :: Query
scalarSubquery =
  select'
    ( cols [ "u.name" ] <>
        [ as
            ( sub
                ( select' (exprs [ countStar ])
                    # from "orders"
                    # where_ (col "orders.user_id" .== col "u.id")
                )
            )
            "order_count"
        ]
    )
    # fromAs "users" "u"
```

```sql
SELECT "u"."name", (
  SELECT COUNT(*)
  FROM "orders"
  WHERE "orders"."user_id" = "u"."id"
) AS "order_count"
FROM "users" AS "u"
```

<sub>Parameterised: <code>SELECT "u"."name", (SELECT COUNT(*) FROM "orders" WHERE "orders"."user_id" = "u"."id") AS "order_count" FROM "users" AS "u"</code></sub>

---

## Derived tables

A subquery in `FROM`. The alias is mandatory because PostgreSQL requires one,
so the type asks for a `String` rather than a `Maybe String`. Parameters
inside the subquery are numbered before the outer query's.

```purescript
derivedTable :: Query
derivedTable =
  select' [ starFrom "paid" ]
    # fromSub
        ( select' (cols [ "id", "user_id", "total" ])
            # from "orders"
            # where_ (col "status" .== str "paid")
        )
        "paid"
    # where_ (col "paid.total" .> num 100.0)
```

```sql
SELECT "paid".*
FROM (
  SELECT "id", "user_id", "total"
  FROM "orders"
  WHERE "status" = 'paid'
) AS "paid"
WHERE "paid"."total" > 100.0
```

Bound parameters: `$1` = `"paid"`, `$2` = `100`

<sub>Parameterised: <code>SELECT "paid".* FROM (SELECT "id", "user_id", "total" FROM "orders" WHERE "status" = $1) AS "paid" WHERE "paid"."total" > $2</code></sub>

---

## Joining a derived table

`joinOn` takes a `Relation`, so `derived` lets you join against a subquery —
here, per-user totals computed once and joined back.

```purescript
derivedTableJoin :: Query
derivedTableJoin =
  select' (cols [ "u.name", "totals.order_count" ])
    # fromAs "users" "u"
    # joinOn InnerJoin
        ( derived
            ( select' (cols [ "user_id" ] <> [ as countStar "order_count" ])
                # from "orders"
                # groupBy [ col "user_id" ]
            )
            "totals"
        )
        (col "u.id" .== col "totals.user_id")
```

```sql
SELECT "u"."name", "totals"."order_count"
FROM "users" AS "u"
JOIN (
  SELECT "user_id", COUNT(*) AS "order_count"
  FROM "orders"
  GROUP BY "user_id"
) AS "totals" ON ("u"."id" = "totals"."user_id")
```

<sub>Parameterised: <code>SELECT "u"."name", "totals"."order_count" FROM "users" AS "u" JOIN (SELECT "user_id", COUNT(*) AS "order_count" FROM "orders" GROUP BY "user_id") AS "totals" ON ("u"."id" = "totals"."user_id")</code></sub>

---

## Lateral joins

A derived table is evaluated on its own, so it cannot see the relations
beside it. `lateral` lifts that restriction, and with it the per-row shape:
the three most recent orders of *each* user, in one join rather than one
correlated subquery per column.

The correlation inside the subquery is the whole of the matching, so a
lateral join has nothing left to say in a condition and `joinLateral` joins
`ON TRUE`. Use `leftJoinLateral` to keep users whose subquery finds nothing;
those are the only two kinds, because PostgreSQL rejects a lateral reference
from the right operand of a `RIGHT` or `FULL` join.

```purescript
lateralJoin :: Query
lateralJoin =
  select' (cols [ "u.name", "recent.total" ])
    # fromAs "users" "u"
    # joinLateral
        ( select' (cols [ "total" ])
            # from "orders"
            # where_ (col "orders.user_id" .== col "u.id")
            # orderBy [ desc (col "placed_at") ]
            # limit 3
        )
        "recent"
```

```sql
SELECT "u"."name", "recent"."total"
FROM "users" AS "u"
JOIN LATERAL (
  SELECT "total"
  FROM "orders"
  WHERE "orders"."user_id" = "u"."id"
  ORDER BY "placed_at" DESC
  LIMIT 3
) AS "recent" ON (TRUE)
```

Bound parameters: `$1` = `3`

<sub>Parameterised: <code>SELECT "u"."name", "recent"."total" FROM "users" AS "u" JOIN LATERAL (SELECT "total" FROM "orders" WHERE "orders"."user_id" = "u"."id" ORDER BY "placed_at" DESC LIMIT $1) AS "recent" ON (TRUE)</code></sub>

---

## Set operations

`union`, `intersect` and `except` combine two result sets; each has an `All`
variant that keeps duplicate rows. The query you pipe from is the left
operand, so a chain reads in the order it is emitted.

Both operands are bracketed, so a chain of mixed operators means what it
reads like, and each operand keeps its own `ORDER BY` and `LIMIT`. Applying
`orderBy`, `limit` or `offset` *after* the operation lands outside the
brackets, so it applies to the combined result — here, active users who have
never had an order cancelled.

```purescript
setOperations :: Query
setOperations =
  select' (cols [ "id" ])
    # from "users"
    # where_ (col "active" .== bool true)
    # except
        ( select' (cols [ "user_id" ])
            # from "orders"
            # where_ (col "status" .== str "cancelled")
        )
    # orderBy [ asc (col "id") ]
    # limit 20
```

```sql
(
  SELECT "id"
  FROM "users"
  WHERE "active" = TRUE
)
EXCEPT
(
  SELECT "user_id"
  FROM "orders"
  WHERE "status" = 'cancelled'
)
ORDER BY "id" ASC
LIMIT 20
```

Bound parameters: `$1` = `true`, `$2` = `"cancelled"`, `$3` = `20`

<sub>Parameterised: <code>(SELECT "id" FROM "users" WHERE "active" = $1) EXCEPT (SELECT "user_id" FROM "orders" WHERE "status" = $2) ORDER BY "id" ASC LIMIT $3</code></sub>

---

## Common table expressions

`with_` names an intermediate result set. A later CTE may reference an
earlier one, and the outer query treats each as an ordinary relation — so a
reporting query reads as a sequence of named steps rather than a pile of
nested subqueries. Parameters inside a CTE are numbered before the outer
query's, matching where they appear in the emitted SQL.

```purescript
commonTableExpressions :: Query
commonTableExpressions =
  select' (cols [ "u.name", "spend.total" ])
    # with_ "paid"
        ( select' (cols [ "user_id", "total" ])
            # from "orders"
            # where_ (col "status" .== str "paid")
        )
    # with_ "spend"
        ( select' (cols [ "user_id" ] <> [ as (sum_ (col "total")) "total" ])
            # from "paid"
            # groupBy [ col "user_id" ]
        )
    # fromAs "users" "u"
    # innerJoin "spend" (col "u.id" .== col "spend.user_id")
    # where_ (col "spend.total" .> num 500.0)
```

```sql
WITH "paid" AS (
  SELECT "user_id", "total"
  FROM "orders"
  WHERE "status" = 'paid'
),
"spend" AS (
  SELECT "user_id", SUM("total") AS "total"
  FROM "paid"
  GROUP BY "user_id"
)
SELECT "u"."name", "spend"."total"
FROM "users" AS "u"
JOIN "spend" ON ("u"."id" = "spend"."user_id")
WHERE "spend"."total" > 500.0
```

Bound parameters: `$1` = `"paid"`, `$2` = `500`

<sub>Parameterised: <code>WITH "paid" AS (SELECT "user_id", "total" FROM "orders" WHERE "status" = $1), "spend" AS (SELECT "user_id", SUM("total") AS "total" FROM "paid" GROUP BY "user_id") SELECT "u"."name", "spend"."total" FROM "users" AS "u" JOIN "spend" ON ("u"."id" = "spend"."user_id") WHERE "spend"."total" > $2</code></sub>

---

## Recursive CTEs

`withRecursive` lets a CTE refer to itself. `RECURSIVE` belongs to the whole
`WITH` clause in SQL, so one recursive entry is enough — the other CTEs need
no change. `withCte` is the general form, and `cteColumns` names the output
columns, which a recursive CTE usually wants.

The two halves are joined by `unionAll`: an anchor term, then a recursive
term that reads from the CTE being defined. The anchor's `1` is `raw` rather
than `int 1` because a bare parameter in a select list gives PostgreSQL
nothing to infer a type from.

```purescript
recursiveCte :: Query
recursiveCte =
  select' [ star ]
    # withCte
        ( cte "counting" countUp
            # cteColumns [ "n" ]
            # cteRecursive
        )
    # from "counting"

countUp :: Query
countUp =
  select' [ expr (raw "1") ]
    # unionAll
        ( select' [ expr (binOp "+" (col "n") (int 1)) ]
            # from "counting"
            # where_ (col "n" .< int 10)
        )
```

```sql
WITH RECURSIVE "counting" ("n") AS (
  (
    SELECT 1
  )
  UNION ALL
  (
    SELECT "n" + 1
    FROM "counting"
    WHERE "n" < 10
  )
)
SELECT *
FROM "counting"
```

Bound parameters: `$1` = `1`, `$2` = `10`

<sub>Parameterised: <code>WITH RECURSIVE "counting" ("n") AS ((SELECT 1) UNION ALL (SELECT "n" + $1 FROM "counting" WHERE "n" < $2)) SELECT * FROM "counting"</code></sub>

---

## Pagination

Builders are plain `Query -> Query` functions, so a pagination helper is
ordinary composition rather than anything the library needs to know about.

```purescript
paginate :: Int -> Int -> Query -> Query
paginate pageSize page = limit pageSize >>> offset (pageSize * page)

pagination :: Query
pagination =
  select' (cols [ "id", "title" ])
    # from "articles"
    # where_ (isNotNull (col "published_at"))
    # orderBy [ desc (col "published_at"), asc (col "id") ]
    # paginate 20 2
```

```sql
SELECT "id", "title"
FROM "articles"
WHERE "published_at" IS NOT NULL
ORDER BY "published_at" DESC, "id" ASC
LIMIT 20
OFFSET 40
```

Bound parameters: `$1` = `20`, `$2` = `40`

<sub>Parameterised: <code>SELECT "id", "title" FROM "articles" WHERE "published_at" IS NOT NULL ORDER BY "published_at" DESC, "id" ASC LIMIT $1 OFFSET $2</code></sub>

---

## Claiming work from a queue

`FOR UPDATE` locks the rows this transaction reads; `SKIP LOCKED` steps over
the ones another worker already holds instead of waiting behind them. Two
workers running this at once therefore claim disjoint batches. The clause is
emitted last, after `LIMIT`, which is the only place SQL accepts it.

```purescript
workQueue :: Query
workQueue =
  select' (cols [ "id", "total" ])
    # from "orders"
    # where_ (col "status" .== str "pending")
    # orderBy [ asc (col "placed_at") ]
    # limit 10
    # forUpdate
    # skipLocked
```

```sql
SELECT "id", "total"
FROM "orders"
WHERE "status" = 'pending'
ORDER BY "placed_at" ASC
LIMIT 10
FOR UPDATE SKIP LOCKED
```

Bound parameters: `$1` = `"pending"`, `$2` = `10`

<sub>Parameterised: <code>SELECT "id", "total" FROM "orders" WHERE "status" = $1 ORDER BY "placed_at" ASC LIMIT $2 FOR UPDATE SKIP LOCKED</code></sub>

---

## Composing fragments

The real payoff: named fragments compose with `>>>`, and optional filters
fall out of `maybe identity`. No string concatenation, and no `WHERE 1=1`.

```purescript
activeUsers :: Query -> Query
activeUsers =
  select (cols [ "id", "name", "email", "department" ])
    >>> from "users"
    >>> where_ (col "active" .== bool true)

inDepartment :: String -> Query -> Query
inDepartment department = where_ (col "department" .== str department)

emailedAt :: String -> Query -> Query
emailedAt domain = where_ (like (col "email") ("%" <> domain))

newestFirst :: Query -> Query
newestFirst = orderBy [ desc (col "created_at") ]

searchUsers :: Maybe String -> Maybe String -> Int -> Query
searchUsers mDepartment mDomain page =
  activeUsers
    >>> maybe identity inDepartment mDepartment
    >>> maybe identity emailedAt mDomain
    >>> newestFirst
    >>> paginate 20 page
    $ emptyQuery

composingFragments :: Query
composingFragments = searchUsers (Just "engineering") (Just "@example.com") 1
```

```sql
SELECT "id", "name", "email", "department"
FROM "users"
WHERE (("active" = TRUE AND "department" = 'engineering') AND "email" LIKE '%@example.com')
ORDER BY "created_at" DESC
LIMIT 20
OFFSET 20
```

Bound parameters: `$1` = `true`, `$2` = `"engineering"`, `$3` = `"%@example.com"`, `$4` = `20`, `$5` = `20`

<sub>Parameterised: <code>SELECT "id", "name", "email", "department" FROM "users" WHERE (("active" = $1 AND "department" = $2) AND "email" LIKE $3) ORDER BY "created_at" DESC LIMIT $4 OFFSET $5</code></sub>

---

## Merging independent queries

`mergeQueries` combines two queries built without knowledge of each other.
WHERE clauses are ANDed; joins concatenate; scalars take the right-hand side.

```purescript
mergingQueries :: Query
mergingQueries =
  mergeQueries
    (select' [ star ] # from "users" # where_ (col "active" .== bool true))
    (emptyQuery # where_ (col "age" .< int 30) # limit 10)
```

```sql
SELECT *
FROM "users"
WHERE ("active" = TRUE AND "age" < 30)
LIMIT 10
```

Bound parameters: `$1` = `true`, `$2` = `30`, `$3` = `10`

<sub>Parameterised: <code>SELECT * FROM "users" WHERE ("active" = $1 AND "age" < $2) LIMIT $3</code></sub>

---

## The raw escape hatch

For SQL the builders do not reach. `raw` is emitted verbatim: it is not
quoted, not parameterised, and not bracketed, so never build one from user
input. Reach for `app` and `binOp` first.

```purescript
rawEscapeHatch :: Query
rawEscapeHatch =
  select' [ colAs "id" "id", as (raw "date_trunc('month', \"created_at\")") "month" ]
    # from "users"
    # where_ (raw "\"created_at\" > NOW() - INTERVAL '30 days'")
```

```sql
SELECT "id" AS "id", date_trunc('month', "created_at") AS "month"
FROM "users"
WHERE "created_at" > NOW() - INTERVAL '30 days'
```

<sub>Parameterised: <code>SELECT "id" AS "id", date_trunc('month', "created_at") AS "month" FROM "users" WHERE "created_at" > NOW() - INTERVAL '30 days'</code></sub>
