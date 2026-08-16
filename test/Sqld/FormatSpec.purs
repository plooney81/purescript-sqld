module Test.Sqld.FormatSpec where

import Prelude (Unit, discard, (#), (<>))
import Data.String (trim)
import Sqld.Core (JoinCondition(..), Literal(..))
import Sqld.Expr (and, bool, col, countStar, currentRow, exists, inSub, int, null, orderWindow, over, partitionBy', raw, rowNumber, rows, str, sub, tcol, unboundedPreceding, withFrame, (.==))
import Sqld.Format (format, formatInline, formatPretty)
import Sqld.Select (as, asc, cols, derived, desc, except, expr, from, fromAs, fromSub, joinRel, leftJoin, orderBy, select', star, starFrom, union, unionAll, where_, with_)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

formatSpec :: Spec Unit
formatSpec = describe "Sqld.Format" do

  describe "value rendering" do
    it "integer" do
      let query = select' [star]
            # from "t"
            # where_ (col "id" .== int 42)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"id\" = 42"

    it "string with single-quote escaping" do
      let query = select' [star]
            # from "t"
            # where_ (col "name" .== str "O'Brien")
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"name\" = 'O''Brien'"

    it "TRUE / FALSE" do
      let query = select' [star]
            # from "t"
            # where_ (col "active" .== bool true)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"active\" = TRUE"

    it "NULL" do
      let query = select' [star]
            # from "t"
            # where_ (col "x" .== null)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"x\" = NULL"

  describe "substitution order" do
    it "left-to-right across the whole query" do
      let query = select' [star]
            # from "t"
            # where_ (and [col "a" .== int 1, col "b" .== str "x", col "c" .== bool false])
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE (\"a\" = 1 AND \"b\" = 'x' AND \"c\" = FALSE)"

    it "JOIN ON values come before WHERE values" do
      let query = select' [star]
            # from "orders"
            # leftJoin "users" (col "user_id" .== int 99)
            # where_ (col "status" .== str "open")
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"orders\" LEFT JOIN \"users\" ON (\"user_id\" = 99) WHERE \"status\" = 'open'"

    -- A CROSS JOIN carries no condition of its own, but its target may be a
    -- derived table that carries parameters, and those still land where the
    -- relation does — ahead of the WHERE clause's.
    it "a cross-joined derived table's values come before WHERE values" do
      let paid = select' (cols ["user_id"])
            # from "orders"
            # where_ (col "status" .== str "paid")
          result = select' [star]
            # fromAs "users" "u"
            # joinRel (derived paid "paid") Cross
            # where_ (tcol "u" "active" .== bool true)
            # format
      result.sql `shouldEqual`
        "SELECT * FROM \"users\" AS \"u\" CROSS JOIN (SELECT \"user_id\" FROM \"orders\" WHERE \"status\" = $1) AS \"paid\" WHERE \"u\".\"active\" = $2"
      result.params `shouldEqual` [LitString "paid", LitBoolean true]

  describe "formatPretty" do
    it "clause per line" do
      let query = select' (cols ["id", "name"])
            # from "users"
            # where_ (col "id" .== int 42)
            # formatPretty
      query `shouldEqual` trim """
SELECT "id", "name"
FROM "users"
WHERE "id" = 42
"""

    it "scalar subquery in the select list" do
      let query = select'
            [ expr (tcol "u" "name")
            , as
                ( sub
                    ( select' [expr countStar]
                        # from "orders"
                        # where_ (tcol "orders" "user_id" .== tcol "u" "id")
                    )
                )
                "order_count"
            ]
            # fromAs "users" "u"
            # formatPretty
      query `shouldEqual` trim """
SELECT "u"."name", (
  SELECT COUNT(*)
  FROM "orders"
  WHERE "orders"."user_id" = "u"."id"
) AS "order_count"
FROM "users" AS "u"
"""

    it "EXISTS subquery" do
      let query = select' [star]
            # fromAs "users" "u"
            # where_
                ( exists
                    ( select' [expr (raw "1")]
                        # from "orders"
                        # where_ (tcol "orders" "user_id" .== tcol "u" "id")
                    )
                )
            # formatPretty
      query `shouldEqual` trim """
SELECT *
FROM "users" AS "u"
WHERE EXISTS (
  SELECT 1
  FROM "orders"
  WHERE "orders"."user_id" = "u"."id"
)
"""

    it "derived table in FROM" do
      let query = select' [starFrom "paid"]
            # fromSub
                ( select' (cols ["id", "total"])
                    # from "orders"
                    # where_ (col "status" .== str "paid")
                )
                "paid"
            # formatPretty
      query `shouldEqual` trim """
SELECT "paid".*
FROM (
  SELECT "id", "total"
  FROM "orders"
  WHERE "status" = 'paid'
) AS "paid"
"""

    it "indents one level per level of nesting" do
      let query = select' [starFrom "t"]
            # fromSub
                ( select' (cols ["id"])
                    # from "orders"
                    # where_
                        ( inSub (col "user_id")
                            ( select' (cols ["id"])
                                # from "users"
                                # where_ (col "active" .== bool true)
                            )
                        )
                )
                "t"
            # formatPretty
      query `shouldEqual` trim """
SELECT "t".*
FROM (
  SELECT "id"
  FROM "orders"
  WHERE "user_id" IN (
    SELECT "id"
    FROM "users"
    WHERE "active" = TRUE
  )
) AS "t"
"""

    it "CTE body gets an indented block of its own" do
      let query = select' [starFrom "paid"]
            # with_ "paid"
                ( select' (cols ["id", "total"])
                    # from "orders"
                    # where_ (col "status" .== str "paid")
                )
            # from "paid"
            # formatPretty
      query `shouldEqual` trim """
WITH "paid" AS (
  SELECT "id", "total"
  FROM "orders"
  WHERE "status" = 'paid'
)
SELECT "paid".*
FROM "paid"
"""

    it "one CTE per line" do
      let query = select' [star]
            # with_ "paid"
                ( select' (cols ["user_id"])
                    # from "orders"
                    # where_ (col "status" .== str "paid")
                )
            # with_ "recent"
                ( select' (cols ["user_id"])
                    # from "orders"
                )
            # from "paid"
            # formatPretty
      query `shouldEqual` trim """
WITH "paid" AS (
  SELECT "user_id"
  FROM "orders"
  WHERE "status" = 'paid'
),
"recent" AS (
  SELECT "user_id"
  FROM "orders"
)
SELECT *
FROM "paid"
"""

    it "set operation: one operand block per line" do
      let query = select' (cols ["id"])
            # from "users"
            # where_ (col "active" .== bool true)
            # unionAll (select' (cols ["user_id"]) # from "orders")
            # orderBy [asc (col "id")]
            # formatPretty
      query `shouldEqual` trim """
(
  SELECT "id"
  FROM "users"
  WHERE "active" = TRUE
)
UNION ALL
(
  SELECT "user_id"
  FROM "orders"
)
ORDER BY "id" ASC
"""

    it "set operation: a chained operand indents one level further" do
      let query = select' (cols ["id"])
            # from "a"
            # union (select' (cols ["id"]) # from "b")
            # except (select' (cols ["id"]) # from "c")
            # formatPretty
      query `shouldEqual` trim """
(
  (
    SELECT "id"
    FROM "a"
  )
  UNION
  (
    SELECT "id"
    FROM "b"
  )
)
EXCEPT
(
  SELECT "id"
  FROM "c"
)
"""

    -- A window is part of an expression rather than a clause of its own, so it
    -- stays on one line however deeply the query is broken up.
    it "a window stays on one line" do
      let window = partitionBy' [col "department"]
            # orderWindow [desc (col "age")]
            # withFrame (rows unboundedPreceding currentRow)
          query = select' (cols ["name"] <> [as (rowNumber `over` window) "rn"])
            # from "users"
            # where_ (col "active" .== bool true)
            # formatPretty
      query `shouldEqual` trim """
SELECT "name", ROW_NUMBER() OVER (PARTITION BY "department" ORDER BY "age" DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "rn"
FROM "users"
WHERE "active" = TRUE
"""

    it "leaves formatInline on one line" do
      let query = select' [star]
            # from "users"
            # where_
                ( inSub (col "id")
                    (select' (cols ["user_id"]) # from "orders")
                )
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"users\" WHERE \"id\" IN (SELECT \"user_id\" FROM \"orders\")"

  describe "integration" do
    it "multi-column select with WHERE" do
      let query = select' (cols ["id", "name", "email"])
            # from "users"
            # where_ (col "id" .== int 42)
            # formatInline
      query `shouldEqual` "SELECT \"id\", \"name\", \"email\" FROM \"users\" WHERE \"id\" = 42"
