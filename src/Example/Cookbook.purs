-- | The worked examples behind `EXAMPLES.md`.
-- |
-- | Nothing here is decorative. Every example is a real `Query` that:
-- |
-- |   * compiles, so it cannot reference an API that does not exist;
-- |   * is replayed against PostgreSQL by the validation harness, so it cannot
-- |     be invalid SQL; and
-- |   * is rendered into `EXAMPLES.md` by `scripts/build-examples.mjs`, which
-- |     slices the code straight out of this file rather than from a copy.
-- |
-- | The `-- #example` markers below delimit those slices. The generator checks
-- | them against `cookbook` and fails if the two disagree, so an example cannot
-- | go missing from either side.
-- |
-- | Every table and column referenced here must exist in
-- | `test/fixtures/schema.sql`.
module Example.Cookbook
  ( Example
  , cookbook
  ) where

import Prelude hiding (between, not, sub)

import Data.Maybe (Maybe(..), maybe)
import Sqld.Core (JoinType(..), Query, Window, emptyQuery, emptyWindow)
import Sqld.Expr (and, avg, between, binOp, bool, cast, coalesce, col, count, countStar, currentRow, exists, ilike, in_, inSub, int, isNotNull, isNull, lag, like, not, notExists, num, or, over, raw, rows, rowNumber, str, sub, sum_, unboundedPreceding, (.<), (.==), (.>), (.>=))
import Sqld.Select (as, asc, colAs, cols, cte, cteColumns, cteRecursive, derived, desc, except, expr, from, fromAs, fromSub, fullJoinAs, groupBy, having, innerJoin, innerJoinAs, joinOn, leftJoinAs, limit, mergeQueries, offset, exprs, orderBy, rightJoin, select, select', star, starFrom, tcols, unionAll, where_, withCte, with_)

type Example =
  { name  :: String
  , query :: Query
  }

-- #example basic-filtering
-- # Basic filtering
-- Name the columns you want, filter with `where_`. Literals never reach the
-- SQL string — they become numbered parameters, so there is nothing to escape.
basicFiltering :: Query
basicFiltering =
  select' (cols [ "id", "name", "email" ])
    # from "users"
    # where_ (col "active" .== bool true)

-- #example combining-conditions
-- # Combining conditions
-- `and` and `or` nest freely and bracket themselves, so the emitted SQL means
-- what the structure says. Calling `where_` twice ANDs rather than replaces.
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

-- #example null-handling
-- # NULL handling
-- `isNull` / `isNotNull` emit real `IS NULL` tests rather than `= NULL`, which
-- is never true in SQL. `coalesce` supplies a fallback.
nullHandling :: Query
nullHandling =
  select' (cols [ "id" ] <> [ as (coalesce [ col "email", str "(none)" ]) "email" ])
    # from "users"
    # where_ (and [ isNotNull (col "name"), isNull (col "department") ])

-- #example pattern-matching
-- # Pattern matching and ranges
-- `like` is case-sensitive, `ilike` is not. `between` is inclusive at both ends.
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

-- #example joins
-- # Joins
-- Every join kind takes an alias variant. The `ON` condition is an ordinary
-- expression, so anything you can put in a `WHERE` works here too.
--
-- Column names may be dot-qualified: `col "u.id"` is `tcol "u" "id"`, which
-- keeps a select list close to the SQL it produces.
joins :: Query
joins =
  select' (cols [ "u.name", "p.bio" ])
    # fromAs "users" "u"
    # leftJoinAs "profiles" "p" (col "u.id" .== col "p.user_id")
    # innerJoinAs "orders" "o" (and [ col "u.id" .== col "o.user_id", col "o.status" .== str "paid" ])

-- #example right-join
-- # Right joins
-- Keeps every row of the right-hand relation. `starFrom` selects every column
-- of one relation.
rightJoinExample :: Query
rightJoinExample =
  select' [ starFrom "profiles" ]
    # from "users"
    # rightJoin "profiles" (col "users.id" .== col "profiles.user_id")

-- #example full-join
-- # Full joins
-- Keeps unmatched rows from both sides.
fullJoinExample :: Query
fullJoinExample =
  select' (cols [ "u.name", "p.bio" ])
    # fromAs "users" "u"
    # fullJoinAs "profiles" "p" (col "u.id" .== col "p.user_id")

-- #example aggregation
-- # Aggregation
-- `countStar` is `COUNT(*)`; `having` filters the groups. Ordering by an output
-- alias works exactly as it does in SQL.
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

-- #example window-functions
-- # Window functions
-- `over` evaluates an aggregate — or a window-only function such as
-- `rowNumber`, `rank` or `lag` — across a set of rows related to the current
-- one, without collapsing them the way `groupBy` does. Every row survives, and
-- each carries its own answer.
--
-- A `Window` is a plain record, so windows compose by record update: `byUser`
-- names the partition once, and each column below adds the ordering or frame it
-- needs. `frame` is what turns an ordered sum into a running one — here, every
-- row from the start of the partition up to the current one.
windowFunctions :: Query
windowFunctions =
  select'
    ( cols [ "user_id", "placed_at", "total" ] <>
        [ as (rowNumber `over` byUser { orderBy = [ desc (col "total") ] }) "biggest_first"
        , as (lag (col "total") 1 `over` chronological) "previous_total"
        , as (sum_ (col "total") `over` runningTotal) "running_total"
        ]
    )
    # from "orders"
    # where_ (col "status" .== str "paid")

byUser :: Window
byUser = emptyWindow { partitionBy = [ col "user_id" ] }

chronological :: Window
chronological = byUser { orderBy = [ asc (col "placed_at") ] }

runningTotal :: Window
runningTotal = chronological { frame = Just (rows unboundedPreceding currentRow) }

-- #example functions-and-casts
-- # Functions, casts and arbitrary operators
-- `app` reaches any function PostgreSQL knows, `binOp` any operator, and `cast`
-- any type — so an unsupported feature rarely means falling back to `raw`.
-- Brackets appear only where precedence demands them.
functionsAndCasts :: Query
functionsAndCasts =
  select'
    [ as (binOp "||" (col "name") (col "department")) "label"
    , as (cast (col "id") "text") "id_text"
    ]
    # from "users"
    # where_ (binOp "*" (binOp "+" (col "age") (int 1)) (int 2) .> int 40)

-- #example exists
-- # EXISTS
-- Correlate a subquery against the outer query to test for related rows
-- without joining and de-duplicating.
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

-- #example not-exists
-- # NOT EXISTS
-- The natural way to ask "rows with nothing related" — here, users who have
-- never ordered.
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

-- #example subquery-in
-- # IN (SELECT …)
-- `inSub` takes a whole query as the right operand. Parameters inside it are
-- numbered in step with the outer query.
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

-- #example scalar-subquery
-- # Scalar subqueries
-- A subquery in the select list, correlated against the outer row.
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

-- #example derived-table
-- # Derived tables
-- A subquery in `FROM`. The alias is mandatory because PostgreSQL requires one,
-- so the type asks for a `String` rather than a `Maybe String`. Parameters
-- inside the subquery are numbered before the outer query's.
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

-- #example derived-table-join
-- # Joining a derived table
-- `joinOn` takes a `Relation`, so `derived` lets you join against a subquery —
-- here, per-user totals computed once and joined back.
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

-- #example set-operations
-- # Set operations
-- `union`, `intersect` and `except` combine two result sets; each has an `All`
-- variant that keeps duplicate rows. The query you pipe from is the left
-- operand, so a chain reads in the order it is emitted.
--
-- Both operands are bracketed, so a chain of mixed operators means what it
-- reads like, and each operand keeps its own `ORDER BY` and `LIMIT`. Applying
-- `orderBy`, `limit` or `offset` *after* the operation lands outside the
-- brackets, so it applies to the combined result — here, active users who have
-- never had an order cancelled.
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

-- #example common-table-expressions
-- # Common table expressions
-- `with_` names an intermediate result set. A later CTE may reference an
-- earlier one, and the outer query treats each as an ordinary relation — so a
-- reporting query reads as a sequence of named steps rather than a pile of
-- nested subqueries. Parameters inside a CTE are numbered before the outer
-- query's, matching where they appear in the emitted SQL.
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

-- #example recursive-cte
-- # Recursive CTEs
-- `withRecursive` lets a CTE refer to itself. `RECURSIVE` belongs to the whole
-- `WITH` clause in SQL, so one recursive entry is enough — the other CTEs need
-- no change. `withCte` is the general form, and `cteColumns` names the output
-- columns, which a recursive CTE usually wants.
--
-- The two halves are joined by `unionAll`: an anchor term, then a recursive
-- term that reads from the CTE being defined. The anchor's `1` is `raw` rather
-- than `int 1` because a bare parameter in a select list gives PostgreSQL
-- nothing to infer a type from.
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

-- #example pagination
-- # Pagination
-- Builders are plain `Query -> Query` functions, so a pagination helper is
-- ordinary composition rather than anything the library needs to know about.
paginate :: Int -> Int -> Query -> Query
paginate pageSize page = limit pageSize >>> offset (pageSize * page)

pagination :: Query
pagination =
  select' (cols [ "id", "title" ])
    # from "articles"
    # where_ (isNotNull (col "published_at"))
    # orderBy [ desc (col "published_at"), asc (col "id") ]
    # paginate 20 2

-- #example composing-fragments
-- # Composing fragments
-- The real payoff: named fragments compose with `>>>`, and optional filters
-- fall out of `maybe identity`. No string concatenation, and no `WHERE 1=1`.
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

-- #example merging-queries
-- # Merging independent queries
-- `mergeQueries` combines two queries built without knowledge of each other.
-- WHERE clauses are ANDed; joins concatenate; scalars take the right-hand side.
mergingQueries :: Query
mergingQueries =
  mergeQueries
    (select' [ star ] # from "users" # where_ (col "active" .== bool true))
    (emptyQuery # where_ (col "age" .< int 30) # limit 10)

-- #example raw-escape-hatch
-- # The raw escape hatch
-- For SQL the builders do not reach. `raw` is emitted verbatim: it is not
-- quoted, not parameterised, and not bracketed, so never build one from user
-- input. Reach for `app` and `binOp` first.
rawEscapeHatch :: Query
rawEscapeHatch =
  select' [ colAs "id" "id", as (raw "date_trunc('month', \"created_at\")") "month" ]
    # from "users"
    # where_ (raw "\"created_at\" > NOW() - INTERVAL '30 days'")

-- #end

-- | Every example, in the order they appear in `EXAMPLES.md`.
cookbook :: Array Example
cookbook =
  [ { name: "basic-filtering",      query: basicFiltering }
  , { name: "combining-conditions", query: combiningConditions }
  , { name: "null-handling",        query: nullHandling }
  , { name: "pattern-matching",     query: patternMatching }
  , { name: "joins",                query: joins }
  , { name: "right-join",           query: rightJoinExample }
  , { name: "full-join",            query: fullJoinExample }
  , { name: "aggregation",          query: aggregation }
  , { name: "window-functions",     query: windowFunctions }
  , { name: "functions-and-casts",  query: functionsAndCasts }
  , { name: "exists",               query: existsExample }
  , { name: "not-exists",           query: notExistsExample }
  , { name: "subquery-in",          query: subqueryIn }
  , { name: "scalar-subquery",      query: scalarSubquery }
  , { name: "derived-table",        query: derivedTable }
  , { name: "derived-table-join",   query: derivedTableJoin }
  , { name: "set-operations",       query: setOperations }
  , { name: "common-table-expressions", query: commonTableExpressions }
  , { name: "recursive-cte",        query: recursiveCte }
  , { name: "pagination",           query: pagination }
  , { name: "composing-fragments",  query: composingFragments }
  , { name: "merging-queries",      query: mergingQueries }
  , { name: "raw-escape-hatch",     query: rawEscapeHatch }
  ]
