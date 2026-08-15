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
- [Aggregation](#aggregation)
- [Functions, casts and arbitrary operators](#functions-casts-and-arbitrary-operators)
- [EXISTS](#exists)
- [NOT EXISTS](#not-exists)
- [IN (SELECT …)](#in-select)
- [Scalar subqueries](#scalar-subqueries)
- [Derived tables](#derived-tables)
- [Joining a derived table](#joining-a-derived-table)
- [Common table expressions](#common-table-expressions)
- [Recursive CTEs](#recursive-ctes)
- [Pagination](#pagination)
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

The two halves of a recursive CTE are joined by `UNION ALL`, and set
operations are not in the AST yet — until they are, that half comes from
`raw`.

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
countUp = select' [ expr (raw "1 UNION ALL SELECT \"n\" + 1 FROM \"counting\" WHERE \"n\" < 10") ]
```

```sql
WITH RECURSIVE "counting" ("n") AS (
  SELECT 1 UNION ALL SELECT "n" + 1 FROM "counting" WHERE "n" < 10
)
SELECT *
FROM "counting"
```

<sub>Parameterised: <code>WITH RECURSIVE "counting" ("n") AS (SELECT 1 UNION ALL SELECT "n" + 1 FROM "counting" WHERE "n" < 10) SELECT * FROM "counting"</code></sub>

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

<sub>Parameterised: <code>SELECT "id", "title" FROM "articles" WHERE "published_at" IS NOT NULL ORDER BY "published_at" DESC, "id" ASC LIMIT 20 OFFSET 40</code></sub>

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

Bound parameters: `$1` = `true`, `$2` = `"engineering"`, `$3` = `"%@example.com"`

<sub>Parameterised: <code>SELECT "id", "name", "email", "department" FROM "users" WHERE (("active" = $1 AND "department" = $2) AND "email" LIKE $3) ORDER BY "created_at" DESC LIMIT 20 OFFSET 20</code></sub>

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

Bound parameters: `$1` = `true`, `$2` = `30`

<sub>Parameterised: <code>SELECT * FROM "users" WHERE ("active" = $1 AND "age" < $2) LIMIT 10</code></sub>

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
