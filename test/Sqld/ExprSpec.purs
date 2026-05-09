module Test.Sqld.ExprSpec where

import Prelude hiding (not, between)
import Sqld.Core (emptyQuery)
import Sqld.Expr
import Sqld.Format (formatInline)
import Sqld.Select (from, select, star, where_)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

q :: String -> _
q table = emptyQuery # select [star] # from table

exprSpec :: Spec Unit
exprSpec = describe "Sqld.Expr" do

  describe "comparison operators" do
    it "equality with int" do
      formatInline (q "t" # where_ (col "id" .== int 42))
        `shouldEqual` "SELECT * FROM \"t\" WHERE \"id\" = 42"

    it "equality with boolean" do
      formatInline (q "t" # where_ (col "active" .== bool true))
        `shouldEqual` "SELECT * FROM \"t\" WHERE \"active\" = TRUE"

    it "equality with string" do
      formatInline (q "t" # where_ (col "role" .== str "admin"))
        `shouldEqual` "SELECT * FROM \"t\" WHERE \"role\" = 'admin'"

    it "inequality" do
      formatInline (q "t" # where_ (col "status" .!= str "deleted"))
        `shouldEqual` "SELECT * FROM \"t\" WHERE \"status\" <> 'deleted'"

    it "greater-than" do
      formatInline (q "t" # where_ (col "age" .> int 18))
        `shouldEqual` "SELECT * FROM \"t\" WHERE \"age\" > 18"

    it "greater-than-or-equal" do
      formatInline (q "t" # where_ (col "score" .>= int 100))
        `shouldEqual` "SELECT * FROM \"t\" WHERE \"score\" >= 100"

    it "IS NULL" do
      formatInline (q "t" # where_ (isNull (col "deleted_at")))
        `shouldEqual` "SELECT * FROM \"t\" WHERE \"deleted_at\" IS NULL"

    it "IS NOT NULL" do
      formatInline (q "t" # where_ (isNotNull (col "email")))
        `shouldEqual` "SELECT * FROM \"t\" WHERE \"email\" IS NOT NULL"

    it "NOT" do
      formatInline (q "t" # where_ (not (col "deleted" .== bool true)))
        `shouldEqual` "SELECT * FROM \"t\" WHERE NOT \"deleted\" = TRUE"

    it "raw passthrough" do
      formatInline (q "t" # where_ (raw "created_at > NOW() - INTERVAL '7 days'"))
        `shouldEqual` "SELECT * FROM \"t\" WHERE created_at > NOW() - INTERVAL '7 days'"

  describe "AND / OR" do
    it "and of multiple conditions" do
      formatInline (q "t" # where_ (and [col "a" .== int 1, col "b" .== int 2, col "c" .== int 3]))
        `shouldEqual` "SELECT * FROM \"t\" WHERE (\"a\" = 1 AND \"b\" = 2 AND \"c\" = 3)"

    it "or of multiple conditions" do
      formatInline (q "t" # where_ (or [col "x" .== int 1, col "x" .== int 2]))
        `shouldEqual` "SELECT * FROM \"t\" WHERE (\"x\" = 1 OR \"x\" = 2)"

    it "nested AND inside OR" do
      formatInline
        ( q "users" # where_
            (and [ or [col "status" .== str "active", col "status" .== str "pending"]
                 , col "age" .>= int 18
                 ])
        )
        `shouldEqual`
          "SELECT * FROM \"users\" WHERE ((\"status\" = 'active' OR \"status\" = 'pending') AND \"age\" >= 18)"

    it "empty and produces TRUE" do
      formatInline (q "t" # where_ (and []))
        `shouldEqual` "SELECT * FROM \"t\" WHERE TRUE"

    it "empty or produces FALSE" do
      formatInline (q "t" # where_ (or []))
        `shouldEqual` "SELECT * FROM \"t\" WHERE FALSE"

  describe "IN / NOT IN / BETWEEN / LIKE" do
    it "IN list" do
      formatInline (q "products" # where_ (in_ (col "category_id") [int 1, int 2, int 3]))
        `shouldEqual` "SELECT * FROM \"products\" WHERE \"category_id\" IN (1, 2, 3)"

    it "NOT IN list" do
      formatInline (q "t" # where_ (notIn (col "status") [str "deleted", str "banned"]))
        `shouldEqual` "SELECT * FROM \"t\" WHERE \"status\" NOT IN ('deleted', 'banned')"

    it "BETWEEN" do
      formatInline (q "orders" # where_ (between (col "total") (int 100) (int 500)))
        `shouldEqual` "SELECT * FROM \"orders\" WHERE \"total\" BETWEEN 100 AND 500"

    it "LIKE" do
      formatInline (q "users" # where_ (like (col "email") "%@example.com"))
        `shouldEqual` "SELECT * FROM \"users\" WHERE \"email\" LIKE '%@example.com'"
