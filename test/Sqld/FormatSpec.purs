module Test.Sqld.FormatSpec where

import Prelude hiding (not, between)
import Sqld.Builder
import Sqld.Core (Literal(..), Query, emptyQuery)
import Sqld.Format (format)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

-- All identifiers are double-quoted by quoteIdent; literals become $N params.

formatSpec :: Spec Unit
formatSpec = describe "Sqld.Format" do

  describe "SELECT clause" do
    it "defaults to SELECT * when no columns given" do
      let r = format $ emptyQuery # from "t"
      r.sql `shouldEqual` "SELECT * FROM \"t\""
      r.params `shouldEqual` []

    it "SELECT * from explicit star" do
      let r = format $ emptyQuery # select [star] # from "t"
      r.sql `shouldEqual` "SELECT * FROM \"t\""
      r.params `shouldEqual` []

    it "selects named columns" do
      let r = format $ emptyQuery
                # select [s (col "id"), s (col "name"), s (col "email")]
                # from "users"
      r.sql `shouldEqual` "SELECT \"id\", \"name\", \"email\" FROM \"users\""
      r.params `shouldEqual` []

    it "aliases a column with AS" do
      let r = format $ emptyQuery
                # select [as (col "created_at") "ts"]
                # from "t"
      r.sql `shouldEqual` "SELECT \"created_at\" AS \"ts\" FROM \"t\""
      r.params `shouldEqual` []

    it "supports table-qualified columns" do
      let r = format $ emptyQuery
                # select [s (tcol "u" "id"), s (tcol "u" "name")]
                # from "users"
      r.sql `shouldEqual` "SELECT \"u\".\"id\", \"u\".\"name\" FROM \"users\""
      r.params `shouldEqual` []

    it "supports raw SELECT expression" do
      let r = format $ emptyQuery # select [s (raw "1 + 1")]
      r.sql `shouldEqual` "SELECT 1 + 1"
      r.params `shouldEqual` []

    it "supports COUNT(*) with alias via raw" do
      let r = format $ emptyQuery
                # select [s (col "dept"), as (raw "COUNT(*)") "n"]
                # from "t"
      r.sql `shouldEqual` "SELECT \"dept\", COUNT(*) AS \"n\" FROM \"t\""
      r.params `shouldEqual` []

  describe "FROM clause" do
    it "FROM bare table" do
      let r = format $ emptyQuery # from "orders"
      r.sql `shouldEqual` "SELECT * FROM \"orders\""
      r.params `shouldEqual` []

    it "FROM with alias" do
      let r = format $ emptyQuery # fromAs "users" "u"
      r.sql `shouldEqual` "SELECT * FROM \"users\" \"u\""
      r.params `shouldEqual` []

    it "omits FROM when not set" do
      let r = format $ emptyQuery # select [s (raw "1")]
      r.sql `shouldEqual` "SELECT 1"
      r.params `shouldEqual` []

  describe "WHERE clause" do
    it "simple equality with int param" do
      let r = format $ emptyQuery
                # from "users"
                # where_ (col "id" .== int 42)
      r.sql `shouldEqual` "SELECT * FROM \"users\" WHERE \"id\" = $1"
      r.params `shouldEqual` [LitInt 42]

    it "equality with boolean param" do
      let r = format $ emptyQuery
                # select [star]
                # from "users"
                # where_ (col "active" .== bool true)
      r.sql `shouldEqual` "SELECT * FROM \"users\" WHERE \"active\" = $1"
      r.params `shouldEqual` [LitBoolean true]

    it "equality with string param" do
      let r = format $ emptyQuery
                # from "t"
                # where_ (col "role" .== str "admin")
      r.sql `shouldEqual` "SELECT * FROM \"t\" WHERE \"role\" = $1"
      r.params `shouldEqual` [LitString "admin"]

    it "inequality operator" do
      let r = format $ emptyQuery # from "t" # where_ (col "status" .!= str "deleted")
      r.sql `shouldEqual` "SELECT * FROM \"t\" WHERE \"status\" <> $1"
      r.params `shouldEqual` [LitString "deleted"]

    it "less-than / greater-than" do
      let r = format $ emptyQuery # from "t" # where_ (col "age" .> int 18)
      r.sql `shouldEqual` "SELECT * FROM \"t\" WHERE \"age\" > $1"
      r.params `shouldEqual` [LitInt 18]

    it "greater-than-or-equal" do
      let r = format $ emptyQuery # from "t" # where_ (col "score" .>= int 100)
      r.sql `shouldEqual` "SELECT * FROM \"t\" WHERE \"score\" >= $1"
      r.params `shouldEqual` [LitInt 100]

    it "calling where_ twice ANDs the conditions" do
      let r = format $ emptyQuery
                # from "t"
                # where_ (col "a" .== int 1)
                # where_ (col "b" .== int 2)
      r.sql `shouldEqual` "SELECT * FROM \"t\" WHERE (\"a\" = $1 AND \"b\" = $2)"
      r.params `shouldEqual` [LitInt 1, LitInt 2]

    it "IS NULL" do
      let r = format $ emptyQuery # from "users" # where_ (isNull (col "deleted_at"))
      r.sql `shouldEqual` "SELECT * FROM \"users\" WHERE \"deleted_at\" IS NULL"
      r.params `shouldEqual` []

    it "IS NOT NULL" do
      let r = format $ emptyQuery # from "users" # where_ (isNotNull (col "email"))
      r.sql `shouldEqual` "SELECT * FROM \"users\" WHERE \"email\" IS NOT NULL"
      r.params `shouldEqual` []

    it "NOT wraps the inner expression" do
      let r = format $ emptyQuery # from "t" # where_ (not (col "deleted" .== bool true))
      r.sql `shouldEqual` "SELECT * FROM \"t\" WHERE NOT \"deleted\" = $1"
      r.params `shouldEqual` [LitBoolean true]

    it "raw passthrough — no quoting or params" do
      let r = format $ emptyQuery
                # from "t"
                # where_ (raw "created_at > NOW() - INTERVAL '7 days'")
      r.sql `shouldEqual` "SELECT * FROM \"t\" WHERE created_at > NOW() - INTERVAL '7 days'"
      r.params `shouldEqual` []

  describe "AND / OR" do
    it "and of multiple conditions" do
      let r = format $ emptyQuery
                # from "t"
                # where_ (and [col "a" .== int 1, col "b" .== int 2, col "c" .== int 3])
      r.sql `shouldEqual` "SELECT * FROM \"t\" WHERE (\"a\" = $1 AND \"b\" = $2 AND \"c\" = $3)"
      r.params `shouldEqual` [LitInt 1, LitInt 2, LitInt 3]

    it "or of multiple conditions" do
      let r = format $ emptyQuery
                # from "t"
                # where_ (or [col "x" .== int 1, col "x" .== int 2])
      r.sql `shouldEqual` "SELECT * FROM \"t\" WHERE (\"x\" = $1 OR \"x\" = $2)"
      r.params `shouldEqual` [LitInt 1, LitInt 2]

    it "nested AND inside OR" do
      let r = format $ emptyQuery
                # from "users"
                # where_
                    (and
                      [ or [ col "status" .== str "active"
                             , col "status" .== str "pending" ]
                      , col "age" .>= int 18
                      ])
      r.sql `shouldEqual`
        "SELECT * FROM \"users\" WHERE ((\"status\" = $1 OR \"status\" = $2) AND \"age\" >= $3)"
      r.params `shouldEqual` [LitString "active", LitString "pending", LitInt 18]

    it "empty and produces TRUE" do
      let r = format $ emptyQuery # from "t" # where_ (and [])
      r.sql `shouldEqual` "SELECT * FROM \"t\" WHERE TRUE"
      r.params `shouldEqual` []

    it "empty or produces FALSE" do
      let r = format $ emptyQuery # from "t" # where_ (or [])
      r.sql `shouldEqual` "SELECT * FROM \"t\" WHERE FALSE"
      r.params `shouldEqual` []

  describe "IN / NOT IN / BETWEEN / LIKE" do
    it "IN list" do
      let r = format $ emptyQuery
                # select [star]
                # from "products"
                # where_ (in_ (col "category_id") [int 1, int 2, int 3])
      r.sql `shouldEqual` "SELECT * FROM \"products\" WHERE \"category_id\" IN ($1, $2, $3)"
      r.params `shouldEqual` [LitInt 1, LitInt 2, LitInt 3]

    it "NOT IN list" do
      let r = format $ emptyQuery
                # from "t"
                # where_ (notIn (col "status") [str "deleted", str "banned"])
      r.sql `shouldEqual` "SELECT * FROM \"t\" WHERE \"status\" NOT IN ($1, $2)"
      r.params `shouldEqual` [LitString "deleted", LitString "banned"]

    it "BETWEEN low and high" do
      let r = format $ emptyQuery
                # from "orders"
                # where_ (between (col "total") (int 100) (int 500))
      r.sql `shouldEqual` "SELECT * FROM \"orders\" WHERE \"total\" BETWEEN $1 AND $2"
      r.params `shouldEqual` [LitInt 100, LitInt 500]

    it "LIKE with param" do
      let r = format $ emptyQuery
                # from "users"
                # where_ (like (col "email") "%@example.com")
      r.sql `shouldEqual` "SELECT * FROM \"users\" WHERE \"email\" LIKE $1"
      r.params `shouldEqual` [LitString "%@example.com"]

  describe "JOINs" do
    it "INNER JOIN (join)" do
      let r = format $ emptyQuery
                # from "orders"
                # innerJoin "users" (col "orders.user_id" .== col "users.id")
      r.sql `shouldEqual`
        "SELECT * FROM \"orders\" JOIN \"users\" ON (\"orders.user_id\" = \"users.id\")"
      r.params `shouldEqual` []

    it "LEFT JOIN with table alias" do
      let r = format $ emptyQuery
                # select [s (tcol "u" "id"), s (tcol "p" "bio")]
                # fromAs "users" "u"
                # leftJoinAs "profiles" "p" (tcol "u" "id" .== tcol "p" "user_id")
                # where_ (tcol "u" "active" .== bool true)
                # orderBy [desc (tcol "u" "created_at")]
                # limit 20
      r.sql `shouldEqual`
        "SELECT \"u\".\"id\", \"p\".\"bio\" FROM \"users\" \"u\" LEFT JOIN \"profiles\" \"p\" ON (\"u\".\"id\" = \"p\".\"user_id\") WHERE \"u\".\"active\" = $1 ORDER BY \"u\".\"created_at\" DESC LIMIT 20"
      r.params `shouldEqual` [LitBoolean true]

  describe "GROUP BY / HAVING" do
    it "GROUP BY with HAVING and aggregation" do
      let r = format $ emptyQuery
                # select [ s (col "department")
                          , as (raw "COUNT(*)") "headcount" ]
                # from "employees"
                # groupBy [col "department"]
                # having (raw "COUNT(*)" .> int 5)
                # orderBy [desc (col "headcount")]
      r.sql `shouldEqual`
        "SELECT \"department\", COUNT(*) AS \"headcount\" FROM \"employees\" GROUP BY \"department\" HAVING COUNT(*) > $1 ORDER BY \"headcount\" DESC"
      r.params `shouldEqual` [LitInt 5]

  describe "ORDER BY / LIMIT / OFFSET" do
    it "ORDER BY ASC" do
      let r = format $ emptyQuery # from "t" # orderBy [asc (col "name")]
      r.sql `shouldEqual` "SELECT * FROM \"t\" ORDER BY \"name\" ASC"
      r.params `shouldEqual` []

    it "ORDER BY DESC" do
      let r = format $ emptyQuery # from "t" # orderBy [desc (col "created_at")]
      r.sql `shouldEqual` "SELECT * FROM \"t\" ORDER BY \"created_at\" DESC"
      r.params `shouldEqual` []

    it "pagination with LIMIT and OFFSET" do
      let r = format $ emptyQuery
                # select [star]
                # from "articles"
                # orderBy [desc (col "published_at")]
                # limit 10
                # offset 20
      r.sql `shouldEqual`
        "SELECT * FROM \"articles\" ORDER BY \"published_at\" DESC LIMIT 10 OFFSET 20"
      r.params `shouldEqual` []

  describe "mergeQueries" do
    it "override wins for scalar fields" do
      let base     = emptyQuery # select [star] # from "users" # where_ (col "active" .== bool true)
          override = emptyQuery # where_ (col "admin" .== bool false) # limit 5
          r        = format (mergeQueries base override)
      r.sql `shouldEqual`
        "SELECT * FROM \"users\" WHERE (\"active\" = $1 AND \"admin\" = $2) LIMIT 5"
      r.params `shouldEqual` [LitBoolean true, LitBoolean false]

    it "base wins when override fields are empty" do
      let base     = emptyQuery # from "t" # limit 10
          override = emptyQuery
          r        = format (mergeQueries base override)
      r.sql `shouldEqual` "SELECT * FROM \"t\" LIMIT 10"
      r.params `shouldEqual` []

    it "joins are concatenated" do
      let base     = emptyQuery # from "a" # innerJoin "b" (col "a.id" .== col "b.a_id")
          override = emptyQuery # innerJoin "c" (col "a.id" .== col "c.a_id")
          r        = format (mergeQueries base override)
      r.sql `shouldEqual`
        "SELECT * FROM \"a\" JOIN \"b\" ON (\"a.id\" = \"b.a_id\") JOIN \"c\" ON (\"a.id\" = \"c.a_id\")"
      r.params `shouldEqual` []

  describe "integration" do
    it "multi-column select with WHERE (example1)" do
      let r = format $ emptyQuery
                # select [s (col "id"), s (col "name"), s (col "email")]
                # from "users"
                # where_ (col "id" .== int 42)
      r.sql `shouldEqual`
        "SELECT \"id\", \"name\", \"email\" FROM \"users\" WHERE \"id\" = $1"
      r.params `shouldEqual` [LitInt 42]

  describe "function composition (>>>)" do
    -- Reusable Query -> Query building blocks composed with >>>
    let baseUsers :: Query -> Query
        baseUsers = select [star] >>> from "users"

        activeOnly :: Query -> Query
        activeOnly = where_ (col "active" .== bool true)

        paginate :: Int -> Int -> Query -> Query
        paginate size page = limit size >>> offset (size * page)

    it "composes two builders with >>>" do
      let r = format $ baseUsers $ emptyQuery
      r.sql `shouldEqual` "SELECT * FROM \"users\""
      r.params `shouldEqual` []

    it "chains multiple builders with >>>" do
      let r = format $ baseUsers >>> activeOnly $ emptyQuery
      r.sql `shouldEqual` "SELECT * FROM \"users\" WHERE \"active\" = $1"
      r.params `shouldEqual` [LitBoolean true]

    it "paginate helper produces correct LIMIT / OFFSET" do
      let r = format $ baseUsers >>> activeOnly >>> paginate 10 2 $ emptyQuery
      r.sql `shouldEqual`
        "SELECT * FROM \"users\" WHERE \"active\" = $1 LIMIT 10 OFFSET 20"
      r.params `shouldEqual` [LitBoolean true]

    it "page 0 gives OFFSET 0" do
      let r = format $ paginate 20 0 $ emptyQuery # from "t"
      r.sql `shouldEqual` "SELECT * FROM \"t\" LIMIT 20 OFFSET 0"
      r.params `shouldEqual` []

  describe "param numbering" do
    it "numbers params left-to-right across the whole query" do
      let r = format $ emptyQuery
                # from "t"
                # where_ (and [col "a" .== int 1, col "b" .== int 2, col "c" .== int 3])
      r.params `shouldEqual` [LitInt 1, LitInt 2, LitInt 3]

    it "JOIN ON params come before WHERE params" do
      let r = format $ emptyQuery
                # from "orders"
                # leftJoin "users" (col "user_id" .== int 99)
                # where_ (col "status" .== str "open")
      r.sql `shouldEqual`
        "SELECT * FROM \"orders\" LEFT JOIN \"users\" ON (\"user_id\" = $1) WHERE \"status\" = $2"
      r.params `shouldEqual` [LitInt 99, LitString "open"]
