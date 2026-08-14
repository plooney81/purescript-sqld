module Test.Sqld.SelectSpec where

import Prelude hiding (not, between)
import Sqld.Core (JoinType(..), Literal(..), Query, emptyQuery)
import Sqld.Expr
import Sqld.Format (format, formatInline)
import Sqld.Select
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

selectSpec :: Spec Unit
selectSpec = describe "Sqld.Select" do

  describe "SELECT clause" do
    it "SELECT * from explicit star" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\""

    it "selects named columns" do
      let query = emptyQuery
            # select (cols ["id", "name", "email"])
            # from "users"
            # formatInline
      query `shouldEqual` "SELECT \"id\", \"name\", \"email\" FROM \"users\""

    it "calling select twice accumulates" do
      let query = emptyQuery
            # select [expr (tcol "u" "id"), expr (tcol "u" "name")]
            # fromAs "users" "u"
            # select [expr (col "something_else")]
            # formatInline
      query `shouldEqual` "SELECT \"u\".\"id\", \"u\".\"name\", \"something_else\" FROM \"users\" AS \"u\""

    it "aliases a column with AS" do
      let query = emptyQuery
            # select [as (col "created_at") "ts"]
            # from "t"
            # formatInline
      query `shouldEqual` "SELECT \"created_at\" AS \"ts\" FROM \"t\""

    it "colAs shorthand" do
      let query = emptyQuery
            # select [colAs "created_at" "ts"]
            # from "t"
            # formatInline
      query `shouldEqual` "SELECT \"created_at\" AS \"ts\" FROM \"t\""

    it "tcolAs shorthand" do
      let query = emptyQuery
            # select [tcolAs "u" "created_at" "ts"]
            # fromAs "users" "u"
            # formatInline
      query `shouldEqual` "SELECT \"u\".\"created_at\" AS \"ts\" FROM \"users\" AS \"u\""

    it "table-qualified columns" do
      let query = emptyQuery
            # select [expr (tcol "u" "id"), expr (tcol "u" "name")]
            # fromAs "users" "u"
            # formatInline
      query `shouldEqual` "SELECT \"u\".\"id\", \"u\".\"name\" FROM \"users\" AS \"u\""

    it "raw SELECT expression" do
      let query = emptyQuery
            # select [expr (raw "1 + 1")]
            # formatInline
      query `shouldEqual` "SELECT 1 + 1"

    it "COUNT(*) with alias" do
      let query = emptyQuery
            # select [expr (col "dept"), as (raw "COUNT(*)") "n"]
            # from "t"
            # formatInline
      query `shouldEqual` "SELECT \"dept\", COUNT(*) AS \"n\" FROM \"t\""

  describe "FROM clause" do
    it "bare table" do
      let query = emptyQuery
            # select [star]
            # from "orders"
            # formatInline
      query `shouldEqual` "SELECT * FROM \"orders\""

    it "with alias" do
      let query = emptyQuery
            # select [star]
            # fromAs "users" "u"
            # formatInline
      query `shouldEqual` "SELECT * FROM \"users\" AS \"u\""

    it "omits FROM when not set" do
      let query = emptyQuery
            # select [expr (raw "1")]
            # formatInline
      query `shouldEqual` "SELECT 1"

  describe "WHERE clause" do
    it "ANDs when where_ is called twice" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # where_ (col "a" .== int 1)
            # where_ (col "b" .== int 2)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE (\"a\" = 1 AND \"b\" = 2)"

  describe "JOINs" do
    it "INNER JOIN" do
      let query = emptyQuery
            # select [star]
            # from "orders"
            # innerJoin "users" (col "orders.user_id" .== col "users.id")
            # formatInline
      query `shouldEqual` "SELECT * FROM \"orders\" JOIN \"users\" ON (\"orders.user_id\" = \"users.id\")"

    it "LEFT JOIN with alias" do
      let query = emptyQuery
            # select [expr (tcol "u" "id"), expr (tcol "p" "bio")]
            # fromAs "users" "u"
            # leftJoinAs "profiles" "p" (tcol "u" "id" .== tcol "p" "user_id")
            # where_ (tcol "u" "active" .== bool true)
            # orderBy [desc (tcol "u" "created_at")]
            # limit 20
            # formatInline
      query `shouldEqual`
        "SELECT \"u\".\"id\", \"p\".\"bio\" FROM \"users\" AS \"u\" LEFT JOIN \"profiles\" AS \"p\" ON (\"u\".\"id\" = \"p\".\"user_id\") WHERE \"u\".\"active\" = TRUE ORDER BY \"u\".\"created_at\" DESC LIMIT 20"

    it "RIGHT JOIN" do
      let query = emptyQuery
            # select [star]
            # from "users"
            # rightJoin "profiles" (tcol "users" "id" .== tcol "profiles" "user_id")
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"users\" RIGHT JOIN \"profiles\" ON (\"users\".\"id\" = \"profiles\".\"user_id\")"

    it "FULL JOIN with alias" do
      let query = emptyQuery
            # select [star]
            # fromAs "users" "u"
            # fullJoinAs "profiles" "p" (tcol "u" "id" .== tcol "p" "user_id")
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"users\" AS \"u\" FULL JOIN \"profiles\" AS \"p\" ON (\"u\".\"id\" = \"p\".\"user_id\")"

    it "INNER JOIN with alias" do
      let query = emptyQuery
            # select [star]
            # fromAs "users" "u"
            # innerJoinAs "orders" "o" (tcol "u" "id" .== tcol "o" "user_id")
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"users\" AS \"u\" JOIN \"orders\" AS \"o\" ON (\"u\".\"id\" = \"o\".\"user_id\")"

  describe "derived tables" do
    it "subquery in FROM" do
      let recent = emptyQuery
            # select [star]
            # from "orders"
            # where_ (col "status" .== str "paid")
          query = emptyQuery
            # select [starFrom "recent"]
            # fromSub recent "recent"
            # formatInline
      query `shouldEqual`
        "SELECT \"recent\".* FROM (SELECT * FROM \"orders\" WHERE \"status\" = 'paid') AS \"recent\""

    it "subquery as a join target" do
      let totals = emptyQuery # select [expr (col "user_id")] # from "orders"
          query = emptyQuery
            # select [star]
            # fromAs "users" "u"
            # joinOn InnerJoin (derived totals "t") (tcol "u" "id" .== tcol "t" "user_id")
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"users\" AS \"u\" JOIN (SELECT \"user_id\" FROM \"orders\") AS \"t\" ON (\"u\".\"id\" = \"t\".\"user_id\")"

    -- A derived table's parameters appear earlier in the SQL than the outer
    -- query's, so they must be numbered first.
    it "parameters are numbered before the outer query's" do
      let recent = emptyQuery
            # select [star]
            # from "orders"
            # where_ (col "status" .== str "paid")
          result = emptyQuery
            # select [starFrom "recent"]
            # fromSub recent "recent"
            # where_ (tcol "recent" "total" .> int 100)
            # format
      result.sql `shouldEqual`
        "SELECT \"recent\".* FROM (SELECT * FROM \"orders\" WHERE \"status\" = $1) AS \"recent\" WHERE \"recent\".\"total\" > $2"
      result.params `shouldEqual` [LitString "paid", LitInt 100]

  describe "GROUP BY / HAVING" do
    it "GROUP BY with HAVING and aggregation" do
      let query = emptyQuery
            # select [expr (col "department"), as (raw "COUNT(*)") "headcount"]
            # from "employees"
            # groupBy [col "department"]
            # having (raw "COUNT(*)" .> int 5)
            # orderBy [desc (col "headcount")]
            # formatInline
      query `shouldEqual`
        "SELECT \"department\", COUNT(*) AS \"headcount\" FROM \"employees\" GROUP BY \"department\" HAVING COUNT(*) > 5 ORDER BY \"headcount\" DESC"

  describe "ORDER BY / LIMIT / OFFSET" do
    it "ORDER BY ASC" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # orderBy [asc (col "name")]
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" ORDER BY \"name\" ASC"

    it "ORDER BY DESC" do
      let query = emptyQuery
            # select [star]
            # from "t"
            # orderBy [desc (col "created_at")]
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" ORDER BY \"created_at\" DESC"

    it "pagination" do
      let query = emptyQuery
            # select [star]
            # from "articles"
            # orderBy [desc (col "published_at")]
            # limit 10
            # offset 20
            # formatInline
      query `shouldEqual` "SELECT * FROM \"articles\" ORDER BY \"published_at\" DESC LIMIT 10 OFFSET 20"

  describe "mergeQueries" do
    it "override wins for scalar fields" do
      let base     = emptyQuery # select [star] # from "users" # where_ (col "active" .== bool true)
          override = emptyQuery # where_ (col "admin" .== bool false) # limit 5
          query    = mergeQueries base override # formatInline
      query `shouldEqual` "SELECT * FROM \"users\" WHERE (\"active\" = TRUE AND \"admin\" = FALSE) LIMIT 5"

    it "base wins when override fields are empty" do
      let query = mergeQueries (emptyQuery # select [star] # from "t" # limit 10) emptyQuery # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" LIMIT 10"

    it "joins are concatenated" do
      let base     = emptyQuery # select [star] # from "a" # innerJoin "b" (col "a.id" .== col "b.a_id")
          override = emptyQuery # innerJoin "c" (col "a.id" .== col "c.a_id")
          query    = mergeQueries base override # formatInline
      query `shouldEqual` "SELECT * FROM \"a\" JOIN \"b\" ON (\"a.id\" = \"b.a_id\") JOIN \"c\" ON (\"a.id\" = \"c.a_id\")"

  describe "function composition (>>>)" do
    let baseUsers :: Query -> Query
        baseUsers = select [star] >>> from "users"

        activeOnly :: Query -> Query
        activeOnly = where_ (col "active" .== bool true)

        paginate :: Int -> Int -> Query -> Query
        paginate size page = limit size >>> offset (size * page)

    it "composes two builders" do
      let query = baseUsers emptyQuery # formatInline
      query `shouldEqual` "SELECT * FROM \"users\""

    it "chains multiple builders" do
      let query = (baseUsers >>> activeOnly $ emptyQuery) # formatInline
      query `shouldEqual` "SELECT * FROM \"users\" WHERE \"active\" = TRUE"

    it "paginate helper" do
      let query = (baseUsers >>> activeOnly >>> paginate 10 2 $ emptyQuery) # formatInline
      query `shouldEqual` "SELECT * FROM \"users\" WHERE \"active\" = TRUE LIMIT 10 OFFSET 20"

    it "page 0 gives OFFSET 0" do
      let query = (select [star] >>> from "t" >>> paginate 20 0 $ emptyQuery) # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" LIMIT 20 OFFSET 0"
