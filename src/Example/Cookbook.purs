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
import Sqld.Core (JoinType(..), Query, emptyQuery)
import Sqld.Expr (and, avg, between, binOp, bool, cast, coalesce, col, count, countStar, exists, ilike, in_, inSub, int, isNotNull, isNull, like, not, notExists, num, or, raw, str, sub, tcol, (.<), (.==), (.>), (.>=))
import Sqld.Select (as, asc, colAs, cols, derived, desc, expr, from, fromAs, fromSub, fullJoinAs, groupBy, having, innerJoinAs, joinOn, leftJoinAs, limit, mergeQueries, offset, orderBy, rightJoin, select, star, starFrom, where_)

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
  emptyQuery
    # select (cols [ "id", "name", "email" ])
    # from "users"
    # where_ (col "active" .== bool true)

-- #example combining-conditions
-- # Combining conditions
-- `and` and `or` nest freely and bracket themselves, so the emitted SQL means
-- what the structure says. Calling `where_` twice ANDs rather than replaces.
combiningConditions :: Query
combiningConditions =
  emptyQuery
    # select [ star ]
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
  emptyQuery
    # select [ expr (col "id"), as (coalesce [ col "email", str "(none)" ]) "email" ]
    # from "users"
    # where_ (and [ isNotNull (col "name"), isNull (col "department") ])

-- #example pattern-matching
-- # Pattern matching and ranges
-- `like` is case-sensitive, `ilike` is not. `between` is inclusive at both ends.
patternMatching :: Query
patternMatching =
  emptyQuery
    # select [ star ]
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
joins :: Query
joins =
  emptyQuery
    # select [ expr (tcol "u" "name"), expr (tcol "p" "bio") ]
    # fromAs "users" "u"
    # leftJoinAs "profiles" "p" (tcol "u" "id" .== tcol "p" "user_id")
    # innerJoinAs "orders" "o" (and [ tcol "u" "id" .== tcol "o" "user_id", tcol "o" "status" .== str "paid" ])

-- #example right-join
-- # Right joins
-- Keeps every row of the right-hand relation. `starFrom` selects every column
-- of one relation.
rightJoinExample :: Query
rightJoinExample =
  emptyQuery
    # select [ starFrom "profiles" ]
    # from "users"
    # rightJoin "profiles" (tcol "users" "id" .== tcol "profiles" "user_id")

-- #example full-join
-- # Full joins
-- Keeps unmatched rows from both sides.
fullJoinExample :: Query
fullJoinExample =
  emptyQuery
    # select [ expr (tcol "u" "name"), expr (tcol "p" "bio") ]
    # fromAs "users" "u"
    # fullJoinAs "profiles" "p" (tcol "u" "id" .== tcol "p" "user_id")

-- #example aggregation
-- # Aggregation
-- `countStar` is `COUNT(*)`; `having` filters the groups. Ordering by an output
-- alias works exactly as it does in SQL.
aggregation :: Query
aggregation =
  emptyQuery
    # select
        [ expr (col "department")
        , as countStar "headcount"
        , as (count (col "email")) "with_email"
        , as (avg (col "age")) "mean_age"
        ]
    # from "users"
    # where_ (col "active" .== bool true)
    # groupBy [ col "department" ]
    # having (countStar .> int 3)
    # orderBy [ desc (col "headcount") ]

-- #example functions-and-casts
-- # Functions, casts and arbitrary operators
-- `app` reaches any function PostgreSQL knows, `binOp` any operator, and `cast`
-- any type — so an unsupported feature rarely means falling back to `raw`.
-- Brackets appear only where precedence demands them.
functionsAndCasts :: Query
functionsAndCasts =
  emptyQuery
    # select
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
  emptyQuery
    # select [ star ]
    # fromAs "users" "u"
    # where_
        ( exists
            ( emptyQuery
                # select [ expr (raw "1") ]
                # from "orders"
                # where_ (and [ tcol "orders" "user_id" .== tcol "u" "id", tcol "orders" "status" .== str "paid" ])
            )
        )

-- #example not-exists
-- # NOT EXISTS
-- The natural way to ask "rows with nothing related" — here, users who have
-- never ordered.
notExistsExample :: Query
notExistsExample =
  emptyQuery
    # select [ expr (tcol "u" "id"), expr (tcol "u" "name") ]
    # fromAs "users" "u"
    # where_
        ( notExists
            ( emptyQuery
                # select [ expr (raw "1") ]
                # from "orders"
                # where_ (tcol "orders" "user_id" .== tcol "u" "id")
            )
        )

-- #example subquery-in
-- # IN (SELECT …)
-- `inSub` takes a whole query as the right operand. Parameters inside it are
-- numbered in step with the outer query.
subqueryIn :: Query
subqueryIn =
  emptyQuery
    # select [ star ]
    # from "users"
    # where_
        ( inSub (col "id")
            ( emptyQuery
                # select [ expr (col "user_id") ]
                # from "orders"
                # where_ (col "total" .> num 100.0)
            )
        )

-- #example scalar-subquery
-- # Scalar subqueries
-- A subquery in the select list, correlated against the outer row.
scalarSubquery :: Query
scalarSubquery =
  emptyQuery
    # select
        [ expr (tcol "u" "name")
        , as
            ( sub
                ( emptyQuery
                    # select [ expr countStar ]
                    # from "orders"
                    # where_ (tcol "orders" "user_id" .== tcol "u" "id")
                )
            )
            "order_count"
        ]
    # fromAs "users" "u"

-- #example derived-table
-- # Derived tables
-- A subquery in `FROM`. The alias is mandatory because PostgreSQL requires one,
-- so the type asks for a `String` rather than a `Maybe String`. Parameters
-- inside the subquery are numbered before the outer query's.
derivedTable :: Query
derivedTable =
  emptyQuery
    # select [ starFrom "paid" ]
    # fromSub
        ( emptyQuery
            # select (cols [ "id", "user_id", "total" ])
            # from "orders"
            # where_ (col "status" .== str "paid")
        )
        "paid"
    # where_ (tcol "paid" "total" .> num 100.0)

-- #example derived-table-join
-- # Joining a derived table
-- `joinOn` takes a `Relation`, so `derived` lets you join against a subquery —
-- here, per-user totals computed once and joined back.
derivedTableJoin :: Query
derivedTableJoin =
  emptyQuery
    # select [ expr (tcol "u" "name"), expr (tcol "totals" "order_count") ]
    # fromAs "users" "u"
    # joinOn InnerJoin
        ( derived
            ( emptyQuery
                # select [ expr (col "user_id"), as countStar "order_count" ]
                # from "orders"
                # groupBy [ col "user_id" ]
            )
            "totals"
        )
        (tcol "u" "id" .== tcol "totals" "user_id")

-- #example pagination
-- # Pagination
-- Builders are plain `Query -> Query` functions, so a pagination helper is
-- ordinary composition rather than anything the library needs to know about.
paginate :: Int -> Int -> Query -> Query
paginate pageSize page = limit pageSize >>> offset (pageSize * page)

pagination :: Query
pagination =
  emptyQuery
    # select (cols [ "id", "title" ])
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
    (emptyQuery # select [ star ] # from "users" # where_ (col "active" .== bool true))
    (emptyQuery # where_ (col "age" .< int 30) # limit 10)

-- #example raw-escape-hatch
-- # The raw escape hatch
-- For SQL the builders do not reach. `raw` is emitted verbatim: it is not
-- quoted, not parameterised, and not bracketed, so never build one from user
-- input. Reach for `app` and `binOp` first.
rawEscapeHatch :: Query
rawEscapeHatch =
  emptyQuery
    # select [ colAs "id" "id", as (raw "date_trunc('month', \"created_at\")") "month" ]
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
  , { name: "functions-and-casts",  query: functionsAndCasts }
  , { name: "exists",               query: existsExample }
  , { name: "not-exists",           query: notExistsExample }
  , { name: "subquery-in",          query: subqueryIn }
  , { name: "scalar-subquery",      query: scalarSubquery }
  , { name: "derived-table",        query: derivedTable }
  , { name: "derived-table-join",   query: derivedTableJoin }
  , { name: "pagination",           query: pagination }
  , { name: "composing-fragments",  query: composingFragments }
  , { name: "merging-queries",      query: mergingQueries }
  , { name: "raw-escape-hatch",     query: rawEscapeHatch }
  ]
