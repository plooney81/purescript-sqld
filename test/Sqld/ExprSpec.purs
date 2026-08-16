module Test.Sqld.ExprSpec where

import Prelude (Unit, discard, (#))
import Sqld.Core (FrameMode(..), Literal(..), emptyWindow)
import Sqld.Expr (and, avg, between, binOp, bool, cast, coalesce, col, count, countStar, currentRow, denseRank, exists, following, frameFrom, groups, in_, inSub, int, isNotNull, isNull, lag, lead, like, not, notIn, or, orderWindow, orderWindow', over, partitionBy, partitionBy', preceding, range, rank, raw, rowNumber, rows, str, sub, sum_, unboundedFollowing, unboundedPreceding, upper, withFrame, (.!=), (.==), (.>), (.>=))
import Sqld.Format (format, formatInline)
import Sqld.Select (as, asc, cols, desc, expr, from, orderBy, select', star, where_)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

exprSpec :: Spec Unit
exprSpec = describe "Sqld.Expr" do

  describe "comparison operators" do
    it "equality with int" do
      let query = select' [star]
            # from "t"
            # where_ (col "id" .== int 42)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"id\" = 42"

    it "equality with boolean" do
      let query = select' [star]
            # from "t"
            # where_ (col "active" .== bool true)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"active\" = TRUE"

    it "equality with string" do
      let query = select' [star]
            # from "t"
            # where_ (col "role" .== str "admin")
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"role\" = 'admin'"

    it "inequality" do
      let query = select' [star]
            # from "t"
            # where_ (col "status" .!= str "deleted")
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"status\" <> 'deleted'"

    it "greater-than" do
      let query = select' [star]
            # from "t"
            # where_ (col "age" .> int 18)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"age\" > 18"

    it "greater-than-or-equal" do
      let query = select' [star]
            # from "t"
            # where_ (col "score" .>= int 100)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"score\" >= 100"

    it "IS NULL" do
      let query = select' [star]
            # from "t"
            # where_ (isNull (col "deleted_at"))
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"deleted_at\" IS NULL"

    it "IS NOT NULL" do
      let query = select' [star]
            # from "t"
            # where_ (isNotNull (col "email"))
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"email\" IS NOT NULL"

    it "NOT" do
      let query = select' [star]
            # from "t"
            # where_ (not (col "deleted" .== bool true))
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE NOT \"deleted\" = TRUE"

    it "raw passthrough" do
      let query = select' [star]
            # from "t"
            # where_ (raw "created_at > NOW() - INTERVAL '7 days'")
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE created_at > NOW() - INTERVAL '7 days'"

  describe "AND / OR" do
    it "and of multiple conditions" do
      let query = select' [star]
            # from "t"
            # where_ (and [col "a" .== int 1, col "b" .== int 2, col "c" .== int 3])
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE (\"a\" = 1 AND \"b\" = 2 AND \"c\" = 3)"

    it "or of multiple conditions" do
      let query = select' [star]
            # from "t"
            # where_ (or [col "x" .== int 1, col "x" .== int 2])
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE (\"x\" = 1 OR \"x\" = 2)"

    it "nested AND inside OR" do
      let query = select' [star]
            # from "users"
            # where_
                (and [ or [col "status" .== str "active", col "status" .== str "pending"]
                     , col "age" .>= int 18
                     ])
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"users\" WHERE ((\"status\" = 'active' OR \"status\" = 'pending') AND \"age\" >= 18)"

    it "empty and produces TRUE" do
      let query = select' [star]
            # from "t"
            # where_ (and [])
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE TRUE"

    it "empty or produces FALSE" do
      let query = select' [star]
            # from "t"
            # where_ (or [])
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE FALSE"

  describe "IN / NOT IN / BETWEEN / LIKE" do
    it "IN list" do
      let query = select' [star]
            # from "products"
            # where_ ((col "category_id") `in_` [int 1, int 2, int 3])
            # formatInline
      query `shouldEqual` "SELECT * FROM \"products\" WHERE \"category_id\" IN (1, 2, 3)"

    it "NOT IN list" do
      let query = select' [star]
            # from "t"
            # where_ ((col "status") `notIn` [str "deleted", str "banned"])
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"status\" NOT IN ('deleted', 'banned')"

    -- "id" IN () is a syntax error, so an empty list folds to the constant it
    -- means: nothing is a member of the empty set.
    it "IN with an empty list produces FALSE" do
      let query = select' [star]
            # from "t"
            # where_ ((col "id") `in_` [])
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE FALSE"

    it "NOT IN with an empty list produces TRUE" do
      let query = select' [star]
            # from "t"
            # where_ ((col "id") `notIn` [])
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE TRUE"

    -- The folded constant sits under AND, OR and NOT in turn: each is a
    -- position where a badly bracketed operand would change the meaning.
    it "the folded constant is bracket-safe as an operand" do
      let query = select' [star]
            # from "t"
            # where_
                (and [ col "active" .== bool true
                     , or [ (col "id") `in_` [], (col "flag") `notIn` [] ]
                     , not ((col "id") `in_` [])
                     ])
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"t\" WHERE (\"active\" = TRUE AND (FALSE OR TRUE) AND NOT FALSE)"

    -- Folding must not consume a parameter slot, or every binding after it
    -- shifts by one.
    it "folding leaves parameter numbering untouched" do
      let result = select' [star]
            # from "t"
            # where_
                (and [ col "a" .== int 1
                     , (col "id") `in_` []
                     , col "b" .== int 2
                     ])
            # format
      result.sql `shouldEqual`
        "SELECT * FROM \"t\" WHERE (\"a\" = $1 AND FALSE AND \"b\" = $2)"
      result.params `shouldEqual` [LitInt 1, LitInt 2]

    it "BETWEEN" do
      let query = select' [star]
            # from "orders"
            # where_ (between (col "total") (int 100) (int 500))
            # formatInline
      query `shouldEqual` "SELECT * FROM \"orders\" WHERE \"total\" BETWEEN 100 AND 500"

    it "LIKE" do
      let query = select' [star]
            # from "users"
            # where_ (like (col "email") "%@example.com")
            # formatInline
      query `shouldEqual` "SELECT * FROM \"users\" WHERE \"email\" LIKE '%@example.com'"

  describe "function application" do
    it "COUNT(*)" do
      let query = select' [as countStar "n"]
            # from "t"
            # formatInline
      query `shouldEqual` "SELECT COUNT(*) AS \"n\" FROM \"t\""

    it "function of a column" do
      let query = select' [expr (count (col "id"))]
            # from "t"
            # formatInline
      query `shouldEqual` "SELECT COUNT(\"id\") FROM \"t\""

    it "nested application with multiple arguments" do
      let query = select' [as (upper (coalesce [col "email", str "none"])) "e"]
            # from "t"
            # formatInline
      query `shouldEqual` "SELECT UPPER(COALESCE(\"email\", 'none')) AS \"e\" FROM \"t\""

  describe "operator precedence" do
    -- The parentheses below are the whole point: PostgreSQL accepts both
    -- "age" + 1 * 2 and ("age" + 1) * 2, and they mean different things.
    it "brackets a looser-binding left operand" do
      let query = select' [star]
            # from "t"
            # where_ (binOp "*" (binOp "+" (col "age") (int 1)) (int 2) .> int 10)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE (\"age\" + 1) * 2 > 10"

    it "omits brackets when precedence already agrees" do
      let query = select' [star]
            # from "t"
            # where_ (binOp "+" (col "a") (binOp "*" (col "b") (int 2)) .> int 3)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"a\" + \"b\" * 2 > 3"

    -- Left-associativity: a - (b - c) is not a - b - c.
    it "brackets an equal-precedence right operand" do
      let query = select' [star]
            # from "t"
            # where_ (binOp "-" (col "a") (binOp "-" (col "b") (col "c")) .> int 0)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"a\" - (\"b\" - \"c\") > 0"

    it "treats an unknown operator as a generic one" do
      let query = select' [star]
            # from "t"
            # where_ (binOp "@>" (col "tags") (raw "ARRAY['a']"))
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"tags\" @> ARRAY['a']"

  describe "casts" do
    it "atom operand needs no brackets" do
      let query = select' [as (cast (col "id") "text") "id_text"]
            # from "t"
            # formatInline
      query `shouldEqual` "SELECT \"id\"::text AS \"id_text\" FROM \"t\""

    it "compound operand is bracketed" do
      let query = select' [star]
            # from "t"
            # where_ (cast (binOp "+" (col "age") (int 1)) "numeric" .> int 2)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE (\"age\" + 1)::numeric > 2"

  describe "subqueries" do
    it "scalar subquery in the select list" do
      let orders = select' [expr countStar] # from "orders"
          query = select' [expr (col "id"), as (sub orders) "n"]
            # from "users"
            # formatInline
      query `shouldEqual`
        "SELECT \"id\", (SELECT COUNT(*) FROM \"orders\") AS \"n\" FROM \"users\""

    it "IN with a subquery" do
      let orders = select' [expr (col "user_id")] # from "orders"
          query = select' [star]
            # from "users"
            # where_ (inSub (col "id") orders)
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"users\" WHERE \"id\" IN (SELECT \"user_id\" FROM \"orders\")"

    it "EXISTS" do
      let orders = select' [expr (raw "1")] # from "orders"
          query = select' [star]
            # from "users"
            # where_ (exists orders)
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"users\" WHERE EXISTS (SELECT 1 FROM \"orders\")"

    -- A subquery must not restart parameter numbering, or the driver receives
    -- the bindings in the wrong order.
    it "parameters interleave with the outer query" do
      let orders = select' [expr (col "user_id")]
            # from "orders"
            # where_ (col "status" .== str "paid")
          result = select' [star]
            # from "users"
            # where_ (and [ col "active" .== bool true
                          , inSub (col "id") orders
                          , col "age" .> int 21
                          ])
            # format
      result.sql `shouldEqual`
        "SELECT * FROM \"users\" WHERE (\"active\" = $1 AND \"id\" IN (SELECT \"user_id\" FROM \"orders\" WHERE \"status\" = $2) AND \"age\" > $3)"
      result.params `shouldEqual` [LitBoolean true, LitString "paid", LitInt 21]

  describe "window functions" do
    it "PARTITION BY and ORDER BY" do
      let query = select' [as (rowNumber `over`
                                  ( partitionBy' [col "department"]
                                      # orderWindow [desc (col "age")]
                                  )) "rn"]
            # from "users"
            # formatInline
      query `shouldEqual`
        "SELECT ROW_NUMBER() OVER (PARTITION BY \"department\" ORDER BY \"age\" DESC) AS \"rn\" FROM \"users\""

    -- OVER () is valid SQL: one partition, unordered.
    it "an empty window is OVER ()" do
      let query = select' [as (countStar `over` emptyWindow) "total"]
            # from "users"
            # formatInline
      query `shouldEqual` "SELECT COUNT(*) OVER () AS \"total\" FROM \"users\""

    -- `partitionBy'` starts from `emptyWindow` the way `select'` starts from
    -- `emptyQuery`, so the primed and unprimed forms agree.
    it "partitionBy' matches partitionBy over emptyWindow" do
      let sugared = select' [as (rank `over` partitionBy' [col "department"]) "r"]
            # from "users"
            # formatInline
          spelled = select' [as (rank `over` partitionBy [col "department"] emptyWindow) "r"]
            # from "users"
            # formatInline
      sugared `shouldEqual` spelled

    it "PARTITION BY alone" do
      let query = select' [as (rank `over` partitionBy' [col "department"]) "r"]
            # from "users"
            # formatInline
      query `shouldEqual`
        "SELECT RANK() OVER (PARTITION BY \"department\") AS \"r\" FROM \"users\""

    it "ORDER BY alone" do
      let query = select' [as (denseRank `over` orderWindow' [asc (col "score")]) "r"]
            # from "users"
            # formatInline
      query `shouldEqual`
        "SELECT DENSE_RANK() OVER (ORDER BY \"score\" ASC) AS \"r\" FROM \"users\""

    -- A named window pipes together with `#` and is shared by `over`.
    it "an aggregate over a named window" do
      let byUser = partitionBy' [col "user_id"]
          query = select' [as (sum_ (col "total") `over` byUser) "user_total"]
            # from "orders"
            # formatInline
      query `shouldEqual`
        "SELECT SUM(\"total\") OVER (PARTITION BY \"user_id\") AS \"user_total\" FROM \"orders\""

    it "lag and lead take an offset" do
      let window = orderWindow' [asc (col "placed_at")]
          query = select' [ as (lag (col "total") 1 `over` window) "prev"
                          , as (lead (col "total") 2 `over` window) "next"
                          ]
            # from "orders"
            # formatInline
      query `shouldEqual`
        "SELECT LAG(\"total\", 1) OVER (ORDER BY \"placed_at\" ASC) AS \"prev\", LEAD(\"total\", 2) OVER (ORDER BY \"placed_at\" ASC) AS \"next\" FROM \"orders\""

    it "frames: ROWS BETWEEN" do
      let query = select' [as (sum_ (col "total") `over`
                                  ( orderWindow' [asc (col "placed_at")]
                                      # withFrame (rows unboundedPreceding currentRow)
                                  )) "running"]
            # from "orders"
            # formatInline
      query `shouldEqual`
        "SELECT SUM(\"total\") OVER (ORDER BY \"placed_at\" ASC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS \"running\" FROM \"orders\""

    -- Offsets are emitted literally: a frame carries no parameters.
    it "frames: offset bounds" do
      let result = select' [as (avg (col "total") `over`
                                   ( orderWindow' [asc (col "placed_at")]
                                       # withFrame (rows (preceding 3) (following 1))
                                   )) "moving"]
            # from "orders"
            # format
      result.sql `shouldEqual`
        "SELECT AVG(\"total\") OVER (ORDER BY \"placed_at\" ASC ROWS BETWEEN 3 PRECEDING AND 1 FOLLOWING) AS \"moving\" FROM \"orders\""
      result.params `shouldEqual` []

    it "frames: RANGE and GROUPS" do
      let rendered f = formatInline
            ( select' [as (sum_ (col "total") `over`
                              (orderWindow' [asc (col "placed_at")] # withFrame f)) "t"]
                # from "orders"
            )
      rendered (range currentRow unboundedFollowing) `shouldEqual`
        "SELECT SUM(\"total\") OVER (ORDER BY \"placed_at\" ASC RANGE BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) AS \"t\" FROM \"orders\""
      rendered (groups unboundedPreceding currentRow) `shouldEqual`
        "SELECT SUM(\"total\") OVER (ORDER BY \"placed_at\" ASC GROUPS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS \"t\" FROM \"orders\""

    -- The one-bound form runs from the bound to the current row.
    it "frames: the one-bound form omits BETWEEN" do
      let query = select' [as (sum_ (col "total") `over`
                                  ( orderWindow' [asc (col "placed_at")]
                                      # withFrame (frameFrom Rows unboundedPreceding)
                                  )) "t"]
            # from "orders"
            # formatInline
      query `shouldEqual`
        "SELECT SUM(\"total\") OVER (ORDER BY \"placed_at\" ASC ROWS UNBOUNDED PRECEDING) AS \"t\" FROM \"orders\""

    -- OVER binds tighter than any operator, so the window function is an atom
    -- and the arithmetic around it brackets nothing.
    it "binds tighter than an operator" do
      let query = select' [as (binOp "-" (rowNumber `over` emptyWindow) (int 1)) "zero_based"]
            # from "users"
            # formatInline
      query `shouldEqual`
        "SELECT ROW_NUMBER() OVER () - 1 AS \"zero_based\" FROM \"users\""

    it "a window function is legal in ORDER BY" do
      let query = select' (cols ["name"])
            # from "users"
            # orderBy [asc (rank `over` orderWindow' [desc (col "score")])]
            # formatInline
      query `shouldEqual`
        "SELECT \"name\" FROM \"users\" ORDER BY RANK() OVER (ORDER BY \"score\" DESC) ASC"

    -- A window sits in the select list, so its parameters are numbered before
    -- the WHERE clause's.
    it "numbers a window's parameters in emitted order" do
      let result = select' [as (countStar `over`
                                   partitionBy' [coalesce [col "department", str "unknown"]])
                              "headcount"]
            # from "users"
            # where_ (col "active" .== bool true)
            # format
      result.sql `shouldEqual`
        "SELECT COUNT(*) OVER (PARTITION BY COALESCE(\"department\", $1)) AS \"headcount\" FROM \"users\" WHERE \"active\" = $2"
      result.params `shouldEqual` [LitString "unknown", LitBoolean true]
