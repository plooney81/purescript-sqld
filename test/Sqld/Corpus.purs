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
import Sqld.Core (Expr(..), JoinType(..), Literal(..), OrderDir(..), OrderExpr, Query, Relation, SelectExpr(..), emptyQuery)
import Sqld.Expr (and, between, bool, col, ilike, in_, int, isNotNull, isNull, like, not, notIn, null, num, or, raw, str, tcol, (.!=), (.<), (.<=), (.==), (.>), (.>=))
import Sqld.Select (as, asc, colAs, cols, desc, expr, from, fromAs, groupBy, having, innerJoin, leftJoinAs, limit, offset, orderBy, rel, relAs, select, star, tcolAs, where_)

type CorpusEntry = { name :: String, query :: Query }

-- ---------------------------------------------------------------------------
-- Builders the public API does not (yet) expose
-- ---------------------------------------------------------------------------

-- | `Sqld.Select` has no `rightJoin` / `fullJoin`, so the corpus reaches for the
-- | `Sqld.Core` constructors directly to keep those code paths covered.
joinWith :: JoinType -> Relation -> Expr -> Query -> Query
joinWith type_ relation on q =
  q { joins = q.joins <> [ { type_, relation, on } ] }

-- | `Sqld.Select` has no `starFrom`, so build `SelectStarFrom` by hand.
starFrom :: String -> SelectExpr
starFrom = SelectStarFrom

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
        # joinWith RightJoin (rel "profiles") (tcol "users" "id" .== tcol "profiles" "user_id")
    }

  , { name: "full-join"
    , query: emptyQuery
        # select [ star ]
        # fromAs "users" "u"
        # joinWith FullJoin (relAs "profiles" "p") (tcol "u" "id" .== tcol "p" "user_id")
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
  Eq a b -> node "Expr.Eq" [ a, b ]
  Neq a b -> node "Expr.Neq" [ a, b ]
  Lt a b -> node "Expr.Lt" [ a, b ]
  Lte a b -> node "Expr.Lte" [ a, b ]
  Gt a b -> node "Expr.Gt" [ a, b ]
  Gte a b -> node "Expr.Gte" [ a, b ]
  And xs -> node (if Array.null xs then "Expr.And.empty" else "Expr.And") xs
  Or xs -> node (if Array.null xs then "Expr.Or.empty" else "Expr.Or") xs
  Not x -> node "Expr.Not" [ x ]
  IsNull x -> node "Expr.IsNull" [ x ]
  IsNotNull x -> node "Expr.IsNotNull" [ x ]
  In x xs -> node "Expr.In" (x : xs)
  NotIn x xs -> node "Expr.NotIn" (x : xs)
  Like x p -> node "Expr.Like" [ x, p ]
  ILike x p -> node "Expr.ILike" [ x, p ]
  Between x lo hi -> node "Expr.Between" [ x, lo, hi ]
  Raw _ -> [ "Expr.Raw" ]
  where
  node tag kids = tag : Array.concatMap exprTags kids

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
relationTags prefix r = case r.alias of
  Nothing -> [ prefix ]
  Just _ -> [ prefix, prefix <> ".alias" ]

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
  , "Expr.Eq"
  , "Expr.Neq"
  , "Expr.Lt"
  , "Expr.Lte"
  , "Expr.Gt"
  , "Expr.Gte"
  , "Expr.And"
  , "Expr.And.empty"
  , "Expr.Or"
  , "Expr.Or.empty"
  , "Expr.Not"
  , "Expr.IsNull"
  , "Expr.IsNotNull"
  , "Expr.In"
  , "Expr.NotIn"
  , "Expr.Like"
  , "Expr.ILike"
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
