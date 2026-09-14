module Test.Sqld.FormatSpec where

import Prelude (Unit, discard, negate, (#), (<>))
import Data.String (trim)
import Sqld.Core (JoinCondition(..), JoinType(..), Literal(..))
import Sqld.Expr (and, between, binOp, bool, cast, col, countStar, currentRow, exists, in_, inSub, int, null, num, orderWindow, over, partitionBy', raw, rowNumber, rows, str, sub, tcol, unboundedPreceding, withFrame, (.<), (.==))
import Sqld.Format (format, formatInline, formatPretty, quoteIdent)
import Sqld.Select (as, asc, cols, derived, desc, except, expr, forUpdate, from, fromAs, fromSub, joinOn, joinRel, lateral, leftJoin, limit, orderBy, select', skipLocked, star, starFrom, union, unionAll, where_, with_)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual)

formatSpec :: Spec Unit
formatSpec = describe "Sqld.Format" do

  describe "value rendering" do
    it "integer" do
      let query = select' [star]
            # from "t"
            # where_ (col "id" .== int 42)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"id\" = 42"

    it "string with single-quote escaping" do
      let query = select' [star]
            # from "t"
            # where_ (col "name" .== str "O'Brien")
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"name\" = 'O''Brien'"

    it "TRUE / FALSE" do
      let query = select' [star]
            # from "t"
            # where_ (col "active" .== bool true)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"active\" = TRUE"

    it "NULL" do
      let query = select' [star]
            # from "t"
            # where_ (col "x" .== null)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"x\" = NULL"

    -- `::` binds tighter than a leading minus, so an unbracketed `-1::text`
    -- would parse as `-(1::text)`. The parameterised form is immune — `$1` is
    -- an atom — which is why only the inline forms bracket.
    it "negative numbers are bracketed" do
      let query = select' [ expr (cast (int (-1)) "text"), expr (cast (num (-1.5)) "text") ]
            # formatInline
      query `shouldEqual` "SELECT (-1)::text, (-1.5)::text"

    it "a bound negative number is not" do
      let result = select' [ expr (cast (int (-1)) "text") ] # format
      result.sql `shouldEqual` "SELECT $1::text"
      result.params `shouldEqual` [ LitInt (-1) ]

  describe "non-associative operators" do
    -- PostgreSQL rejects `a BETWEEN b AND c IN (…)` and `a < b = c` outright,
    -- so the left operand is bracketed on those two levels exactly as the right
    -- one is. Everywhere else the printer stays left-associative.
    it "brackets a BETWEEN under IN" do
      let query = select' [star]
            # from "t"
            # where_ (in_ (between (col "age") (int 18) (int 65)) [bool true])
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE (\"age\" BETWEEN 18 AND 65) IN (TRUE)"

    it "brackets a comparison under a comparison" do
      let query = select' [star]
            # from "t"
            # where_ ((col "age" .< int 5) .== bool true)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE (\"age\" < 5) = TRUE"

    it "leaves a left-associative operator alone" do
      let query = select' [star]
            # from "t"
            # where_ (binOp "-" (binOp "-" (col "a") (col "b")) (col "c") .== int 0)
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE \"a\" - \"b\" - \"c\" = 0"

  describe "substitution order" do
    it "left-to-right across the whole query" do
      let query = select' [star]
            # from "t"
            # where_ (and [col "a" .== int 1, col "b" .== str "x", col "c" .== bool false])
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE (\"a\" = 1 AND \"b\" = 'x' AND \"c\" = FALSE)"

    it "JOIN ON values come before WHERE values" do
      let query = select' [star]
            # from "orders"
            # leftJoin "users" (col "user_id" .== int 99)
            # where_ (col "status" .== str "open")
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"orders\" LEFT JOIN \"users\" ON (\"user_id\" = 99) WHERE \"status\" = 'open'"

    -- A CROSS JOIN carries no condition of its own, but its target may be a
    -- derived table that carries parameters, and those still land where the
    -- relation does — ahead of the WHERE clause's.
    it "a cross-joined derived table's values come before WHERE values" do
      let paid = select' (cols ["user_id"])
            # from "orders"
            # where_ (col "status" .== str "paid")
          result = select' [star]
            # fromAs "users" "u"
            # joinRel (derived paid "paid") Cross
            # where_ (tcol "u" "active" .== bool true)
            # format
      result.sql `shouldEqual`
        "SELECT * FROM \"users\" AS \"u\" CROSS JOIN (SELECT \"user_id\" FROM \"orders\" WHERE \"status\" = $1) AS \"paid\" WHERE \"u\".\"active\" = $2"
      result.params `shouldEqual` [LitString "paid", LitBoolean true]

  describe "formatPretty" do
    it "clause per line" do
      let query = select' (cols ["id", "name"])
            # from "users"
            # where_ (col "id" .== int 42)
            # formatPretty
      query `shouldEqual` trim """
SELECT "id", "name"
FROM "users"
WHERE "id" = 42
"""

    it "scalar subquery in the select list" do
      let query = select'
            [ expr (tcol "u" "name")
            , as
                ( sub
                    ( select' [expr countStar]
                        # from "orders"
                        # where_ (tcol "orders" "user_id" .== tcol "u" "id")
                    )
                )
                "order_count"
            ]
            # fromAs "users" "u"
            # formatPretty
      query `shouldEqual` trim """
SELECT "u"."name", (
  SELECT COUNT(*)
  FROM "orders"
  WHERE "orders"."user_id" = "u"."id"
) AS "order_count"
FROM "users" AS "u"
"""

    it "EXISTS subquery" do
      let query = select' [star]
            # fromAs "users" "u"
            # where_
                ( exists
                    ( select' [expr (raw "1")]
                        # from "orders"
                        # where_ (tcol "orders" "user_id" .== tcol "u" "id")
                    )
                )
            # formatPretty
      query `shouldEqual` trim """
SELECT *
FROM "users" AS "u"
WHERE EXISTS (
  SELECT 1
  FROM "orders"
  WHERE "orders"."user_id" = "u"."id"
)
"""

    it "derived table in FROM" do
      let query = select' [starFrom "paid"]
            # fromSub
                ( select' (cols ["id", "total"])
                    # from "orders"
                    # where_ (col "status" .== str "paid")
                )
                "paid"
            # formatPretty
      query `shouldEqual` trim """
SELECT "paid".*
FROM (
  SELECT "id", "total"
  FROM "orders"
  WHERE "status" = 'paid'
) AS "paid"
"""

    -- LATERAL sits in front of the bracket, so the block below it is laid out
    -- exactly as a derived table's is.
    it "lateral join target in FROM" do
      let query = select' [expr (tcol "recent" "total")]
            # fromAs "users" "u"
            # joinOn InnerJoin
                ( lateral
                    ( select' (cols ["total"])
                        # from "orders"
                        # where_ (tcol "orders" "user_id" .== tcol "u" "id")
                    )
                    "recent"
                )
                (and [])
            # formatPretty
      query `shouldEqual` trim """
SELECT "recent"."total"
FROM "users" AS "u"
JOIN LATERAL (
  SELECT "total"
  FROM "orders"
  WHERE "orders"."user_id" = "u"."id"
) AS "recent" ON (TRUE)
"""

    it "indents one level per level of nesting" do
      let query = select' [starFrom "t"]
            # fromSub
                ( select' (cols ["id"])
                    # from "orders"
                    # where_
                        ( inSub (col "user_id")
                            ( select' (cols ["id"])
                                # from "users"
                                # where_ (col "active" .== bool true)
                            )
                        )
                )
                "t"
            # formatPretty
      query `shouldEqual` trim """
SELECT "t".*
FROM (
  SELECT "id"
  FROM "orders"
  WHERE "user_id" IN (
    SELECT "id"
    FROM "users"
    WHERE "active" = TRUE
  )
) AS "t"
"""

    it "CTE body gets an indented block of its own" do
      let query = select' [starFrom "paid"]
            # with_ "paid"
                ( select' (cols ["id", "total"])
                    # from "orders"
                    # where_ (col "status" .== str "paid")
                )
            # from "paid"
            # formatPretty
      query `shouldEqual` trim """
WITH "paid" AS (
  SELECT "id", "total"
  FROM "orders"
  WHERE "status" = 'paid'
)
SELECT "paid".*
FROM "paid"
"""

    it "one CTE per line" do
      let query = select' [star]
            # with_ "paid"
                ( select' (cols ["user_id"])
                    # from "orders"
                    # where_ (col "status" .== str "paid")
                )
            # with_ "recent"
                ( select' (cols ["user_id"])
                    # from "orders"
                )
            # from "paid"
            # formatPretty
      query `shouldEqual` trim """
WITH "paid" AS (
  SELECT "user_id"
  FROM "orders"
  WHERE "status" = 'paid'
),
"recent" AS (
  SELECT "user_id"
  FROM "orders"
)
SELECT *
FROM "paid"
"""

    it "set operation: one operand block per line" do
      let query = select' (cols ["id"])
            # from "users"
            # where_ (col "active" .== bool true)
            # unionAll (select' (cols ["user_id"]) # from "orders")
            # orderBy [asc (col "id")]
            # formatPretty
      query `shouldEqual` trim """
(
  SELECT "id"
  FROM "users"
  WHERE "active" = TRUE
)
UNION ALL
(
  SELECT "user_id"
  FROM "orders"
)
ORDER BY "id" ASC
"""

    it "set operation: a chained operand indents one level further" do
      let query = select' (cols ["id"])
            # from "a"
            # union (select' (cols ["id"]) # from "b")
            # except (select' (cols ["id"]) # from "c")
            # formatPretty
      query `shouldEqual` trim """
(
  (
    SELECT "id"
    FROM "a"
  )
  UNION
  (
    SELECT "id"
    FROM "b"
  )
)
EXCEPT
(
  SELECT "id"
  FROM "c"
)
"""

    -- A window is part of an expression rather than a clause of its own, so it
    -- stays on one line however deeply the query is broken up.
    it "a window stays on one line" do
      let window = partitionBy' [col "department"]
            # orderWindow [desc (col "age")]
            # withFrame (rows unboundedPreceding currentRow)
          query = select' (cols ["name"] <> [as (rowNumber `over` window) "rn"])
            # from "users"
            # where_ (col "active" .== bool true)
            # formatPretty
      query `shouldEqual` trim """
SELECT "name", ROW_NUMBER() OVER (PARTITION BY "department" ORDER BY "age" DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS "rn"
FROM "users"
WHERE "active" = TRUE
"""

    -- A locking clause is a clause of the query, so it gets a line of its own,
    -- last of all.
    it "the locking clause is a clause like any other" do
      let query = select' [star]
            # from "orders"
            # where_ (col "status" .== str "pending")
            # orderBy [asc (col "placed_at")]
            # limit 10
            # forUpdate
            # skipLocked
            # formatPretty
      query `shouldEqual` trim """
SELECT *
FROM "orders"
WHERE "status" = 'pending'
ORDER BY "placed_at" ASC
LIMIT 10
FOR UPDATE SKIP LOCKED
"""

    it "leaves formatInline on one line" do
      let query = select' [star]
            # from "users"
            # where_
                ( inSub (col "id")
                    (select' (cols ["user_id"]) # from "orders")
                )
            # formatInline
      query `shouldEqual`
        "SELECT * FROM \"users\" WHERE \"id\" IN (SELECT \"user_id\" FROM \"orders\")"

  -- The names below are the ones that end their quoting and continue as SQL of
  -- their own if `quoteIdent` ever stops doubling an embedded `"`.
  -- `Test.Sqld.Corpus` carries the same names against a schema that really has
  -- them, so PostgreSQL is seen to read each one back as a single identifier;
  -- these pin the string sqld emits.
  describe "identifier quoting" do
    it "doubles an embedded double quote" do
      quoteIdent "a\"b" `shouldEqual` "\"a\"\"b\""

    it "keeps a breakout attempt inside one identifier" do
      let query = select' (cols ["id"])
            # from "x\" FROM \"secrets\" --"
            # formatInline
      query `shouldEqual`
        "SELECT \"id\" FROM \"x\"\" FROM \"\"secrets\"\" --\""

    it "quotes a trailing line comment" do
      let query = select' (cols ["id -- "]) # from "users" # formatInline
      query `shouldEqual` "SELECT \"id -- \" FROM \"users\""

    it "quotes a statement terminator" do
      let query = select' (cols ["id"]) # from "users; DROP TABLE users" # formatInline
      query `shouldEqual` "SELECT \"id\" FROM \"users; DROP TABLE users\""

    it "quotes an alias" do
      let query = select' [ as (col "id") "al\"ias" ] # from "users" # formatInline
      query `shouldEqual` "SELECT \"id\" AS \"al\"\"ias\" FROM \"users\""

    it "quotes a CTE name" do
      let query = select' (cols ["id"])
            # from "c\"te"
            # with_ "c\"te" (select' (cols ["id"]) # from "users")
            # formatInline
      query `shouldEqual`
        "WITH \"c\"\"te\" AS (SELECT \"id\" FROM \"users\") SELECT \"id\" FROM \"c\"\"te\""

    -- Neither is valid PostgreSQL, so neither reaches the validation corpus.
    -- sqld quotes them and lets the server say so, which is the documented
    -- policy rather than an oversight: the empty name is a zero-length
    -- delimited identifier, and the NUL stays inside the quotes, so a driver
    -- that truncates there leaves an unterminated identifier rather than a
    -- shorter query that runs.
    it "quotes the empty identifier" do
      quoteIdent "" `shouldEqual` "\"\""

    it "passes a NUL byte through, inside the quotes" do
      quoteIdent ("a" <> nul <> "b") `shouldEqual` ("\"a" <> nul <> "b\"")

    it "splits `col` on the first dot only" do
      let query = select' [ expr (col "a.b.c") ] # formatInline
      query `shouldEqual` "SELECT \"a\".\"b.c\""

    it "never splits `tcol`" do
      let query = select' [ expr (tcol "t" "a.b") ] # formatInline
      query `shouldEqual` "SELECT \"t\".\"a.b\""

    it "binds a value that looks like SQL rather than quoting it" do
      let query = format (select' [star] # from "users" # where_ (col "name" .== str "'; DROP TABLE users; --"))
      query.sql `shouldEqual` "SELECT * FROM \"users\" WHERE \"name\" = $1"
      query.params `shouldEqual` [ LitString "'; DROP TABLE users; --" ]

  -- Substituting `$1` … `$n` into the finished string would re-read what the
  -- previous substitution wrote. The inline formatters print each value where
  -- its placeholder would have gone instead, which is what these two hold to.
  describe "inlining is a single pass" do
    it "leaves a value that looks like a placeholder alone" do
      let query = select' [star]
            # from "t"
            # where_ (and [ col "age" .== int 7, col "name" .== str "$1" ])
            # formatInline
      query `shouldEqual` "SELECT * FROM \"t\" WHERE (\"age\" = 7 AND \"name\" = '$1')"

    it "leaves a placeholder inside a raw fragment alone" do
      let query = select' [ expr (raw "'$1'") ]
            # from "t"
            # where_ (col "age" .== int 7)
            # formatInline
      query `shouldEqual` "SELECT '$1' FROM \"t\" WHERE \"age\" = 7"

  describe "integration" do
    it "multi-column select with WHERE" do
      let query = select' (cols ["id", "name", "email"])
            # from "users"
            # where_ (col "id" .== int 42)
            # formatInline
      query `shouldEqual` "SELECT \"id\", \"name\", \"email\" FROM \"users\" WHERE \"id\" = 42"

-- | A NUL byte, spelled out so the escape cannot run into the character after
-- | it: `"\x0b"` is one hex escape, not a NUL and a `b`.
nul :: String
nul = "\x0"
