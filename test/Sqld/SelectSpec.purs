module Test.Sqld.SelectSpec where

import Prelude hiding (not, between)
import Sqld.Core (Query, emptyQuery)
import Sqld.Expr
import Sqld.Format (formatInline)
import Sqld.Select
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

selectSpec :: Spec Unit
selectSpec = describe "Sqld.Select" do

  describe "SELECT clause" do
    it "SELECT * from explicit star" do
      formatInline (emptyQuery # select [star] # from "t")
        `shouldEqual` "SELECT * FROM \"t\""

    it "selects named columns" do
      formatInline (emptyQuery # select (cols ["id", "name", "email"]) # from "users")
        `shouldEqual` "SELECT \"id\", \"name\", \"email\" FROM \"users\""

    it "aliases a column with AS" do
      formatInline (emptyQuery # select [as (col "created_at") "ts"] # from "t")
        `shouldEqual` "SELECT \"created_at\" AS \"ts\" FROM \"t\""

    it "colAs shorthand" do
      formatInline (emptyQuery # select [colAs "created_at" "ts"] # from "t")
        `shouldEqual` "SELECT \"created_at\" AS \"ts\" FROM \"t\""

    it "tcolAs shorthand" do
      formatInline (emptyQuery # select [tcolAs "u" "created_at" "ts"] # fromAs "users" "u")
        `shouldEqual` "SELECT \"u\".\"created_at\" AS \"ts\" FROM \"users\" AS \"u\""

    it "table-qualified columns" do
      formatInline (emptyQuery # select [expr (tcol "u" "id"), expr (tcol "u" "name")] # fromAs "users" "u")
        `shouldEqual` "SELECT \"u\".\"id\", \"u\".\"name\" FROM \"users\" AS \"u\""

    it "raw SELECT expression" do
      formatInline (emptyQuery # select [expr (raw "1 + 1")])
        `shouldEqual` "SELECT 1 + 1"

    it "COUNT(*) with alias" do
      formatInline (emptyQuery # select [expr (col "dept"), as (raw "COUNT(*)") "n"] # from "t")
        `shouldEqual` "SELECT \"dept\", COUNT(*) AS \"n\" FROM \"t\""

  describe "FROM clause" do
    it "bare table" do
      formatInline (emptyQuery # select [star] # from "orders")
        `shouldEqual` "SELECT * FROM \"orders\""

    it "with alias" do
      formatInline (emptyQuery # select [star] # fromAs "users" "u")
        `shouldEqual` "SELECT * FROM \"users\" AS \"u\""

    it "omits FROM when not set" do
      formatInline (emptyQuery # select [expr (raw "1")])
        `shouldEqual` "SELECT 1"

  describe "WHERE clause" do
    it "ANDs when where_ is called twice" do
      formatInline (emptyQuery # select [star] # from "t" # where_ (col "a" .== int 1) # where_ (col "b" .== int 2))
        `shouldEqual` "SELECT * FROM \"t\" WHERE (\"a\" = 1 AND \"b\" = 2)"

  describe "JOINs" do
    it "INNER JOIN" do
      formatInline (emptyQuery # select [star] # from "orders" # innerJoin "users" (col "orders.user_id" .== col "users.id"))
        `shouldEqual` "SELECT * FROM \"orders\" JOIN \"users\" ON (\"orders.user_id\" = \"users.id\")"

    it "LEFT JOIN with alias" do
      formatInline
        ( emptyQuery
            # select [expr (tcol "u" "id"), expr (tcol "p" "bio")]
            # fromAs "users" "u"
            # leftJoinAs "profiles" "p" (tcol "u" "id" .== tcol "p" "user_id")
            # where_ (tcol "u" "active" .== bool true)
            # orderBy [desc (tcol "u" "created_at")]
            # limit 20
        )
        `shouldEqual`
          "SELECT \"u\".\"id\", \"p\".\"bio\" FROM \"users\" AS \"u\" LEFT JOIN \"profiles\" AS \"p\" ON (\"u\".\"id\" = \"p\".\"user_id\") WHERE \"u\".\"active\" = TRUE ORDER BY \"u\".\"created_at\" DESC LIMIT 20"

  describe "GROUP BY / HAVING" do
    it "GROUP BY with HAVING and aggregation" do
      formatInline
        ( emptyQuery
            # select [expr (col "department"), as (raw "COUNT(*)") "headcount"]
            # from "employees"
            # groupBy [col "department"]
            # having (raw "COUNT(*)" .> int 5)
            # orderBy [desc (col "headcount")]
        )
        `shouldEqual`
          "SELECT \"department\", COUNT(*) AS \"headcount\" FROM \"employees\" GROUP BY \"department\" HAVING COUNT(*) > 5 ORDER BY \"headcount\" DESC"

  describe "ORDER BY / LIMIT / OFFSET" do
    it "ORDER BY ASC" do
      formatInline (emptyQuery # select [star] # from "t" # orderBy [asc (col "name")])
        `shouldEqual` "SELECT * FROM \"t\" ORDER BY \"name\" ASC"

    it "ORDER BY DESC" do
      formatInline (emptyQuery # select [star] # from "t" # orderBy [desc (col "created_at")])
        `shouldEqual` "SELECT * FROM \"t\" ORDER BY \"created_at\" DESC"

    it "pagination" do
      formatInline (emptyQuery # select [star] # from "articles" # orderBy [desc (col "published_at")] # limit 10 # offset 20)
        `shouldEqual` "SELECT * FROM \"articles\" ORDER BY \"published_at\" DESC LIMIT 10 OFFSET 20"

  describe "mergeQueries" do
    it "override wins for scalar fields" do
      let base     = emptyQuery # select [star] # from "users" # where_ (col "active" .== bool true)
          override = emptyQuery # where_ (col "admin" .== bool false) # limit 5
      formatInline (mergeQueries base override)
        `shouldEqual` "SELECT * FROM \"users\" WHERE (\"active\" = TRUE AND \"admin\" = FALSE) LIMIT 5"

    it "base wins when override fields are empty" do
      formatInline (mergeQueries (emptyQuery # select [star] # from "t" # limit 10) emptyQuery)
        `shouldEqual` "SELECT * FROM \"t\" LIMIT 10"

    it "joins are concatenated" do
      let base     = emptyQuery # select [star] # from "a" # innerJoin "b" (col "a.id" .== col "b.a_id")
          override = emptyQuery # innerJoin "c" (col "a.id" .== col "c.a_id")
      formatInline (mergeQueries base override)
        `shouldEqual` "SELECT * FROM \"a\" JOIN \"b\" ON (\"a.id\" = \"b.a_id\") JOIN \"c\" ON (\"a.id\" = \"c.a_id\")"

  describe "function composition (>>>)" do
    let baseUsers :: Query -> Query
        baseUsers = select [star] >>> from "users"

        activeOnly :: Query -> Query
        activeOnly = where_ (col "active" .== bool true)

        paginate :: Int -> Int -> Query -> Query
        paginate size page = limit size >>> offset (size * page)

    it "composes two builders" do
      formatInline (baseUsers emptyQuery)
        `shouldEqual` "SELECT * FROM \"users\""

    it "chains multiple builders" do
      formatInline (baseUsers >>> activeOnly $ emptyQuery)
        `shouldEqual` "SELECT * FROM \"users\" WHERE \"active\" = TRUE"

    it "paginate helper" do
      formatInline (baseUsers >>> activeOnly >>> paginate 10 2 $ emptyQuery)
        `shouldEqual` "SELECT * FROM \"users\" WHERE \"active\" = TRUE LIMIT 10 OFFSET 20"

    it "page 0 gives OFFSET 0" do
      formatInline (select [star] >>> from "t" >>> paginate 20 0 $ emptyQuery)
        `shouldEqual` "SELECT * FROM \"t\" LIMIT 20 OFFSET 0"
