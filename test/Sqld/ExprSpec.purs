module Test.Sqld.ExprSpec where

import Prelude (Unit, discard, (#))
import Sqld.Core (emptyQuery)
import Sqld.Expr (and, between, bool, col, in_, int, isNotNull, isNull, like, not, notIn, or, raw, str, (.!=), (.==), (.>), (.>=))
import Sqld.Format (formatInline)
import Sqld.Select (from, select, star, where_)
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
