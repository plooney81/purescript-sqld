module Test.Sqld.FormatSpec where

import Prelude (Unit, discard, (#))
import Sqld.Core (emptyQuery)
import Sqld.Expr (and, bool, col, int, null, str, (.==))
import Sqld.Format (formatInline)
import Sqld.Select (cols, from, leftJoin, select, star, where_)
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

  describe "integration" do
    it "multi-column select with WHERE" do
      let query = emptyQuery
            # select (cols ["id", "name", "email"])
            # from "users"
            # where_ (col "id" .== int 42)
            # formatInline
      query `shouldEqual` "SELECT \"id\", \"name\", \"email\" FROM \"users\" WHERE \"id\" = 42"
