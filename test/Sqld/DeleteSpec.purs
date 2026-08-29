module Test.Sqld.DeleteSpec where

import Prelude (Unit, discard, (#))
import Sqld.Core (Literal(..))
import Sqld.Expr (bool, col, int, str, tcol, (.==), (.>))
import Sqld.Format (formatDeleteStmt, formatDeleteInline)
import Sqld.Select (as, cols, deleteFrom, deleteReturning, deleteWhere, star, using)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

deleteSpec :: Spec Unit
deleteSpec = describe "DELETE" do

  describe "basic DELETE" do
    it "delete all rows" do
      let sql = deleteFrom "orders"
            # formatDeleteInline
      sql `shouldEqual`
        "DELETE FROM \"orders\""

    it "delete with WHERE" do
      let sql = deleteFrom "orders"
            # deleteWhere (col "status" .== str "cancelled")
            # formatDeleteInline
      sql `shouldEqual`
        "DELETE FROM \"orders\" WHERE \"status\" = 'cancelled'"

    it "parameterised format" do
      let fq = deleteFrom "orders"
            # deleteWhere (col "status" .== str "cancelled")
            # formatDeleteStmt
      fq.sql `shouldEqual`
        "DELETE FROM \"orders\" WHERE \"status\" = $1"
      fq.params `shouldEqual` [LitString "cancelled"]

  describe "DELETE ... USING" do
    it "joins another table" do
      let sql = deleteFrom "orders"
            # using ["users"]
            # deleteWhere (tcol "orders" "user_id" .== tcol "users" "id")
            # formatDeleteInline
      sql `shouldEqual`
        "DELETE FROM \"orders\" USING \"users\" WHERE \"orders\".\"user_id\" = \"users\".\"id\""

    it "joins multiple tables" do
      let sql = deleteFrom "orders"
            # using ["users", "profiles"]
            # deleteWhere (tcol "orders" "user_id" .== tcol "users" "id")
            # formatDeleteInline
      sql `shouldEqual`
        "DELETE FROM \"orders\" USING \"users\", \"profiles\" WHERE \"orders\".\"user_id\" = \"users\".\"id\""

  describe "DELETE without WHERE" do
    it "deletes every row" do
      let sql = deleteFrom "users"
            # formatDeleteInline
      sql `shouldEqual`
        "DELETE FROM \"users\""

  describe "RETURNING" do
    it "returns specific columns" do
      let sql = deleteFrom "orders"
            # deleteWhere (col "status" .== str "cancelled")
            # deleteReturning (cols ["id", "status"])
            # formatDeleteInline
      sql `shouldEqual`
        "DELETE FROM \"orders\" WHERE \"status\" = 'cancelled' RETURNING \"id\", \"status\""

    it "returns star" do
      let sql = deleteFrom "orders"
            # deleteWhere (col "id" .== int 1)
            # deleteReturning [star]
            # formatDeleteInline
      sql `shouldEqual`
        "DELETE FROM \"orders\" WHERE \"id\" = 1 RETURNING *"

    it "returns aliased expression" do
      let sql = deleteFrom "orders"
            # deleteWhere (col "id" .== int 1)
            # deleteReturning [as (col "id") "deleted_id"]
            # formatDeleteInline
      sql `shouldEqual`
        "DELETE FROM \"orders\" WHERE \"id\" = 1 RETURNING \"id\" AS \"deleted_id\""

  describe "parameter ordering" do
    it "USING before WHERE before RETURNING" do
      let fq = deleteFrom "orders"
            # using ["users"]
            # deleteWhere (tcol "orders" "user_id" .== tcol "users" "id")
            # deleteWhere (tcol "users" "active" .== bool false)
            # deleteReturning (cols ["orders.id"])
            # formatDeleteStmt
      fq.sql `shouldEqual`
        "DELETE FROM \"orders\" USING \"users\" WHERE (\"orders\".\"user_id\" = \"users\".\"id\" AND \"users\".\"active\" = $1) RETURNING \"orders\".\"id\""
      fq.params `shouldEqual` [LitBoolean false]

  describe "full DELETE" do
    it "DELETE FROM ... USING ... WHERE ... RETURNING" do
      let fq = deleteFrom "orders"
            # using ["users"]
            # deleteWhere (tcol "orders" "user_id" .== tcol "users" "id")
            # deleteWhere (tcol "users" "active" .== bool false)
            # deleteReturning (cols ["orders.id"])
            # formatDeleteStmt
      fq.sql `shouldEqual`
        "DELETE FROM \"orders\" USING \"users\" WHERE (\"orders\".\"user_id\" = \"users\".\"id\" AND \"users\".\"active\" = $1) RETURNING \"orders\".\"id\""
      fq.params `shouldEqual` [LitBoolean false]

    it "multiple WHERE conditions with parameters" do
      let fq = deleteFrom "orders"
            # using ["users"]
            # deleteWhere (tcol "orders" "user_id" .== tcol "users" "id")
            # deleteWhere (tcol "orders" "total" .> int 100)
            # deleteWhere (tcol "users" "active" .== bool false)
            # deleteReturning (cols ["orders.id", "orders.total"])
            # formatDeleteStmt
      fq.sql `shouldEqual`
        "DELETE FROM \"orders\" USING \"users\" WHERE ((\"orders\".\"user_id\" = \"users\".\"id\" AND \"orders\".\"total\" > $1) AND \"users\".\"active\" = $2) RETURNING \"orders\".\"id\", \"orders\".\"total\""
      fq.params `shouldEqual` [LitInt 100, LitBoolean false]
