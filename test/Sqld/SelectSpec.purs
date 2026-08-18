module Test.Sqld.SelectSpec where

import Prelude hiding (not, between)
import Sqld.Core (JoinCondition(..), JoinType(..), Literal(..), Query, emptyQuery)
import Sqld.Expr
import Sqld.Format (format, formatInline)
import Sqld.Select
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

selectSpec :: Spec Unit
selectSpec = describe "Sqld.Select" do

  describe "SELECT clause" do
    it "SELECT * from explicit star" do
      let query = select' [star]
            # from "t"
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\""

    it "selects named columns" do
      let query = select' (cols ["id", "name", "email"])
            # from "users"
            # formatInline
      query `shouldEqual` "SELECT \"id\", \"name\", \"email\" FROM \"users\""

    it "calling select twice accumulates" do
      let query = select' [expr (tcol "u" "id"), expr (tcol "u" "name")]
            # fromAs "users" "u"
            # select [expr (col "something_else")]
            # formatInline
      query `shouldEqual` "SELECT \"u\".\"id\", \"u\".\"name\", \"something_else\" FROM \"users\" AS \"u\""

    it "aliases a column with AS" do
      let query = select' [as (col "created_at") "ts"]
            # from "t"
            # formatInline
      query `shouldEqual` "SELECT \"created_at\" AS \"ts\" FROM \"t\""

    it "colAs shorthand" do
      let query = select' [colAs "created_at" "ts"]
            # from "t"
            # formatInline
      query `shouldEqual` "SELECT \"created_at\" AS \"ts\" FROM \"t\""

    it "tcolAs shorthand" do
      let query = select' [tcolAs "u" "created_at" "ts"]
            # fromAs "users" "u"
            # formatInline
      query `shouldEqual` "SELECT \"u\".\"created_at\" AS \"ts\" FROM \"users\" AS \"u\""

    it "table-qualified columns" do
      let query = select' [expr (tcol "u" "id"), expr (tcol "u" "name")]
            # fromAs "users" "u"
            # formatInline
      query `shouldEqual` "SELECT \"u\".\"id\", \"u\".\"name\" FROM \"users\" AS \"u\""

    it "raw SELECT expression" do
      let query = select' [expr (raw "1 + 1")]
            # formatInline
      query `shouldEqual` "SELECT 1 + 1"

    it "COUNT(*) with alias" do
      let query = select' [expr (col "dept"), as (raw "COUNT(*)") "n"]
            # from "t"
            # formatInline
      query `shouldEqual` "SELECT \"dept\", COUNT(*) AS \"n\" FROM \"t\""

  describe "select'" do
    it "starts a query without naming emptyQuery" do
      let query = select' (cols ["id", "name"])
            # from "users"
            # where_ (col "active" .== bool true)
            # formatInline
      query `shouldEqual` "SELECT \"id\", \"name\" FROM \"users\" WHERE \"active\" = TRUE"

    it "stays additive, so later select calls append" do
      let query = select' (cols ["department"])
            # select [as countStar "headcount"]
            # from "users"
            # groupBy [col "department"]
            # formatInline
      query `shouldEqual`
        "SELECT \"department\", COUNT(*) AS \"headcount\" FROM \"users\" GROUP BY \"department\""

    -- The one place `emptyQuery # select` is still written out: the point of
    -- the test is that the two forms agree.
    it "matches the emptyQuery form exactly" do
      let viaHelper = select' (cols ["id"]) # from "users" # formatInline
          viaEmpty  = emptyQuery # select (cols ["id"]) # from "users" # formatInline
      viaHelper `shouldEqual` viaEmpty

  describe "mixed select lists" do
    it "concatenates plain columns with aliased expressions" do
      let query = select' (cols ["department"] <> [as countStar "headcount"])
            # from "users"
            # groupBy [col "department"]
            # formatInline
      query `shouldEqual`
        "SELECT \"department\", COUNT(*) AS \"headcount\" FROM \"users\" GROUP BY \"department\""

    it "exprs wraps a run of bare expressions" do
      let query = select' (exprs [col "id", avg (col "age")])
            # from "users"
            # formatInline
      query `shouldEqual` "SELECT \"id\", AVG(\"age\") FROM \"users\""

    it "select is additive, so lists can be built up in stages" do
      let query = select' (cols ["department"])
            # select [as countStar "headcount"]
            # from "users"
            # groupBy [col "department"]
            # formatInline
      query `shouldEqual`
        "SELECT \"department\", COUNT(*) AS \"headcount\" FROM \"users\" GROUP BY \"department\""

  describe "DISTINCT" do
    it "SELECT DISTINCT" do
      let query = select' (cols ["department"])
            # distinct
            # from "users"
            # formatInline
      query `shouldEqual` "SELECT DISTINCT \"department\" FROM \"users\""

    it "DISTINCT ON, bracketed ahead of the select list" do
      let query = select' (cols ["user_id", "total"])
            # distinctOn [col "user_id"]
            # from "orders"
            # orderBy [asc (col "user_id"), desc (col "placed_at")]
            # formatInline
      query `shouldEqual`
        "SELECT DISTINCT ON (\"user_id\") \"user_id\", \"total\" FROM \"orders\" ORDER BY \"user_id\" ASC, \"placed_at\" DESC"

    it "DISTINCT ON several expressions, comma-separated" do
      let query = select' [star]
            # distinctOn [col "user_id", upper (col "status")]
            # from "orders"
            # formatInline
      query `shouldEqual`
        "SELECT DISTINCT ON (\"user_id\", UPPER(\"status\")) * FROM \"orders\""

    -- The DISTINCT ON expressions precede the select list in the emitted SQL,
    -- so they are numbered first.
    it "numbers parameters in emitted-SQL order" do
      let result = select' [as (coalesce [col "email", str "none"]) "email"]
            # distinctOn [coalesce [col "department", str "unknown"]]
            # from "users"
            # where_ (col "active" .== bool true)
            # format
      result.sql `shouldEqual`
        "SELECT DISTINCT ON (COALESCE(\"department\", $1)) COALESCE(\"email\", $2) AS \"email\" FROM \"users\" WHERE \"active\" = $3"
      result.params `shouldEqual` [LitString "unknown", LitString "none", LitBoolean true]

    it "is mutually exclusive: the later call wins" do
      let onThenPlain = select' (cols ["department"])
            # distinctOn [col "user_id"]
            # distinct
            # from "users"
            # formatInline
          plainThenOn = select' (cols ["department"])
            # distinct
            # distinctOn [col "user_id"]
            # from "users"
            # formatInline
      onThenPlain `shouldEqual` "SELECT DISTINCT \"department\" FROM \"users\""
      plainThenOn `shouldEqual`
        "SELECT DISTINCT ON (\"user_id\") \"department\" FROM \"users\""

    -- `DISTINCT ON ()` is not something PostgreSQL parses, and an empty list
    -- arises naturally when the expressions come from user input.
    it "falls back to plain DISTINCT on an empty list" do
      let query = select' (cols ["department"])
            # distinctOn []
            # from "users"
            # formatInline
      query `shouldEqual` "SELECT DISTINCT \"department\" FROM \"users\""

    it "mergeQueries takes the right-hand side's" do
      let base     = select' (cols ["department"]) # distinct # from "users"
          override = emptyQuery # distinctOn [col "department"]
          query    = mergeQueries base override # formatInline
      query `shouldEqual`
        "SELECT DISTINCT ON (\"department\") \"department\" FROM \"users\""

    it "mergeQueries keeps the base's when the override sets none" do
      let query = mergeQueries (select' (cols ["department"]) # distinct # from "users") emptyQuery
            # formatInline
      query `shouldEqual` "SELECT DISTINCT \"department\" FROM \"users\""

  describe "FROM clause" do
    it "bare table" do
      let query = select' [star]
            # from "orders"
            # formatInline
      query `shouldEqual` "SELECT * FROM \"orders\""

    it "with alias" do
      let query = select' [star]
            # fromAs "users" "u"
            # formatInline
      query `shouldEqual` "SELECT * FROM \"users\" AS \"u\""

    it "omits FROM when not set" do
      let query = select' [expr (raw "1")]
            # formatInline
      query `shouldEqual` "SELECT 1"

  describe "WHERE clause" do
    it "ANDs when where_ is called twice" do
      let query = select' [star]
            # from "t"
            # where_ (col "a" .== int 1)
            # where_ (col "b" .== int 2)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE (\"a\" = 1 AND \"b\" = 2)"

  describe "JOINs" do
    it "INNER JOIN" do
      let query = select' [star]
            # from "orders"
            # innerJoin "users" (col "orders.user_id" .== col "users.id")
            # formatInline
      query `shouldEqual` "SELECT * FROM \"orders\" JOIN \"users\" ON (\"orders\".\"user_id\" = \"users\".\"id\")"

    it "LEFT JOIN with alias" do
      let query = select' [expr (tcol "u" "id"), expr (tcol "p" "bio")]
            # fromAs "users" "u"
            # leftJoinAs "profiles" "p" (tcol "u" "id" .== tcol "p" "user_id")
            # where_ (tcol "u" "active" .== bool true)
            # orderBy [desc (tcol "u" "created_at")]
            # limit 20
            # formatInline
      query `shouldEqual`
        "SELECT \"u\".\"id\", \"p\".\"bio\" FROM \"users\" AS \"u\" LEFT JOIN \"profiles\" AS \"p\" ON (\"u\".\"id\" = \"p\".\"user_id\") WHERE \"u\".\"active\" = TRUE ORDER BY \"u\".\"created_at\" DESC LIMIT 20"

    it "RIGHT JOIN" do
      let query = select' [star]
            # from "users"
            # rightJoin "profiles" (tcol "users" "id" .== tcol "profiles" "user_id")
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"users\" RIGHT JOIN \"profiles\" ON (\"users\".\"id\" = \"profiles\".\"user_id\")"

    it "FULL JOIN with alias" do
      let query = select' [star]
            # fromAs "users" "u"
            # fullJoinAs "profiles" "p" (tcol "u" "id" .== tcol "p" "user_id")
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"users\" AS \"u\" FULL JOIN \"profiles\" AS \"p\" ON (\"u\".\"id\" = \"p\".\"user_id\")"

    it "INNER JOIN with alias" do
      let query = select' [star]
            # fromAs "users" "u"
            # innerJoinAs "orders" "o" (tcol "u" "id" .== tcol "o" "user_id")
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"users\" AS \"u\" JOIN \"orders\" AS \"o\" ON (\"u\".\"id\" = \"o\".\"user_id\")"

    it "CROSS JOIN" do
      let query = select' [star]
            # from "users"
            # crossJoin "departments"
            # formatInline
      query `shouldEqual` "SELECT * FROM \"users\" CROSS JOIN \"departments\""

    it "JOIN USING" do
      let query = select' [star]
            # from "orders"
            # joinUsing InnerJoin "profiles" ["user_id"]
            # formatInline
      query `shouldEqual` "SELECT * FROM \"orders\" JOIN \"profiles\" USING (\"user_id\")"

    it "JOIN USING quotes every column name" do
      let query = select' [star]
            # from "orders"
            # joinUsing LeftJoin "profiles" ["id", "user_id"]
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"orders\" LEFT JOIN \"profiles\" USING (\"id\", \"user_id\")"

    -- `USING ()` is not something PostgreSQL parses, and no columns to match on
    -- is what `and []` already means.
    it "JOIN USING with no columns falls back to ON (TRUE)" do
      let query = select' [star]
            # from "orders"
            # joinUsing InnerJoin "profiles" []
            # formatInline
      query `shouldEqual` "SELECT * FROM \"orders\" JOIN \"profiles\" ON (TRUE)"

    it "NATURAL JOIN" do
      let query = select' [star]
            # from "users"
            # naturalJoin InnerJoin "departments"
            # formatInline
      query `shouldEqual` "SELECT * FROM \"users\" NATURAL JOIN \"departments\""

    it "NATURAL LEFT JOIN puts NATURAL in front of the join type" do
      let query = select' [star]
            # from "users"
            # naturalJoin LeftJoin "departments"
            # formatInline
      query `shouldEqual` "SELECT * FROM \"users\" NATURAL LEFT JOIN \"departments\""

    it "joins an aliased relation with joinRel" do
      let query = select' [star]
            # from "users"
            # joinRel (relAs "departments" "d") Cross
            # formatInline
      query `shouldEqual` "SELECT * FROM \"users\" CROSS JOIN \"departments\" AS \"d\""

    it "mixes join forms in one query" do
      let query = select' [star]
            # fromAs "users" "u"
            # joinUsing LeftJoin "profiles" ["user_id"]
            # crossJoin "departments"
            # innerJoinAs "orders" "o" (tcol "u" "id" .== tcol "o" "user_id")
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"users\" AS \"u\" LEFT JOIN \"profiles\" USING (\"user_id\") CROSS JOIN \"departments\" JOIN \"orders\" AS \"o\" ON (\"u\".\"id\" = \"o\".\"user_id\")"

  describe "derived tables" do
    it "subquery in FROM" do
      let recent = select' [star]
            # from "orders"
            # where_ (col "status" .== str "paid")
          query = select' [starFrom "recent"]
            # fromSub recent "recent"
            # formatInline
      query `shouldEqual`
        "SELECT \"recent\".* FROM (SELECT * FROM \"orders\" WHERE \"status\" = 'paid') AS \"recent\""

    it "subquery as a join target" do
      let totals = select' [expr (col "user_id")] # from "orders"
          query = select' [star]
            # fromAs "users" "u"
            # joinOn InnerJoin (derived totals "t") (tcol "u" "id" .== tcol "t" "user_id")
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"users\" AS \"u\" JOIN (SELECT \"user_id\" FROM \"orders\") AS \"t\" ON (\"u\".\"id\" = \"t\".\"user_id\")"

    -- A derived table's parameters appear earlier in the SQL than the outer
    -- query's, so they must be numbered first.
    it "parameters are numbered before the outer query's" do
      let recent = select' [star]
            # from "orders"
            # where_ (col "status" .== str "paid")
          result = select' [starFrom "recent"]
            # fromSub recent "recent"
            # where_ (tcol "recent" "total" .> int 100)
            # format
      result.sql `shouldEqual`
        "SELECT \"recent\".* FROM (SELECT * FROM \"orders\" WHERE \"status\" = $1) AS \"recent\" WHERE \"recent\".\"total\" > $2"
      result.params `shouldEqual` [LitString "paid", LitInt 100]

  describe "lateral subqueries" do
    -- The subquery references "u"."id", which only LATERAL makes legal.
    it "joinLateral joins ON (TRUE)" do
      let recent = select' (cols ["total"])
            # from "orders"
            # where_ (tcol "orders" "user_id" .== tcol "u" "id")
            # limit 3
          query = select' [expr (tcol "recent" "total")]
            # fromAs "users" "u"
            # joinLateral recent "recent"
            # formatInline
      query `shouldEqual`
        "SELECT \"recent\".\"total\" FROM \"users\" AS \"u\" JOIN LATERAL (SELECT \"total\" FROM \"orders\" WHERE \"orders\".\"user_id\" = \"u\".\"id\" LIMIT 3) AS \"recent\" ON (TRUE)"

    -- The outer form, which keeps a left row whose subquery found nothing.
    it "leftJoinLateral" do
      let recent = select' (cols ["total"])
            # from "orders"
            # where_ (tcol "orders" "user_id" .== tcol "u" "id")
          query = select' [expr (tcol "recent" "total")]
            # fromAs "users" "u"
            # leftJoinLateral recent "recent"
            # formatInline
      query `shouldEqual`
        "SELECT \"recent\".\"total\" FROM \"users\" AS \"u\" LEFT JOIN LATERAL (SELECT \"total\" FROM \"orders\" WHERE \"orders\".\"user_id\" = \"u\".\"id\") AS \"recent\" ON (TRUE)"

    -- ON TRUE is never supplied implicitly: a lateral join takes whatever
    -- condition it is given, including a real one.
    it "keeps an ON condition of its own" do
      let recent = select' (cols ["total"]) # from "orders"
          query = select' [star]
            # fromAs "users" "u"
            # joinOn InnerJoin (lateral recent "recent") (tcol "recent" "total" .> int 100)
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"users\" AS \"u\" JOIN LATERAL (SELECT \"total\" FROM \"orders\") AS \"recent\" ON (\"recent\".\"total\" > 100)"

    it "CROSS JOIN LATERAL" do
      let recent = select' (cols ["total"])
            # from "orders"
            # where_ (tcol "orders" "user_id" .== tcol "u" "id")
          query = select' [star]
            # fromAs "users" "u"
            # joinRel (lateral recent "recent") Cross
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"users\" AS \"u\" CROSS JOIN LATERAL (SELECT \"total\" FROM \"orders\" WHERE \"orders\".\"user_id\" = \"u\".\"id\") AS \"recent\""

    it "FROM LATERAL" do
      let recent = select' (cols ["total"]) # from "orders"
          query = select' [starFrom "recent"]
            # fromLateral recent "recent"
            # formatInline
      query `shouldEqual`
        "SELECT \"recent\".* FROM LATERAL (SELECT \"total\" FROM \"orders\") AS \"recent\""

    -- The relation is emitted before its ON clause, and both before the outer
    -- WHERE, so that is the order the bindings are numbered in.
    it "numbers the relation's parameters before the ON clause's" do
      let recent = select' (cols ["total"])
            # from "orders"
            # where_ (tcol "orders" "status" .== str "paid")
          result = select' [star]
            # fromAs "users" "u"
            # joinOn InnerJoin (lateral recent "recent") (tcol "recent" "total" .> int 100)
            # where_ (tcol "u" "active" .== bool true)
            # format
      result.sql `shouldEqual`
        "SELECT * FROM \"users\" AS \"u\" JOIN LATERAL (SELECT \"total\" FROM \"orders\" WHERE \"orders\".\"status\" = $1) AS \"recent\" ON (\"recent\".\"total\" > $2) WHERE \"u\".\"active\" = $3"
      result.params `shouldEqual` [LitString "paid", LitInt 100, LitBoolean true]

  describe "common table expressions" do
    it "names an intermediate result set" do
      let recent = select' [star]
            # from "orders"
            # where_ (col "status" .== str "paid")
          query = select' [starFrom "recent"]
            # with_ "recent" recent
            # from "recent"
            # formatInline
      query `shouldEqual`
        "WITH \"recent\" AS (SELECT * FROM \"orders\" WHERE \"status\" = 'paid') SELECT \"recent\".* FROM \"recent\""

    it "comma-separates multiple CTEs within one WITH" do
      let query = select' [star]
            # with_ "a" (select' [expr (raw "1")])
            # with_ "b" (select' [expr (raw "2")])
            # from "b"
            # formatInline
      query `shouldEqual`
        "WITH \"a\" AS (SELECT 1), \"b\" AS (SELECT 2) SELECT * FROM \"b\""

    it "names the output columns" do
      let query = select' [star]
            # withCte (cteColumns ["n"] (cte "t" (select' [expr (raw "1")])))
            # from "t"
            # formatInline
      query `shouldEqual` "WITH \"t\" (\"n\") AS (SELECT 1) SELECT * FROM \"t\""

    it "quotes CTE names as identifiers" do
      let query = select' [star]
            # with_ "odd name" (select' [expr (raw "1")])
            # from "odd name"
            # formatInline
      query `shouldEqual` "WITH \"odd name\" AS (SELECT 1) SELECT * FROM \"odd name\""

    -- RECURSIVE is a property of the whole clause, so one recursive entry
    -- moves the keyword onto a WITH that also carries plain CTEs.
    it "one recursive CTE makes the whole clause recursive" do
      let query = select' [star]
            # with_ "a" (select' [expr (raw "1")])
            # withRecursive "b" (select' [expr (raw "2")])
            # from "b"
            # formatInline
      query `shouldEqual`
        "WITH RECURSIVE \"a\" AS (SELECT 1), \"b\" AS (SELECT 2) SELECT * FROM \"b\""

    -- A CTE precedes every other clause in the emitted SQL, so its parameters
    -- are numbered first.
    it "parameters are numbered before the outer query's" do
      let recent = select' [star]
            # from "orders"
            # where_ (col "status" .== str "paid")
          result = select' [starFrom "recent"]
            # with_ "recent" recent
            # from "recent"
            # where_ (tcol "recent" "total" .> int 100)
            # format
      result.sql `shouldEqual`
        "WITH \"recent\" AS (SELECT * FROM \"orders\" WHERE \"status\" = $1) SELECT \"recent\".* FROM \"recent\" WHERE \"recent\".\"total\" > $2"
      result.params `shouldEqual` [LitString "paid", LitInt 100]

    it "mergeQueries concatenates CTEs" do
      let base     = select' [star] # with_ "a" (select' [expr (raw "1")])
          override = emptyQuery # with_ "b" (select' [expr (raw "2")]) # from "b"
          query    = mergeQueries base override # formatInline
      query `shouldEqual` "WITH \"a\" AS (SELECT 1), \"b\" AS (SELECT 2) SELECT * FROM \"b\""

  describe "set operations" do
    it "UNION brackets both operands" do
      let query = select' (cols ["id"])
            # from "users"
            # union (select' (cols ["user_id"]) # from "orders")
            # formatInline
      query `shouldEqual`
        "(SELECT \"id\" FROM \"users\") UNION (SELECT \"user_id\" FROM \"orders\")"

    it "UNION ALL" do
      let query = select' (cols ["id"])
            # from "users"
            # unionAll (select' (cols ["user_id"]) # from "orders")
            # formatInline
      query `shouldEqual`
        "(SELECT \"id\" FROM \"users\") UNION ALL (SELECT \"user_id\" FROM \"orders\")"

    it "INTERSECT / INTERSECT ALL" do
      let a = select' (cols ["id"]) # from "users"
          b = select' (cols ["user_id"]) # from "orders"
      formatInline (a # intersect b) `shouldEqual`
        "(SELECT \"id\" FROM \"users\") INTERSECT (SELECT \"user_id\" FROM \"orders\")"
      formatInline (a # intersectAll b) `shouldEqual`
        "(SELECT \"id\" FROM \"users\") INTERSECT ALL (SELECT \"user_id\" FROM \"orders\")"

    it "EXCEPT / EXCEPT ALL" do
      let a = select' (cols ["id"]) # from "users"
          b = select' (cols ["user_id"]) # from "orders"
      formatInline (a # except b) `shouldEqual`
        "(SELECT \"id\" FROM \"users\") EXCEPT (SELECT \"user_id\" FROM \"orders\")"
      formatInline (a # exceptAll b) `shouldEqual`
        "(SELECT \"id\" FROM \"users\") EXCEPT ALL (SELECT \"user_id\" FROM \"orders\")"

    -- The bracketing is the assertion: a chain reads the same whatever
    -- PostgreSQL's own precedence between the operators is.
    it "chains left-associatively, each operand bracketed" do
      let query = select' (cols ["id"])
            # from "a"
            # union (select' (cols ["id"]) # from "b")
            # except (select' (cols ["id"]) # from "c")
            # formatInline
      query `shouldEqual`
        "((SELECT \"id\" FROM \"a\") UNION (SELECT \"id\" FROM \"b\")) EXCEPT (SELECT \"id\" FROM \"c\")"

    it "ORDER BY / LIMIT / OFFSET after the operation apply to the whole" do
      let query = select' (cols ["id"])
            # from "users"
            # union (select' (cols ["user_id"]) # from "orders")
            # orderBy [asc (col "id")]
            # limit 10
            # offset 5
            # formatInline
      query `shouldEqual`
        "(SELECT \"id\" FROM \"users\") UNION (SELECT \"user_id\" FROM \"orders\") ORDER BY \"id\" ASC LIMIT 10 OFFSET 5"

    -- The counterpart: an operand's own ORDER BY and LIMIT stay inside its
    -- brackets rather than being lifted onto the combined result.
    it "an operand keeps its own ORDER BY and LIMIT" do
      let query = select' (cols ["id"])
            # from "users"
            # orderBy [asc (col "id")]
            # limit 5
            # unionAll (select' (cols ["user_id"]) # from "orders" # limit 3)
            # formatInline
      query `shouldEqual`
        "(SELECT \"id\" FROM \"users\" ORDER BY \"id\" ASC LIMIT 5) UNION ALL (SELECT \"user_id\" FROM \"orders\" LIMIT 3)"

    it "numbers parameters left to right across both operands" do
      let result = select' (cols ["id"])
            # from "users"
            # where_ (col "active" .== bool true)
            # union
                ( select' (cols ["user_id"])
                    # from "orders"
                    # where_ (col "status" .== str "paid")
                )
            # format
      result.sql `shouldEqual`
        "(SELECT \"id\" FROM \"users\" WHERE \"active\" = $1) UNION (SELECT \"user_id\" FROM \"orders\" WHERE \"status\" = $2)"
      result.params `shouldEqual` [LitBoolean true, LitString "paid"]

    -- A WITH clause on a set operation covers the statement, so it is emitted
    -- once, ahead of both operands, and its parameters are numbered first.
    it "a WITH clause precedes both operands" do
      let result = select' (cols ["user_id"])
            # from "paid"
            # union (select' (cols ["user_id"]) # from "orders" # where_ (col "status" .== str "cancelled"))
            # with_ "paid" (select' (cols ["user_id"]) # from "orders" # where_ (col "status" .== str "paid"))
            # format
      result.sql `shouldEqual`
        "WITH \"paid\" AS (SELECT \"user_id\" FROM \"orders\" WHERE \"status\" = $1) (SELECT \"user_id\" FROM \"paid\") UNION (SELECT \"user_id\" FROM \"orders\" WHERE \"status\" = $2)"
      result.params `shouldEqual` [LitString "paid", LitString "cancelled"]

    it "nests as a derived table" do
      let query = select' [star]
            # fromSub
                ( select' (cols ["id"])
                    # from "users"
                    # union (select' (cols ["user_id"]) # from "orders")
                )
                "ids"
            # formatInline
      query `shouldEqual`
        "SELECT * FROM ((SELECT \"id\" FROM \"users\") UNION (SELECT \"user_id\" FROM \"orders\")) AS \"ids\""

    it "joins the two halves of a recursive CTE" do
      let query = select' [star]
            # withRecursive "counting"
                ( select' [as (raw "1") "n"]
                    # unionAll
                        ( select' [expr (binOp "+" (col "n") (int 1))]
                            # from "counting"
                            # where_ (col "n" .< int 5)
                        )
                )
            # from "counting"
            # formatInline
      query `shouldEqual`
        "WITH RECURSIVE \"counting\" AS ((SELECT 1 AS \"n\") UNION ALL (SELECT \"n\" + 1 FROM \"counting\" WHERE \"n\" < 5)) SELECT * FROM \"counting\""

  describe "GROUP BY / HAVING" do
    it "GROUP BY with HAVING and aggregation" do
      let query = select' [expr (col "department"), as (raw "COUNT(*)") "headcount"]
            # from "employees"
            # groupBy [col "department"]
            # having (raw "COUNT(*)" .> int 5)
            # orderBy [desc (col "headcount")]
            # formatInline
      query `shouldEqual`
        "SELECT \"department\", COUNT(*) AS \"headcount\" FROM \"employees\" GROUP BY \"department\" HAVING COUNT(*) > 5 ORDER BY \"headcount\" DESC"

    it "calling groupBy twice accumulates" do
      let query = select' [star]
            # from "users"
            # groupBy [col "department"]
            # groupBy [col "active"]
            # formatInline
      query `shouldEqual` "SELECT * FROM \"users\" GROUP BY \"department\", \"active\""

    it "GROUPING SETS" do
      let query = select' [star]
            # from "users"
            # groupBySets [[col "department"], [col "department", col "active"]]
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"users\" GROUP BY GROUPING SETS ((\"department\"), (\"department\", \"active\"))"

    it "the empty grouping set is the grand total" do
      let query = select' [star]
            # from "users"
            # groupBySets [[col "department"], []]
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"users\" GROUP BY GROUPING SETS ((\"department\"), ())"

    it "ROLLUP" do
      let query = select' [star]
            # from "users"
            # groupByRollup [col "department", col "active"]
            # formatInline
      query `shouldEqual` "SELECT * FROM \"users\" GROUP BY ROLLUP (\"department\", \"active\")"

    it "CUBE" do
      let query = select' [star]
            # from "users"
            # groupByCube [col "department", col "active"]
            # formatInline
      query `shouldEqual` "SELECT * FROM \"users\" GROUP BY CUBE (\"department\", \"active\")"

    it "a plain grouping and a ROLLUP share one clause" do
      let query = select' [star]
            # from "users"
            # groupBy [col "department"]
            # groupByRollup [col "active"]
            # formatInline
      query `shouldEqual` "SELECT * FROM \"users\" GROUP BY \"department\", ROLLUP (\"active\")"

    -- `GROUPING SETS ()`, `CUBE ()` and `ROLLUP ()` are not SQL PostgreSQL
    -- parses, and an empty list arises naturally when the grouping is driven by
    -- user input.
    it "an empty grouping adds nothing" do
      let base = select' [star] # from "users"
          query = base # groupBySets [] # groupByCube [] # groupByRollup [] # formatInline
      query `shouldEqual` "SELECT * FROM \"users\""

    it "numbers a grouping element's parameters after the WHERE clause's" do
      let query = format $ select' [as countStar "headcount"]
            # from "users"
            # where_ (col "active" .== bool true)
            # groupByRollup [coalesce [col "department", str "unknown"]]
      query.sql `shouldEqual`
        "SELECT COUNT(*) AS \"headcount\" FROM \"users\" WHERE \"active\" = $1 GROUP BY ROLLUP (COALESCE(\"department\", $2))"
      query.params `shouldEqual` [LitBoolean true, LitString "unknown"]

  describe "ORDER BY / LIMIT / OFFSET" do
    it "ORDER BY ASC" do
      let query = select' [star]
            # from "t"
            # orderBy [asc (col "name")]
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" ORDER BY \"name\" ASC"

    it "ORDER BY DESC" do
      let query = select' [star]
            # from "t"
            # orderBy [desc (col "created_at")]
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" ORDER BY \"created_at\" DESC"

    it "pagination" do
      let query = select' [star]
            # from "articles"
            # orderBy [desc (col "published_at")]
            # limit 10
            # offset 20
            # formatInline
      query `shouldEqual` "SELECT * FROM \"articles\" ORDER BY \"published_at\" DESC LIMIT 10 OFFSET 20"

  describe "mergeQueries" do
    it "override wins for scalar fields" do
      let base     = select' [star] # from "users" # where_ (col "active" .== bool true)
          override = emptyQuery # where_ (col "admin" .== bool false) # limit 5
          query    = mergeQueries base override # formatInline
      query `shouldEqual` "SELECT * FROM \"users\" WHERE (\"active\" = TRUE AND \"admin\" = FALSE) LIMIT 5"

    it "base wins when override fields are empty" do
      let query = mergeQueries (select' [star] # from "t" # limit 10) emptyQuery # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" LIMIT 10"

    it "joins are concatenated" do
      let base     = select' [star] # from "a" # innerJoin "b" (col "a.id" .== col "b.a_id")
          override = emptyQuery # innerJoin "c" (col "a.id" .== col "c.a_id")
          query    = mergeQueries base override # formatInline
      query `shouldEqual` "SELECT * FROM \"a\" JOIN \"b\" ON (\"a\".\"id\" = \"b\".\"a_id\") JOIN \"c\" ON (\"a\".\"id\" = \"c\".\"a_id\")"

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
