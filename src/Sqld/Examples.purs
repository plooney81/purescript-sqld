module Sqld.Examples where

import Prelude
import Sqld.Core (FormattedQuery, Query, emptyQuery)
import Sqld.Builder
import Sqld.Format (format)

-- ---------------------------------------------------------------------------
-- Example 1: Simple column select with WHERE
-- ---------------------------------------------------------------------------
-- SELECT "id", "name", "email" FROM "users" WHERE "id" = $1
-- params: [LitInt 42]

example1 :: FormattedQuery
example1 = format $ emptyQuery
  # select [s (col "id"), s (col "name"), s (col "email")]
  # from "users"
  # where_ (col "id" .== int 42)

-- ---------------------------------------------------------------------------
-- Example 2: JOIN with aliased tables
-- ---------------------------------------------------------------------------
-- SELECT "u"."id", "p"."bio" FROM "users" "u"
--   LEFT JOIN "profiles" "p" ON ("u"."id" = "p"."user_id")
--   WHERE "u"."active" = $1
--   ORDER BY "u"."created_at" DESC LIMIT 20

example2 :: FormattedQuery
example2 = format $ emptyQuery
  # select [s (tcol "u" "id"), s (tcol "p" "bio")]
  # fromAs "users" "u"
  # leftJoinAs "profiles" "p" (tcol "u" "id" .== tcol "p" "user_id")
  # where_ (tcol "u" "active" .== bool true)
  # orderBy [desc (tcol "u" "created_at")]
  # limit 20

-- ---------------------------------------------------------------------------
-- Example 3: Composable query fragments — the HoneySQL superpower
-- ---------------------------------------------------------------------------

baseUserQuery :: Query -> Query
baseUserQuery = select [star] >>> from "users"

activeOnly :: Query -> Query
activeOnly = where_ (col "active" .== bool true)

paginate :: Int -> Int -> Query -> Query
paginate pageSize page = limit pageSize >>> offset (pageSize * page)

-- Usage: format $ baseUserQuery >>> activeOnly >>> paginate 10 2 $ emptyQuery

-- ---------------------------------------------------------------------------
-- Example 4: Nested AND/OR
-- ---------------------------------------------------------------------------
-- WHERE (("status" = $1 OR "status" = $2) AND "age" >= $3)

example4 :: FormattedQuery
example4 = format $ emptyQuery
  # from "users"
  # where_
      (and_
        [ or_ [ col "status" .== str "active"
              , col "status" .== str "pending" ]
        , col "age" .>= int 18
        ])

-- ---------------------------------------------------------------------------
-- Example 5: IN clause
-- ---------------------------------------------------------------------------

example5 :: FormattedQuery
example5 = format $ emptyQuery
  # select [star]
  # from "products"
  # where_ (in_ (col "category_id") [int 1, int 2, int 3])
  # orderBy [asc (col "name")]

-- ---------------------------------------------------------------------------
-- Example 6: Aggregation with GROUP BY / HAVING
-- ---------------------------------------------------------------------------
-- SELECT "department", COUNT(*) AS "headcount" FROM "employees"
--   GROUP BY "department" HAVING COUNT(*) > $1 ORDER BY "headcount" DESC

example6 :: FormattedQuery
example6 = format $ emptyQuery
  # select [ s (col "department")
           , as (raw "COUNT(*)") "headcount" ]
  # from "employees"
  # groupBy [col "department"]
  # having (raw "COUNT(*)" .> int 5)
  # orderBy [desc (col "headcount")]
