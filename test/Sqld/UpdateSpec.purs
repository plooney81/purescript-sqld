module Test.Sqld.UpdateSpec where

import Prelude (Unit, discard, (#))
import Data.Tuple (Tuple(..))
import Sqld.Core (Literal(..))
import Sqld.Expr (bool, col, int, str, tcol, (.==), (.>))
import Sqld.Format (formatUpdateStmt, formatUpdateInline)
import Sqld.Select (as, cols, set, star, update, updateFrom, updateReturning, updateWhere)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

updateSpec :: Spec Unit
updateSpec = describe "UPDATE" do

  describe "basic UPDATE" do
    it "single assignment" do
      let sql = update "users"
            # set [Tuple "active" (bool false)]
            # updateWhere (col "id" .== int 1)
            # formatUpdateInline
      sql `shouldEqual`
        "UPDATE \"users\" SET \"active\" = FALSE WHERE \"id\" = 1"

    it "multiple assignments" do
      let sql = update "users"
            # set [Tuple "active" (bool false), Tuple "name" (str "Bob")]
            # updateWhere (col "id" .== int 1)
            # formatUpdateInline
      sql `shouldEqual`
        "UPDATE \"users\" SET \"active\" = FALSE, \"name\" = 'Bob' WHERE \"id\" = 1"

    it "parameterised format" do
      let fq = update "users"
            # set [Tuple "active" (bool false), Tuple "name" (str "Bob")]
            # updateWhere (col "id" .== int 1)
            # formatUpdateStmt
      fq.sql `shouldEqual`
        "UPDATE \"users\" SET \"active\" = $1, \"name\" = $2 WHERE \"id\" = $3"
      fq.params `shouldEqual` [LitBoolean false, LitString "Bob", LitInt 1]

  describe "UPDATE ... FROM" do
    it "joins another table" do
      let sql = update "users"
            # set [Tuple "active" (bool false)]
            # updateFrom "orders"
            # updateWhere (tcol "orders" "user_id" .== tcol "users" "id")
            # formatUpdateInline
      sql `shouldEqual`
        "UPDATE \"users\" SET \"active\" = FALSE FROM \"orders\" WHERE \"orders\".\"user_id\" = \"users\".\"id\""

  describe "UPDATE without WHERE" do
    it "updates every row" do
      let sql = update "users"
            # set [Tuple "active" (bool true)]
            # formatUpdateInline
      sql `shouldEqual`
        "UPDATE \"users\" SET \"active\" = TRUE"

  describe "RETURNING" do
    it "returns specific columns" do
      let sql = update "users"
            # set [Tuple "active" (bool false)]
            # updateWhere (col "id" .== int 1)
            # updateReturning (cols ["id", "active"])
            # formatUpdateInline
      sql `shouldEqual`
        "UPDATE \"users\" SET \"active\" = FALSE WHERE \"id\" = 1 RETURNING \"id\", \"active\""

    it "returns star" do
      let sql = update "users"
            # set [Tuple "active" (bool false)]
            # updateWhere (col "id" .== int 1)
            # updateReturning [star]
            # formatUpdateInline
      sql `shouldEqual`
        "UPDATE \"users\" SET \"active\" = FALSE WHERE \"id\" = 1 RETURNING *"

    it "returns aliased expression" do
      let sql = update "users"
            # set [Tuple "active" (bool false)]
            # updateWhere (col "id" .== int 1)
            # updateReturning [as (col "id") "updated_id"]
            # formatUpdateInline
      sql `shouldEqual`
        "UPDATE \"users\" SET \"active\" = FALSE WHERE \"id\" = 1 RETURNING \"id\" AS \"updated_id\""

  describe "parameter ordering" do
    it "SET before FROM before WHERE before RETURNING" do
      let fq = update "users"
            # set [Tuple "active" (bool false), Tuple "name" (str "Bob")]
            # updateFrom "orders"
            # updateWhere (tcol "orders" "user_id" .== tcol "users" "id")
            # updateWhere (tcol "orders" "total" .> int 100)
            # updateReturning (cols ["id"])
            # formatUpdateStmt
      fq.sql `shouldEqual`
        "UPDATE \"users\" SET \"active\" = $1, \"name\" = $2 FROM \"orders\" WHERE (\"orders\".\"user_id\" = \"users\".\"id\" AND \"orders\".\"total\" > $3) RETURNING \"id\""
      fq.params `shouldEqual` [LitBoolean false, LitString "Bob", LitInt 100]

  describe "full UPDATE" do
    it "UPDATE ... SET ... FROM ... WHERE ... RETURNING" do
      let fq = update "users"
            # set [Tuple "active" (bool false), Tuple "name" (str "Bob")]
            # updateFrom "orders"
            # updateWhere (tcol "orders" "user_id" .== tcol "users" "id")
            # updateWhere (tcol "orders" "status" .== str "cancelled")
            # updateReturning (cols ["users.id"])
            # formatUpdateStmt
      fq.sql `shouldEqual`
        "UPDATE \"users\" SET \"active\" = $1, \"name\" = $2 FROM \"orders\" WHERE (\"orders\".\"user_id\" = \"users\".\"id\" AND \"orders\".\"status\" = $3) RETURNING \"users\".\"id\""
      fq.params `shouldEqual` [LitBoolean false, LitString "Bob", LitString "cancelled"]
