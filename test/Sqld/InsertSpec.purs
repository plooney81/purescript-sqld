module Test.Sqld.InsertSpec where

import Prelude (Unit, discard, (#))
import Data.Tuple (Tuple(..))
import Sqld.Core (Literal(..))
import Sqld.Expr (bool, col, default_, excluded, int, str, (.==))
import Sqld.Format (formatInsert, formatInsertInline)
import Sqld.Select (as, cols, expr, from, insertFrom, insertInto, onConflictDoNothing, onConflictUpdate, returning, select', star, values, where_)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

insertSpec :: Spec Unit
insertSpec = describe "INSERT" do

  describe "basic INSERT" do
    it "single row" do
      let sql = insertInto "users" ["name", "email"]
            # values [[str "Alice", str "alice@example.com"]]
            # formatInsertInline
      sql `shouldEqual`
        "INSERT INTO \"users\" (\"name\", \"email\") VALUES ('Alice', 'alice@example.com')"

    it "multiple rows" do
      let sql = insertInto "users" ["name", "email"]
            # values [ [str "Alice", str "a@example.com"]
                      , [str "Bob", str "b@example.com"]
                      ]
            # formatInsertInline
      sql `shouldEqual`
        "INSERT INTO \"users\" (\"name\", \"email\") VALUES ('Alice', 'a@example.com'), ('Bob', 'b@example.com')"

    it "parameterised format" do
      let fq = insertInto "users" ["name", "email"]
            # values [[str "Alice", str "alice@example.com"]]
            # formatInsert
      fq.sql `shouldEqual`
        "INSERT INTO \"users\" (\"name\", \"email\") VALUES ($1, $2)"
      fq.params `shouldEqual` [LitString "Alice", LitString "alice@example.com"]

  describe "DEFAULT" do
    it "DEFAULT keyword in VALUES row" do
      let sql = insertInto "users" ["name", "email"]
            # values [[str "Alice", default_]]
            # formatInsertInline
      sql `shouldEqual`
        "INSERT INTO \"users\" (\"name\", \"email\") VALUES ('Alice', DEFAULT)"

  describe "INSERT ... SELECT" do
    it "inserts from a subquery" do
      let sql = insertInto "archive" ["name", "email"]
            # insertFrom
                ( select' (cols ["name", "email"])
                    # from "users"
                    # where_ (col "active" .== bool false)
                )
            # formatInsertInline
      sql `shouldEqual`
        "INSERT INTO \"archive\" (\"name\", \"email\") SELECT \"name\", \"email\" FROM \"users\" WHERE \"active\" = FALSE"

  describe "ON CONFLICT" do
    it "DO NOTHING" do
      let sql = insertInto "users" ["name", "email"]
            # values [[str "Alice", str "alice@example.com"]]
            # onConflictDoNothing
            # formatInsertInline
      sql `shouldEqual`
        "INSERT INTO \"users\" (\"name\", \"email\") VALUES ('Alice', 'alice@example.com') ON CONFLICT DO NOTHING"

    it "DO UPDATE SET" do
      let sql = insertInto "users" ["name", "email"]
            # values [[str "Alice", str "alice@example.com"]]
            # onConflictUpdate ["email"] [Tuple "name" (excluded "name")]
            # formatInsertInline
      sql `shouldEqual`
        "INSERT INTO \"users\" (\"name\", \"email\") VALUES ('Alice', 'alice@example.com') ON CONFLICT (\"email\") DO UPDATE SET \"name\" = \"EXCLUDED\".\"name\""

  describe "RETURNING" do
    it "returns specific columns" do
      let sql = insertInto "users" ["name", "email"]
            # values [[str "Alice", str "alice@example.com"]]
            # returning (cols ["id"])
            # formatInsertInline
      sql `shouldEqual`
        "INSERT INTO \"users\" (\"name\", \"email\") VALUES ('Alice', 'alice@example.com') RETURNING \"id\""

    it "returns star" do
      let sql = insertInto "users" ["name", "email"]
            # values [[str "Alice", str "alice@example.com"]]
            # returning [star]
            # formatInsertInline
      sql `shouldEqual`
        "INSERT INTO \"users\" (\"name\", \"email\") VALUES ('Alice', 'alice@example.com') RETURNING *"

    it "returns aliased expression" do
      let sql = insertInto "users" ["name", "email"]
            # values [[str "Alice", str "alice@example.com"]]
            # returning [as (col "id") "new_id"]
            # formatInsertInline
      sql `shouldEqual`
        "INSERT INTO \"users\" (\"name\", \"email\") VALUES ('Alice', 'alice@example.com') RETURNING \"id\" AS \"new_id\""

  describe "full upsert" do
    it "INSERT ... ON CONFLICT ... DO UPDATE ... RETURNING" do
      let fq = insertInto "users" ["name", "email"]
            # values [[str "Alice", str "alice@example.com"]]
            # onConflictUpdate ["email"] [Tuple "name" (excluded "name")]
            # returning (cols ["id", "name"])
            # formatInsert
      fq.sql `shouldEqual`
        "INSERT INTO \"users\" (\"name\", \"email\") VALUES ($1, $2) ON CONFLICT (\"email\") DO UPDATE SET \"name\" = \"EXCLUDED\".\"name\" RETURNING \"id\", \"name\""
      fq.params `shouldEqual` [LitString "Alice", LitString "alice@example.com"]
