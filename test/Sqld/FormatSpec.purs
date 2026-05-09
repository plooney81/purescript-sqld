module Test.Sqld.FormatSpec where

import Prelude hiding (not, between)
import Sqld.Core (emptyQuery)
import Sqld.Expr
import Sqld.Format (formatInline)
import Sqld.Select
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

formatSpec :: Spec Unit
formatSpec = describe "Sqld.Format" do

  describe "value rendering" do
    it "integer" do
      formatInline (emptyQuery # select [star] # from "t" # where_ (col "id" .== int 42))
        `shouldEqual` "SELECT * FROM \"t\" WHERE \"id\" = 42"

    it "string with single-quote escaping" do
      formatInline (emptyQuery # select [star] # from "t" # where_ (col "name" .== str "O'Brien"))
        `shouldEqual` "SELECT * FROM \"t\" WHERE \"name\" = 'O''Brien'"

    it "TRUE / FALSE" do
      formatInline (emptyQuery # select [star] # from "t" # where_ (col "active" .== bool true))
        `shouldEqual` "SELECT * FROM \"t\" WHERE \"active\" = TRUE"

    it "NULL" do
      formatInline (emptyQuery # select [star] # from "t" # where_ (col "x" .== null))
        `shouldEqual` "SELECT * FROM \"t\" WHERE \"x\" = NULL"

  describe "substitution order" do
    it "left-to-right across the whole query" do
      formatInline
        ( emptyQuery # select [star] # from "t"
            # where_ (and [col "a" .== int 1, col "b" .== str "x", col "c" .== bool false])
        )
        `shouldEqual` "SELECT * FROM \"t\" WHERE (\"a\" = 1 AND \"b\" = 'x' AND \"c\" = FALSE)"

    it "JOIN ON values come before WHERE values" do
      formatInline
        ( emptyQuery # select [star] # from "orders"
            # leftJoin "users" (col "user_id" .== int 99)
            # where_ (col "status" .== str "open")
        )
        `shouldEqual`
          "SELECT * FROM \"orders\" LEFT JOIN \"users\" ON (\"user_id\" = 99) WHERE \"status\" = 'open'"

  describe "integration" do
    it "multi-column select with WHERE" do
      formatInline
        ( emptyQuery
            # select (cols ["id", "name", "email"])
            # from "users"
            # where_ (col "id" .== int 42)
        )
        `shouldEqual` "SELECT \"id\", \"name\", \"email\" FROM \"users\" WHERE \"id\" = 42"
