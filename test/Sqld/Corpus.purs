-- | The validation corpus: one canonical set of queries that every backend
-- | check runs against.
-- |
-- | Two things consume this module:
-- |
-- |   * `Test.Sqld.CorpusSpec` — asserts the corpus exercises every AST
-- |     constructor, so coverage cannot silently regress.
-- |   * `Test.Sqld.CorpusEmit` — writes the formatted SQL to
-- |     `test-artifacts/corpus.json`, which `scripts/validate-sql.mjs` feeds
-- |     through a real PostgreSQL server.
-- |
-- | Every table and column referenced here MUST exist in
-- | `test/fixtures/schema.sql`. Postgres runs full parse analysis on these
-- | queries, so a typo in a column name is a test failure — that is the point.
module Test.Sqld.Corpus
  ( CorpusEntry
  , corpus
  , coveredTags
  , requiredTags
  , missingTags
  ) where

import Prelude hiding (between, not)

import Data.Array ((:))
import Data.Array (concatMap, difference, nub, null, sort) as Array
import Data.Maybe (Maybe(..), isJust)
import Sqld.Core (Expr(..), JoinType(..), Literal(..), OrderDir(..), OrderExpr, Query, Relation(..), SelectExpr(..), emptyQuery)
import Sqld.Expr (and, between, binOp, bool, cast, coalesce, col, count, countStar, exists, ilike, in_, inSub, int, isNotNull, isNull, like, not, notExists, notILike, notIn, notInSub, notLike, null, num, or, raw, str, sub, tcol, upper, (.!=), (.<), (.<=), (.==), (.>), (.>=))
import Sqld.Select (as, asc, colAs, cols, derived, desc, expr, from, fromAs, fromSub, fullJoinAs, groupBy, having, innerJoin, joinOn, leftJoinAs, limit, offset, orderBy, rightJoin, select, star, starFrom, tcolAs, where_)

type CorpusEntry = { name :: String, query :: Query }

-- ---------------------------------------------------------------------------
-- The corpus
-- ---------------------------------------------------------------------------

corpus :: Array CorpusEntry
corpus =
  [ { name: "select-star"
    , query: emptyQuery # select [ star ] # from "users"
    }

  , { name: "select-columns"
    , query: emptyQuery # select (cols [ "id", "name", "email" ]) # from "users"
    }

  , { name: "select-alias"
    , query: emptyQuery # select [ as (col "created_at") "ts" ] # from "users"
    }

  , { name: "select-col-alias-shorthand"
    , query: emptyQuery # select [ colAs "created_at" "ts" ] # from "users"
    }

  , { name: "select-qualified-columns"
    , query: emptyQuery
        # select [ expr (tcol "u" "id"), expr (tcol "u" "name") ]
        # fromAs "users" "u"
    }

  , { name: "select-qualified-alias"
    , query: emptyQuery
        # select [ tcolAs "u" "created_at" "ts" ]
        # fromAs "users" "u"
    }

  , { name: "select-star-from-alias"
    , query: emptyQuery # select [ starFrom "u" ] # fromAs "users" "u"
    }

  , { name: "select-raw-expression"
    , query: emptyQuery # select [ expr (raw "1 + 1") ]
    }

  , { name: "select-aggregate-alias"
    , query: emptyQuery
        # select [ expr (col "department"), as (raw "COUNT(*)") "n" ]
        # from "users"
        # groupBy [ col "department" ]
    }

  -- Literals -----------------------------------------------------------------

  , { name: "literal-int"
    , query: emptyQuery # select [ star ] # from "users" # where_ (col "id" .== int 42)
    }

  , { name: "literal-string-with-quote"
    , query: emptyQuery # select [ star ] # from "users" # where_ (col "name" .!= str "O'Brien")
    }

  , { name: "literal-number"
    , query: emptyQuery # select [ star ] # from "users" # where_ (col "score" .>= num 4.5)
    }

  , { name: "literal-boolean"
    , query: emptyQuery # select [ star ] # from "users" # where_ (col "active" .== bool true)
    }

  , { name: "literal-null"
    , query: emptyQuery # select [ star ] # from "users" # where_ (col "email" .== null)
    }

  -- Comparison operators -----------------------------------------------------

  , { name: "comparison-operators"
    , query: emptyQuery
        # select [ star ]
        # from "users"
        # where_
            ( and
                [ col "age" .> int 18
                , col "age" .>= int 21
                , col "age" .< int 65
                , col "age" .<= int 64
                ]
            )
    }

  -- Boolean combinators ------------------------------------------------------

  , { name: "boolean-or"
    , query: emptyQuery
        # select [ star ]
        # from "users"
        # where_ (or [ col "active" .== bool true, isNull (col "email") ])
    }

  , { name: "boolean-not"
    , query: emptyQuery
        # select [ star ]
        # from "users"
        # where_ (not (col "active" .== bool true))
    }

  , { name: "boolean-and-empty"
    , query: emptyQuery # select [ star ] # from "users" # where_ (and [])
    }

  , { name: "boolean-or-empty"
    , query: emptyQuery # select [ star ] # from "users" # where_ (or [])
    }

  -- Null tests ---------------------------------------------------------------

  , { name: "is-null-and-is-not-null"
    , query: emptyQuery
        # select [ star ]
        # from "users"
        # where_ (and [ isNull (col "email"), isNotNull (col "name") ])
    }

  -- Set membership -----------------------------------------------------------

  , { name: "in-list"
    , query: emptyQuery
        # select [ star ]
        # from "users"
        # where_ (in_ (col "department") [ str "engineering", str "sales" ])
    }

  , { name: "not-in-list"
    , query: emptyQuery
        # select [ star ]
        # from "users"
        # where_ (notIn (col "id") [ int 1, int 2, int 3 ])
    }

  -- Pattern matching ---------------------------------------------------------

  , { name: "like"
    , query: emptyQuery # select [ star ] # from "users" # where_ (like (col "name") "A%")
    }

  , { name: "ilike"
    , query: emptyQuery # select [ star ] # from "users" # where_ (ilike (col "email") "%@example.com")
    }

  -- Ranges -------------------------------------------------------------------

  , { name: "between"
    , query: emptyQuery
        # select [ star ]
        # from "users"
        # where_ (between (col "age") (int 18) (int 65))
    }

  -- Raw escape hatch ---------------------------------------------------------

  , { name: "where-raw"
    , query: emptyQuery # select [ star ] # from "users" # where_ (raw "age % 2 = 0")
    }

  -- Joins --------------------------------------------------------------------

  , { name: "inner-join"
    , query: emptyQuery
        # select [ star ]
        # from "orders"
        # innerJoin "users" (tcol "orders" "user_id" .== tcol "users" "id")
    }

  , { name: "left-join-with-aliases"
    , query: emptyQuery
        # select [ expr (tcol "u" "id"), expr (tcol "p" "bio") ]
        # fromAs "users" "u"
        # leftJoinAs "profiles" "p" (tcol "u" "id" .== tcol "p" "user_id")
        # where_ (tcol "u" "active" .== bool true)
        # orderBy [ desc (tcol "u" "created_at") ]
        # limit 20
    }

  , { name: "right-join"
    , query: emptyQuery
        # select [ star ]
        # from "users"
        # rightJoin "profiles" (tcol "users" "id" .== tcol "profiles" "user_id")
    }

  , { name: "full-join"
    , query: emptyQuery
        # select [ star ]
        # fromAs "users" "u"
        # fullJoinAs "profiles" "p" (tcol "u" "id" .== tcol "p" "user_id")
    }

  -- Grouping -----------------------------------------------------------------

  , { name: "group-by-having"
    , query: emptyQuery
        # select [ expr (col "department"), as (raw "COUNT(*)") "headcount" ]
        # from "users"
        # groupBy [ col "department" ]
        # having (raw "COUNT(*)" .> int 5)
        # orderBy [ desc (col "headcount") ]
    }

  -- Ordering / pagination ----------------------------------------------------

  , { name: "order-by-asc"
    , query: emptyQuery # select [ star ] # from "users" # orderBy [ asc (col "name") ]
    }

  , { name: "order-by-multiple"
    , query: emptyQuery
        # select [ star ]
        # from "users"
        # orderBy [ asc (col "department"), desc (col "created_at") ]
    }

  , { name: "limit-offset"
    , query: emptyQuery
        # select [ star ]
        # from "articles"
        # orderBy [ desc (col "published_at") ]
        # limit 10
        # offset 20
    }

  -- Everything at once -------------------------------------------------------

  , { name: "kitchen-sink"
    , query: emptyQuery
        # select [ tcolAs "u" "id" "user_id", as (raw "COUNT(o.id)") "order_count" ]
        # fromAs "users" "u"
        # leftJoinAs "orders" "o" (tcol "u" "id" .== tcol "o" "user_id")
        # where_
            ( and
                [ tcol "u" "active" .== bool true
                , isNotNull (tcol "u" "email")
                , in_ (tcol "u" "department") [ str "engineering", str "sales" ]
                ]
            )
        # groupBy [ tcol "u" "id" ]
        # having (raw "COUNT(o.id)" .> int 0)
        # orderBy [ desc (raw "COUNT(o.id)"), asc (tcol "u" "id") ]
        # limit 25
        # offset 50
    }

  -- Function application (App) -----------------------------------------------

  , { name: "app-count-star"
    , query: emptyQuery # select [ as countStar "n" ] # from "users"
    }

  , { name: "app-aggregates"
    , query: emptyQuery
        # select
            [ expr (col "department")
            , as (count (col "id")) "headcount"
            , as (App "MAX" [ col "age" ]) "oldest"
            ]
        # from "users"
        # groupBy [ col "department" ]
    }

  , { name: "app-nested"
    , query: emptyQuery
        # select [ as (upper (coalesce [ col "email", str "none" ])) "email" ]
        # from "users"
    }

  -- Operators (BinOp) --------------------------------------------------------

  , { name: "binop-concat"
    , query: emptyQuery
        # select [ as (binOp "||" (col "name") (col "department")) "label" ]
        # from "users"
    }

  -- The parentheses in the emitted SQL are the assertion here: without the
  -- precedence printer this renders as "age" + $1 * $2, which means something
  -- entirely different and which PostgreSQL would happily accept.
  , { name: "binop-arithmetic-precedence"
    , query: emptyQuery
        # select [ star ]
        # from "users"
        # where_ (binOp "*" (binOp "+" (col "age") (int 1)) (int 2) .> int 10)
    }

  , { name: "binop-not-like"
    , query: emptyQuery
        # select [ star ]
        # from "users"
        # where_ (and [ notLike (col "email") "%@spam.test", notILike (col "name") "test%" ])
    }

  -- Casts --------------------------------------------------------------------

  , { name: "cast-simple"
    , query: emptyQuery
        # select [ as (cast (col "id") "text") "id_text" ]
        # from "users"
    }

  , { name: "cast-compound-operand"
    , query: emptyQuery
        # select [ star ]
        # from "users"
        # where_ (cast (binOp "+" (col "age") (int 1)) "numeric" .>= num 1.5)
    }

  -- Subqueries (Sub) ---------------------------------------------------------

  , { name: "sub-scalar-correlated"
    , query: emptyQuery
        # select
            [ expr (tcol "u" "id")
            , as
                ( sub
                    ( emptyQuery
                        # select [ expr countStar ]
                        # from "orders"
                        # where_ (tcol "orders" "user_id" .== tcol "u" "id")
                    )
                )
                "order_count"
            ]
        # fromAs "users" "u"
    }

  , { name: "sub-in"
    , query: emptyQuery
        # select [ star ]
        # from "users"
        # where_
            ( inSub (col "id")
                (emptyQuery # select [ expr (col "user_id") ] # from "orders")
            )
    }

  , { name: "sub-not-in"
    , query: emptyQuery
        # select [ star ]
        # from "users"
        # where_
            ( notInSub (col "id")
                ( emptyQuery
                    # select [ expr (col "user_id") ]
                    # from "orders"
                    # where_ (col "status" .== str "cancelled")
                )
            )
    }

  , { name: "sub-exists"
    , query: emptyQuery
        # select [ star ]
        # fromAs "users" "u"
        # where_
            ( exists
                ( emptyQuery
                    # select [ expr (raw "1") ]
                    # from "orders"
                    # where_ (tcol "orders" "user_id" .== tcol "u" "id")
                )
            )
    }

  , { name: "sub-not-exists"
    , query: emptyQuery
        # select [ star ]
        # fromAs "users" "u"
        # where_
            ( notExists
                ( emptyQuery
                    # select [ expr (raw "1") ]
                    # from "orders"
                    # where_ (tcol "orders" "user_id" .== tcol "u" "id")
                )
            )
    }

  -- Derived tables -----------------------------------------------------------

  , { name: "derived-table"
    , query: emptyQuery
        # select [ starFrom "recent" ]
        # fromSub
            ( emptyQuery
                # select (cols [ "id", "user_id", "total" ])
                # from "orders"
                # where_ (col "status" .== str "paid")
            )
            "recent"
    }

  , { name: "derived-table-aggregate"
    , query: emptyQuery
        # select [ expr (tcol "u" "name"), expr (tcol "totals" "order_count") ]
        # fromAs "users" "u"
        # joinOn InnerJoin
            ( derived
                ( emptyQuery
                    # select [ expr (col "user_id"), as countStar "order_count" ]
                    # from "orders"
                    # groupBy [ col "user_id" ]
                )
                "totals"
            )
            (tcol "u" "id" .== tcol "totals" "user_id")
    }

  -- A derived table's parameters sit earlier in the SQL than the outer
  -- WHERE's, so they must be numbered first.
  , { name: "derived-table-parameter-ordering"
    , query: emptyQuery
        # select [ starFrom "recent" ]
        # fromSub
            ( emptyQuery
                # select (cols [ "id", "user_id", "total" ])
                # from "orders"
                # where_ (col "status" .== str "paid")
            )
            "recent"
        # where_ (tcol "recent" "total" .> int 100)
    }

  -- Subquery parameters must keep numbering in step with the outer query.
  , { name: "sub-parameter-ordering"
    , query: emptyQuery
        # select [ star ]
        # fromAs "users" "u"
        # where_
            ( and
                [ tcol "u" "active" .== bool true
                , exists
                    ( emptyQuery
                        # select [ expr (raw "1") ]
                        # from "orders"
                        # where_
                            ( and
                                [ tcol "orders" "user_id" .== tcol "u" "id"
                                , tcol "orders" "status" .== str "paid"
                                ]
                            )
                    )
                , tcol "u" "age" .> int 21
                ]
            )
    }
  ]

-- ---------------------------------------------------------------------------
-- Coverage tagging
-- ---------------------------------------------------------------------------
--
-- `exprTags`, `selectTags`, `literalTag`, `joinTypeTag` and `orderDirTag` are
-- exhaustive pattern matches. Adding a constructor to `Sqld.Core` makes them
-- incomplete, which the compiler reports; adding the case then forces a new
-- tag, and `missingTags` fails the suite until the corpus exercises it.

exprTags :: Expr -> Array String
exprTags e = case e of
  Col { table } -> [ if isJust table then "Expr.Col.qualified" else "Expr.Col" ]
  Lit l -> [ "Expr.Lit", "Literal." <> literalTag l ]
  App name args -> nodes [ "Expr.App", "Expr.App." <> name ] args
  -- Tagged per operator as well as per node, so the ratchet still guarantees
  -- each individual operator reaches PostgreSQL now that they share a
  -- constructor.
  BinOp op l r -> nodes [ "Expr.BinOp", "Expr.BinOp." <> op ] [ l, r ]
  Unary op x -> nodes [ "Expr.Unary", "Expr.Unary." <> op ] [ x ]
  Postfix op x -> nodes [ "Expr.Postfix", "Expr.Postfix." <> op ] [ x ]
  Cast x _ -> node "Expr.Cast" [ x ]
  Row xs -> node "Expr.Row" xs
  Sub q -> "Expr.Sub" : queryTags q
  And xs -> node (if Array.null xs then "Expr.And.empty" else "Expr.And") xs
  Or xs -> node (if Array.null xs then "Expr.Or.empty" else "Expr.Or") xs
  Between x lo hi -> node "Expr.Between" [ x, lo, hi ]
  Raw _ -> [ "Expr.Raw" ]
  where
  node tag kids = tag : Array.concatMap exprTags kids
  nodes tags kids = tags <> Array.concatMap exprTags kids

literalTag :: Literal -> String
literalTag = case _ of
  LitInt _ -> "LitInt"
  LitNumber _ -> "LitNumber"
  LitString _ -> "LitString"
  LitBoolean _ -> "LitBoolean"
  LitNull -> "LitNull"

selectTags :: SelectExpr -> Array String
selectTags = case _ of
  SelectStar -> [ "SelectExpr.SelectStar" ]
  SelectStarFrom _ -> [ "SelectExpr.SelectStarFrom" ]
  SelectExpr e -> "SelectExpr.SelectExpr" : exprTags e
  SelectAs e _ -> "SelectExpr.SelectAs" : exprTags e

joinTypeTag :: JoinType -> String
joinTypeTag = case _ of
  InnerJoin -> "JoinType.InnerJoin"
  LeftJoin -> "JoinType.LeftJoin"
  RightJoin -> "JoinType.RightJoin"
  FullJoin -> "JoinType.FullJoin"

orderDirTag :: OrderDir -> String
orderDirTag = case _ of
  Asc -> "OrderDir.Asc"
  Desc -> "OrderDir.Desc"

orderTags :: OrderExpr -> Array String
orderTags o = orderDirTag o.dir : exprTags o.expr

relationTags :: String -> Relation -> Array String
relationTags prefix (Table _ alias) = case alias of
  Nothing -> [ prefix ]
  Just _ -> [ prefix, prefix <> ".alias" ]
relationTags prefix (Derived q _) = (prefix <> ".derived") : queryTags q

queryTags :: Query -> Array String
queryTags q =
  Array.concatMap selectTags q.select
    <> foldClause "Query.from" (map (relationTags "Query.from") q.from)
    <> Array.concatMap (\j -> joinTypeTag j.type_ : relationTags "Query.join" j.relation <> exprTags j.on) q.joins
    <> foldClause "Query.where" (map exprTags q.where_)
    <> clause "Query.groupBy" (Array.concatMap exprTags q.groupBy) (Array.null q.groupBy)
    <> foldClause "Query.having" (map exprTags q.having)
    <> clause "Query.orderBy" (Array.concatMap orderTags q.orderBy) (Array.null q.orderBy)
    <> foldClause "Query.limit" (map (const []) q.limit)
    <> foldClause "Query.offset" (map (const []) q.offset)
  where
  foldClause tag = case _ of
    Nothing -> []
    Just inner -> tag : inner

  clause tag inner isEmpty = if isEmpty then [] else tag : inner

-- | Every feature tag the corpus actually exercises.
coveredTags :: Array String
coveredTags = Array.sort (Array.nub (Array.concatMap (\e -> queryTags e.query) corpus))

-- | Every feature tag the corpus is required to exercise. Keep in sync with
-- | `Sqld.Core` — a new constructor belongs here and in a corpus entry.
requiredTags :: Array String
requiredTags = Array.sort
  [ "Expr.Col"
  , "Expr.Col.qualified"
  , "Expr.Lit"
  , "Expr.App"
  , "Expr.BinOp"
  , "Expr.BinOp.="
  , "Expr.BinOp.<>"
  , "Expr.BinOp.<"
  , "Expr.BinOp.<="
  , "Expr.BinOp.>"
  , "Expr.BinOp.>="
  , "Expr.BinOp.IN"
  , "Expr.BinOp.NOT IN"
  , "Expr.BinOp.LIKE"
  , "Expr.BinOp.ILIKE"
  , "Expr.BinOp.NOT LIKE"
  -- Arithmetic is required because it is the only thing that exercises the
  -- precedence printer; without it a parenthesisation bug ships unnoticed.
  , "Expr.BinOp.+"
  , "Expr.BinOp.*"
  , "Expr.BinOp.||"
  , "Expr.Unary"
  , "Expr.Unary.NOT"
  , "Expr.Unary.EXISTS"
  , "Expr.Unary.NOT EXISTS"
  , "Expr.Postfix"
  , "Expr.Postfix.IS NULL"
  , "Expr.Postfix.IS NOT NULL"
  , "Expr.Cast"
  , "Expr.Row"
  , "Expr.Sub"
  , "Expr.And"
  , "Expr.And.empty"
  , "Expr.Or"
  , "Expr.Or.empty"
  , "Expr.Between"
  , "Expr.Raw"
  , "Literal.LitInt"
  , "Literal.LitNumber"
  , "Literal.LitString"
  , "Literal.LitBoolean"
  , "Literal.LitNull"
  , "SelectExpr.SelectExpr"
  , "SelectExpr.SelectAs"
  , "SelectExpr.SelectStar"
  , "SelectExpr.SelectStarFrom"
  , "JoinType.InnerJoin"
  , "JoinType.LeftJoin"
  , "JoinType.RightJoin"
  , "JoinType.FullJoin"
  , "OrderDir.Asc"
  , "OrderDir.Desc"
  , "Query.from"
  , "Query.from.alias"
  , "Query.join"
  , "Query.join.alias"
  , "Query.join.derived"
  , "Query.from.derived"
  , "Query.where"
  , "Query.groupBy"
  , "Query.having"
  , "Query.orderBy"
  , "Query.limit"
  , "Query.offset"
  ]

-- | Required tags with no corpus entry. Must be empty.
missingTags :: Array String
missingTags = Array.difference requiredTags coveredTags
