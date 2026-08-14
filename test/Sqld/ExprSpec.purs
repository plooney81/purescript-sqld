module Test.Sqld.ExprSpec where

import Prelude (Unit, discard, (#))
import Sqld.Core (Literal(..), emptyQuery)
import Sqld.Expr (and, between, binOp, bool, cast, coalesce, col, count, countStar, exists, in_, inSub, int, isNotNull, isNull, like, not, notIn, or, raw, str, sub, upper, (.!=), (.==), (.>), (.>=))
import Sqld.Format (format, formatInline)
import Sqld.Select (as, expr, from, select, star, where_)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

exprSpec :: Spec Unit
exprSpec = describe "Sqld.Expr" do

  describe "comparison operators" do
    it "equality with int" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (col "id" .== int 42)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"id\" = 42"

    it "equality with boolean" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (col "active" .== bool true)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"active\" = TRUE"

    it "equality with string" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (col "role" .== str "admin")
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"role\" = 'admin'"

    it "inequality" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (col "status" .!= str "deleted")
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"status\" <> 'deleted'"

    it "greater-than" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (col "age" .> int 18)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"age\" > 18"

    it "greater-than-or-equal" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (col "score" .>= int 100)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"score\" >= 100"

    it "IS NULL" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (isNull (col "deleted_at"))
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"deleted_at\" IS NULL"

    it "IS NOT NULL" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (isNotNull (col "email"))
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"email\" IS NOT NULL"

    it "NOT" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (not (col "deleted" .== bool true))
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE NOT \"deleted\" = TRUE"

    it "raw passthrough" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (raw "created_at > NOW() - INTERVAL '7 days'")
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE created_at > NOW() - INTERVAL '7 days'"

  describe "AND / OR" do
    it "and of multiple conditions" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (and [col "a" .== int 1, col "b" .== int 2, col "c" .== int 3])
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE (\"a\" = 1 AND \"b\" = 2 AND \"c\" = 3)"

    it "or of multiple conditions" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (or [col "x" .== int 1, col "x" .== int 2])
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE (\"x\" = 1 OR \"x\" = 2)"

    it "nested AND inside OR" do
      let query = emptyQuery
            # select [star]
            # from "users"
            # where_
                (and [ or [col "status" .== str "active", col "status" .== str "pending"]
                     , col "age" .>= int 18
                     ])
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"users\" WHERE ((\"status\" = 'active' OR \"status\" = 'pending') AND \"age\" >= 18)"

    it "empty and produces TRUE" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (and [])
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE TRUE"

    it "empty or produces FALSE" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (or [])
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE FALSE"

  describe "IN / NOT IN / BETWEEN / LIKE" do
    it "IN list" do
      let query = emptyQuery
            # select [star]
            # from "products"
            # where_ ((col "category_id") `in_` [int 1, int 2, int 3])
            # formatInline
      query `shouldEqual` "SELECT * FROM \"products\" WHERE \"category_id\" IN (1, 2, 3)"

    it "NOT IN list" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ ((col "status") `notIn` [str "deleted", str "banned"])
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"status\" NOT IN ('deleted', 'banned')"

    it "BETWEEN" do
      let query = emptyQuery
            # select [star]
            # from "orders"
            # where_ (between (col "total") (int 100) (int 500))
            # formatInline
      query `shouldEqual` "SELECT * FROM \"orders\" WHERE \"total\" BETWEEN 100 AND 500"

    it "LIKE" do
      let query = emptyQuery
            # select [star]
            # from "users"
            # where_ (like (col "email") "%@example.com")
            # formatInline
      query `shouldEqual` "SELECT * FROM \"users\" WHERE \"email\" LIKE '%@example.com'"

  describe "function application" do
    it "COUNT(*)" do
      let query = emptyQuery
            # select [as countStar "n"]
            # from "t"
            # formatInline
      query `shouldEqual` "SELECT COUNT(*) AS \"n\" FROM \"t\""

    it "function of a column" do
      let query = emptyQuery
            # select [expr (count (col "id"))]
            # from "t"
            # formatInline
      query `shouldEqual` "SELECT COUNT(\"id\") FROM \"t\""

    it "nested application with multiple arguments" do
      let query = emptyQuery
            # select [as (upper (coalesce [col "email", str "none"])) "e"]
            # from "t"
            # formatInline
      query `shouldEqual` "SELECT UPPER(COALESCE(\"email\", 'none')) AS \"e\" FROM \"t\""

  describe "operator precedence" do
    -- The parentheses below are the whole point: PostgreSQL accepts both
    -- "age" + 1 * 2 and ("age" + 1) * 2, and they mean different things.
    it "brackets a looser-binding left operand" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (binOp "*" (binOp "+" (col "age") (int 1)) (int 2) .> int 10)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE (\"age\" + 1) * 2 > 10"

    it "omits brackets when precedence already agrees" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (binOp "+" (col "a") (binOp "*" (col "b") (int 2)) .> int 3)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"a\" + \"b\" * 2 > 3"

    -- Left-associativity: a - (b - c) is not a - b - c.
    it "brackets an equal-precedence right operand" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (binOp "-" (col "a") (binOp "-" (col "b") (col "c")) .> int 0)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"a\" - (\"b\" - \"c\") > 0"

    it "treats an unknown operator as a generic one" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (binOp "@>" (col "tags") (raw "ARRAY['a']"))
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"tags\" @> ARRAY['a']"

  describe "casts" do
    it "atom operand needs no brackets" do
      let query = emptyQuery
            # select [as (cast (col "id") "text") "id_text"]
            # from "t"
            # formatInline
      query `shouldEqual` "SELECT \"id\"::text AS \"id_text\" FROM \"t\""

    it "compound operand is bracketed" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (cast (binOp "+" (col "age") (int 1)) "numeric" .> int 2)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE (\"age\" + 1)::numeric > 2"

  describe "subqueries" do
    it "scalar subquery in the select list" do
      let orders = emptyQuery # select [expr countStar] # from "orders"
          query = emptyQuery
            # select [expr (col "id"), as (sub orders) "n"]
            # from "users"
            # formatInline
      query `shouldEqual`
        "SELECT \"id\", (SELECT COUNT(*) FROM \"orders\") AS \"n\" FROM \"users\""

    it "IN with a subquery" do
      let orders = emptyQuery # select [expr (col "user_id")] # from "orders"
          query = emptyQuery
            # select [star]
            # from "users"
            # where_ (inSub (col "id") orders)
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"users\" WHERE \"id\" IN (SELECT \"user_id\" FROM \"orders\")"

    it "EXISTS" do
      let orders = emptyQuery # select [expr (raw "1")] # from "orders"
          query = emptyQuery
            # select [star]
            # from "users"
            # where_ (exists orders)
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"users\" WHERE EXISTS (SELECT 1 FROM \"orders\")"

    -- A subquery must not restart parameter numbering, or the driver receives
    -- the bindings in the wrong order.
    it "parameters interleave with the outer query" do
      let orders = emptyQuery
            # select [expr (col "user_id")]
            # from "orders"
            # where_ (col "status" .== str "paid")
          result = emptyQuery
            # select [star]
            # from "users"
            # where_ (and [ col "active" .== bool true
                          , inSub (col "id") orders
                          , col "age" .> int 21
                          ])
            # format
      result.sql `shouldEqual`
        "SELECT * FROM \"users\" WHERE (\"active\" = $1 AND \"id\" IN (SELECT \"user_id\" FROM \"orders\" WHERE \"status\" = $2) AND \"age\" > $3)"
      result.params `shouldEqual` [LitBoolean true, LitString "paid", LitInt 21]
