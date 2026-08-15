module Test.Sqld.FormatSpec where

import Prelude (Unit, discard, (#))
import Data.String (trim)
import Sqld.Core (emptyQuery)
import Sqld.Expr (and, bool, col, countStar, exists, inSub, int, null, raw, str, sub, tcol, (.==))
import Sqld.Format (formatInline, formatPretty)
import Sqld.Select (as, cols, expr, from, fromAs, fromSub, leftJoin, select, star, starFrom, where_)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

formatSpec :: Spec Unit
formatSpec = describe "Sqld.Format" do

  describe "value rendering" do
    it "integer" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (col "id" .== int 42)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"id\" = 42"

    it "string with single-quote escaping" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (col "name" .== str "O'Brien")
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"name\" = 'O''Brien'"

    it "TRUE / FALSE" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (col "active" .== bool true)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"active\" = TRUE"

    it "NULL" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (col "x" .== null)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"x\" = NULL"

  describe "substitution order" do
    it "left-to-right across the whole query" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (and [col "a" .== int 1, col "b" .== str "x", col "c" .== bool false])
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE (\"a\" = 1 AND \"b\" = 'x' AND \"c\" = FALSE)"

    it "JOIN ON values come before WHERE values" do
      let query = emptyQuery
            # select [star]
            # from "orders"
            # leftJoin "users" (col "user_id" .== int 99)
            # where_ (col "status" .== str "open")
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"orders\" LEFT JOIN \"users\" ON (\"user_id\" = 99) WHERE \"status\" = 'open'"

  describe "formatPretty" do
    it "clause per line" do
      let query = emptyQuery
            # select (cols ["id", "name"])
            # from "users"
            # where_ (col "id" .== int 42)
            # formatPretty
      query `shouldEqual` trim """
SELECT "id", "name"
FROM "users"
WHERE "id" = 42
"""

    it "scalar subquery in the select list" do
      let query = emptyQuery
            # select
                [ expr (tcol "u" "name")
                , as
                    ( sub
                        ( emptyQuery
                            # select [expr countStar]
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
      let query = emptyQuery
            # select [star]
            # fromAs "users" "u"
            # where_
                ( exists
                    ( emptyQuery
                        # select [expr (raw "1")]
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
      let query = emptyQuery
            # select [starFrom "paid"]
            # fromSub
                ( emptyQuery
                    # select (cols ["id", "total"])
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
      let query = emptyQuery
            # select [starFrom "t"]
            # fromSub
                ( emptyQuery
                    # select (cols ["id"])
                    # from "orders"
                    # where_
                        ( inSub (col "user_id")
                            ( emptyQuery
                                # select (cols ["id"])
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

    it "leaves formatInline on one line" do
      let query = emptyQuery
            # select [star]
            # from "users"
            # where_
                ( inSub (col "id")
                    (emptyQuery # select (cols ["user_id"]) # from "orders")
                )
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"users\" WHERE \"id\" IN (SELECT \"user_id\" FROM \"orders\")"

  describe "integration" do
    it "multi-column select with WHERE" do
      let query = emptyQuery
            # select (cols ["id", "name", "email"])
            # from "users"
            # where_ (col "id" .== int 42)
            # formatInline
      query `shouldEqual` "SELECT \"id\", \"name\", \"email\" FROM \"users\" WHERE \"id\" = 42"
