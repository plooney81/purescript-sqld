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

import Prelude hiding (between, not, sub)

import Data.Array ((:))
import Data.Array (concatMap, difference, nub, null, sort) as Array
import Data.Maybe (Maybe(..), isJust)
import Example.Cookbook (cookbook) as Cookbook
import Sqld.Core (Cte(..), Expr(..), Frame, FrameBound(..), FrameMode(..), JoinType(..), Literal(..), OrderDir(..), OrderExpr, Query, Relation(..), SelectExpr(..), SetOp(..), SetOperation(..), Window, emptyWindow)
import Sqld.Expr (and, avg, between, binOp, bool, cast, coalesce, col, count, countStar, currentRow, denseRank, exists, following, frameFrom, groups, ilike, in_, inSub, int, isNotNull, isNull, lag, lead, like, not, notExists, notILike, notIn, notInSub, notLike, null, num, or, orderWindow, over, over', partitionBy, preceding, range, rank, raw, rowNumber, rows, str, sub, sum_, tcol, unboundedFollowing, unboundedPreceding, upper, withFrame, (.!=), (.<), (.<=), (.==), (.>), (.>=))
import Sqld.Select (as, asc, colAs, cols, cte, cteColumns, cteRecursive, derived, desc, except, exceptAll, expr, exprs, from, fromAs, fromSub, fullJoinAs, groupBy, having, innerJoin, intersect, intersectAll, joinOn, leftJoinAs, limit, offset, orderBy, rightJoin, select', star, starFrom, tcolAs, tcols, union, unionAll, where_, with_, withCte, withRecursive)

type CorpusEntry = { name :: String, query :: Query }

-- | A window shared by more than one corpus entry, so `over` with a named
-- | `Window` is exercised alongside the `over'` shorthand.
byUser :: Window
byUser = emptyWindow # partitionBy [ col "user_id" ] # orderWindow [ asc (col "placed_at") ]

-- ---------------------------------------------------------------------------
-- The corpus
-- ---------------------------------------------------------------------------

-- | The hand-written corpus, plus every cookbook example — so a published
-- | example cannot be SQL that PostgreSQL rejects.
corpus :: Array CorpusEntry
corpus = handWritten <> map asEntry Cookbook.cookbook
  where
  asEntry e = { name: "example-" <> e.name, query: e.query }

handWritten :: Array CorpusEntry
handWritten =
  [ { name: "select-star"
    , query: select' [ star ] # from "users"
    }

  , { name: "select-columns"
    , query: select' (cols [ "id", "name", "email" ]) # from "users"
    }

  , { name: "select-alias"
    , query: select' [ as (col "created_at") "ts" ] # from "users"
    }

  , { name: "select-col-alias-shorthand"
    , query: select' [ colAs "created_at" "ts" ] # from "users"
    }

  , { name: "select-qualified-columns"
    , query: select' [ expr (tcol "u" "id"), expr (tcol "u" "name") ]
        # fromAs "users" "u"
    }

  , { name: "select-qualified-alias"
    , query: select' [ tcolAs "u" "created_at" "ts" ]
        # fromAs "users" "u"
    }

  , { name: "select-star-from-alias"
    , query: select' [ starFrom "u" ] # fromAs "users" "u"
    }

  , { name: "select-raw-expression"
    , query: select' [ expr (raw "1 + 1") ]
    }

  , { name: "select-aggregate-alias"
    , query: select' [ expr (col "department"), as (raw "COUNT(*)") "n" ]
        # from "users"
        # groupBy [ col "department" ]
    }

  -- Literals -----------------------------------------------------------------

  , { name: "literal-int"
    , query: select' [ star ] # from "users" # where_ (col "id" .== int 42)
    }

  , { name: "literal-string-with-quote"
    , query: select' [ star ] # from "users" # where_ (col "name" .!= str "O'Brien")
    }

  , { name: "literal-number"
    , query: select' [ star ] # from "users" # where_ (col "score" .>= num 4.5)
    }

  , { name: "literal-boolean"
    , query: select' [ star ] # from "users" # where_ (col "active" .== bool true)
    }

  , { name: "literal-null"
    , query: select' [ star ] # from "users" # where_ (col "email" .== null)
    }

  -- Comparison operators -----------------------------------------------------

  , { name: "comparison-operators"
    , query: select' [ star ]
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
    , query: select' [ star ]
        # from "users"
        # where_ (or [ col "active" .== bool true, isNull (col "email") ])
    }

  , { name: "boolean-not"
    , query: select' [ star ]
        # from "users"
        # where_ (not (col "active" .== bool true))
    }

  , { name: "boolean-and-empty"
    , query: select' [ star ] # from "users" # where_ (and [])
    }

  , { name: "boolean-or-empty"
    , query: select' [ star ] # from "users" # where_ (or [])
    }

  -- Null tests ---------------------------------------------------------------

  , { name: "is-null-and-is-not-null"
    , query: select' [ star ]
        # from "users"
        # where_ (and [ isNull (col "email"), isNotNull (col "name") ])
    }

  -- Set membership -----------------------------------------------------------

  , { name: "in-list"
    , query: select' [ star ]
        # from "users"
        # where_ (in_ (col "department") [ str "engineering", str "sales" ])
    }

  , { name: "not-in-list"
    , query: select' [ star ]
        # from "users"
        # where_ (notIn (col "id") [ int 1, int 2, int 3 ])
    }

  -- An empty candidate list folds to a constant rather than emitting `IN ()`,
  -- which PostgreSQL rejects. These entries are here to prove that: without the
  -- fold, PREPARE fails on them.
  , { name: "in-list-empty"
    , query: select' [ star ]
        # from "users"
        # where_ (in_ (col "department") [])
    }

  , { name: "not-in-list-empty"
    , query: select' [ star ]
        # from "users"
        # where_ (notIn (col "id") [])
    }

  -- The folded constant under AND / OR / NOT — the positions where bracketing
  -- would change the meaning if it were not an atom.
  , { name: "in-list-empty-nested"
    , query: select' [ star ]
        # from "users"
        # where_
            ( and
                [ col "active" .== bool true
                , or [ in_ (col "department") [], notIn (col "id") [] ]
                , not (in_ (col "email") [])
                ]
            )
    }

  -- Pattern matching ---------------------------------------------------------

  , { name: "like"
    , query: select' [ star ] # from "users" # where_ (like (col "name") "A%")
    }

  , { name: "ilike"
    , query: select' [ star ] # from "users" # where_ (ilike (col "email") "%@example.com")
    }

  -- Ranges -------------------------------------------------------------------

  , { name: "between"
    , query: select' [ star ]
        # from "users"
        # where_ (between (col "age") (int 18) (int 65))
    }

  -- Raw escape hatch ---------------------------------------------------------

  , { name: "where-raw"
    , query: select' [ star ] # from "users" # where_ (raw "age % 2 = 0")
    }

  -- Joins --------------------------------------------------------------------

  , { name: "inner-join"
    , query: select' [ star ]
        # from "orders"
        # innerJoin "users" (tcol "orders" "user_id" .== tcol "users" "id")
    }

  , { name: "left-join-with-aliases"
    , query: select' [ expr (tcol "u" "id"), expr (tcol "p" "bio") ]
        # fromAs "users" "u"
        # leftJoinAs "profiles" "p" (tcol "u" "id" .== tcol "p" "user_id")
        # where_ (tcol "u" "active" .== bool true)
        # orderBy [ desc (tcol "u" "created_at") ]
        # limit 20
    }

  , { name: "right-join"
    , query: select' [ star ]
        # from "users"
        # rightJoin "profiles" (tcol "users" "id" .== tcol "profiles" "user_id")
    }

  , { name: "full-join"
    , query: select' [ star ]
        # fromAs "users" "u"
        # fullJoinAs "profiles" "p" (tcol "u" "id" .== tcol "p" "user_id")
    }

  -- Grouping -----------------------------------------------------------------

  , { name: "group-by-having"
    , query: select' [ expr (col "department"), as (raw "COUNT(*)") "headcount" ]
        # from "users"
        # groupBy [ col "department" ]
        # having (raw "COUNT(*)" .> int 5)
        # orderBy [ desc (col "headcount") ]
    }

  -- Ordering / pagination ----------------------------------------------------

  , { name: "order-by-asc"
    , query: select' [ star ] # from "users" # orderBy [ asc (col "name") ]
    }

  , { name: "order-by-multiple"
    , query: select' [ star ]
        # from "users"
        # orderBy [ asc (col "department"), desc (col "created_at") ]
    }

  , { name: "limit-offset"
    , query: select' [ star ]
        # from "articles"
        # orderBy [ desc (col "published_at") ]
        # limit 10
        # offset 20
    }

  -- Everything at once -------------------------------------------------------

  , { name: "kitchen-sink"
    , query: select' [ tcolAs "u" "id" "user_id", as (raw "COUNT(o.id)") "order_count" ]
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
    , query: select' [ as countStar "n" ] # from "users"
    }

  , { name: "app-aggregates"
    , query: select'
        [ expr (col "department")
        , as (count (col "id")) "headcount"
        , as (App "MAX" [ col "age" ]) "oldest"
        ]
        # from "users"
        # groupBy [ col "department" ]
    }

  , { name: "app-nested"
    , query: select' [ as (upper (coalesce [ col "email", str "none" ])) "email" ]
        # from "users"
    }

  -- Operators (BinOp) --------------------------------------------------------

  , { name: "binop-concat"
    , query: select' [ as (binOp "||" (col "name") (col "department")) "label" ]
        # from "users"
    }

  -- The parentheses in the emitted SQL are the assertion here: without the
  -- precedence printer this renders as "age" + $1 * $2, which means something
  -- entirely different and which PostgreSQL would happily accept.
  , { name: "binop-arithmetic-precedence"
    , query: select' [ star ]
        # from "users"
        # where_ (binOp "*" (binOp "+" (col "age") (int 1)) (int 2) .> int 10)
    }

  , { name: "binop-not-like"
    , query: select' [ star ]
        # from "users"
        # where_ (and [ notLike (col "email") "%@spam.test", notILike (col "name") "test%" ])
    }

  -- Casts --------------------------------------------------------------------

  , { name: "cast-simple"
    , query: select' [ as (cast (col "id") "text") "id_text" ]
        # from "users"
    }

  , { name: "cast-compound-operand"
    , query: select' [ star ]
        # from "users"
        # where_ (cast (binOp "+" (col "age") (int 1)) "numeric" .>= num 1.5)
    }

  -- Subqueries (Sub) ---------------------------------------------------------

  , { name: "sub-scalar-correlated"
    , query: select'
        [ expr (tcol "u" "id")
        , as
            ( sub
                ( select' [ expr countStar ]
                    # from "orders"
                    # where_ (tcol "orders" "user_id" .== tcol "u" "id")
                )
            )
            "order_count"
        ]
        # fromAs "users" "u"
    }

  , { name: "sub-in"
    , query: select' [ star ]
        # from "users"
        # where_
            ( inSub (col "id")
                (select' [ expr (col "user_id") ] # from "orders")
            )
    }

  , { name: "sub-not-in"
    , query: select' [ star ]
        # from "users"
        # where_
            ( notInSub (col "id")
                ( select' [ expr (col "user_id") ]
                    # from "orders"
                    # where_ (col "status" .== str "cancelled")
                )
            )
    }

  , { name: "sub-exists"
    , query: select' [ star ]
        # fromAs "users" "u"
        # where_
            ( exists
                ( select' [ expr (raw "1") ]
                    # from "orders"
                    # where_ (tcol "orders" "user_id" .== tcol "u" "id")
                )
            )
    }

  , { name: "sub-not-exists"
    , query: select' [ star ]
        # fromAs "users" "u"
        # where_
            ( notExists
                ( select' [ expr (raw "1") ]
                    # from "orders"
                    # where_ (tcol "orders" "user_id" .== tcol "u" "id")
                )
            )
    }

  -- Select-list composition ---------------------------------------------------

  , { name: "mixed-select-list"
    , query: select' (cols [ "department" ] <> exprs [ avg (col "age") ] <> [ as countStar "headcount" ])
        # from "users"
        # groupBy [ col "department" ]
    }

  -- Dot-qualified column references ------------------------------------------

  , { name: "dotted-column-references"
    , query: select' (cols [ "orders.id", "users.name" ])
        # from "orders"
        # innerJoin "users" (col "orders.user_id" .== col "users.id")
        # where_ (col "orders.status" .== str "paid")
    }

  , { name: "dotted-column-references-aliased"
    , query: select' (tcols "u" [ "id", "name" ] <> cols [ "p.bio" ])
        # fromAs "users" "u"
        # leftJoinAs "profiles" "p" (col "u.id" .== col "p.user_id")
    }

  -- Derived tables -----------------------------------------------------------

  , { name: "derived-table"
    , query: select' [ starFrom "recent" ]
        # fromSub
            ( select' (cols [ "id", "user_id", "total" ])
                # from "orders"
                # where_ (col "status" .== str "paid")
            )
            "recent"
    }

  , { name: "derived-table-aggregate"
    , query: select' [ expr (tcol "u" "name"), expr (tcol "totals" "order_count") ]
        # fromAs "users" "u"
        # joinOn InnerJoin
            ( derived
                ( select' [ expr (col "user_id"), as countStar "order_count" ]
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
    , query: select' [ starFrom "recent" ]
        # fromSub
            ( select' (cols [ "id", "user_id", "total" ])
                # from "orders"
                # where_ (col "status" .== str "paid")
            )
            "recent"
        # where_ (tcol "recent" "total" .> int 100)
    }

  -- Common table expressions --------------------------------------------------

  , { name: "with-cte"
    , query: select' [ starFrom "recent" ]
        # with_ "recent"
            ( select' [ star ]
                # from "orders"
                # where_ (col "status" .== str "paid")
            )
        # from "recent"
    }

  -- A later CTE may reference an earlier one, and the outer query treats both
  -- as ordinary relations.
  , { name: "with-cte-multiple"
    , query: select' [ expr (tcol "u" "name"), expr (tcol "spend" "total") ]
        # with_ "paid"
            ( select' (cols [ "user_id", "total" ])
                # from "orders"
                # where_ (col "status" .== str "paid")
            )
        # with_ "spend"
            ( select' (cols [ "user_id" ] <> [ as (sum_ (col "total")) "total" ])
                # from "paid"
                # groupBy [ col "user_id" ]
            )
        # fromAs "users" "u"
        # innerJoin "spend" (tcol "u" "id" .== tcol "spend" "user_id")
    }

  , { name: "with-cte-column-list"
    , query: select' [ star ]
        # withCte
            ( cteColumns [ "user_id", "spend" ]
                ( cte "totals"
                    ( select' (exprs [ col "user_id", sum_ (col "total") ])
                        # from "orders"
                        # groupBy [ col "user_id" ]
                    )
                )
            )
        # from "totals"
    }

  -- A CTE's parameters sit ahead of every other clause in the emitted SQL, so
  -- they are numbered first.
  , { name: "with-cte-parameter-ordering"
    , query: select' [ starFrom "recent" ]
        # with_ "recent"
            ( select' (cols [ "id", "user_id", "total" ])
                # from "orders"
                # where_ (col "status" .== str "paid")
            )
        # from "recent"
        # where_ (tcol "recent" "total" .> int 100)
    }

  -- A recursive CTE is conventionally `anchor UNION ALL recursive-term`. The
  -- anchor's literal is `raw` rather than `int`: a bare parameter in a select
  -- list gives PostgreSQL nothing to infer a type from, and PREPARE rejects it.
  , { name: "with-recursive"
    , query: select' [ star ]
        # withRecursive "counting"
            ( select' [ as (raw "1") "n" ]
                # unionAll
                    ( select' [ expr (binOp "+" (col "n") (int 1)) ]
                        # from "counting"
                        # where_ (col "n" .< int 5)
                    )
            )
        # from "counting"
    }

  -- RECURSIVE is a property of the clause, not the entry: one recursive CTE
  -- makes the whole WITH recursive, and the non-recursive one still works.
  , { name: "with-recursive-mixed"
    , query: select' [ star ]
        # with_ "paid"
            ( select' (cols [ "user_id" ])
                # from "orders"
                # where_ (col "status" .== str "paid")
            )
        # withCte
            ( cteRecursive
                ( cteColumns [ "n" ]
                    ( cte "counting"
                        ( select' [ expr (raw "1") ]
                            # unionAll
                                ( select' [ expr (binOp "+" (col "n") (int 1)) ]
                                    # from "counting"
                                    # where_ (col "n" .< int 5)
                                )
                        )
                    )
                )
            )
        # from "counting"
        # innerJoin "paid" (tcol "paid" "user_id" .== tcol "counting" "n")
    }

  -- Set operations -------------------------------------------------------------

  , { name: "set-op-union"
    , query: select' (cols [ "id" ])
        # from "users"
        # union (select' (cols [ "user_id" ]) # from "orders")
    }

  , { name: "set-op-union-all"
    , query: select' (cols [ "id" ])
        # from "users"
        # unionAll (select' (cols [ "user_id" ]) # from "orders")
    }

  , { name: "set-op-intersect"
    , query: select' (cols [ "id" ])
        # from "users"
        # intersect (select' (cols [ "user_id" ]) # from "orders")
    }

  , { name: "set-op-intersect-all"
    , query: select' (cols [ "id" ])
        # from "users"
        # intersectAll (select' (cols [ "user_id" ]) # from "profiles")
    }

  , { name: "set-op-except"
    , query: select' (cols [ "id" ])
        # from "users"
        # except (select' (cols [ "user_id" ]) # from "orders")
    }

  , { name: "set-op-except-all"
    , query: select' (cols [ "id" ])
        # from "users"
        # exceptAll (select' (cols [ "user_id" ]) # from "profiles")
    }

  -- Both operands are bracketed, so a chain of mixed operators does not depend
  -- on PostgreSQL's precedence between UNION and INTERSECT.
  , { name: "set-op-chained"
    , query: select' (cols [ "id" ])
        # from "users"
        # union (select' (cols [ "user_id" ]) # from "orders")
        # except (select' (cols [ "user_id" ]) # from "profiles")
    }

  -- ORDER BY, LIMIT and OFFSET after a set operation apply to the combined
  -- result: they are emitted outside the brackets.
  , { name: "set-op-order-by-limit"
    , query: select' (cols [ "id" ])
        # from "users"
        # union (select' (cols [ "user_id" ]) # from "orders")
        # orderBy [ asc (col "id") ]
        # limit 10
        # offset 5
    }

  -- And an operand keeps an ORDER BY and LIMIT of its own, because it is
  -- bracketed.
  , { name: "set-op-operand-order-by-limit"
    , query: select' (cols [ "id" ])
        # from "users"
        # orderBy [ asc (col "id") ]
        # limit 5
        # unionAll
            ( select' (cols [ "user_id" ])
                # from "orders"
                # orderBy [ desc (col "user_id") ]
                # limit 3
            )
    }

  -- Parameters are numbered left to right across both operands.
  , { name: "set-op-parameter-ordering"
    , query: select' (cols [ "id" ])
        # from "users"
        # where_ (col "active" .== bool true)
        # union
            ( select' (cols [ "user_id" ])
                # from "orders"
                # where_ (col "status" .== str "paid")
            )
        # orderBy [ asc (col "id") ]
    }

  -- A WITH clause on a set operation covers the whole statement, and its
  -- parameters precede both operands'.
  , { name: "set-op-with-cte"
    , query: select' (cols [ "user_id" ])
        # from "paid"
        # union
            ( select' (cols [ "user_id" ])
                # from "orders"
                # where_ (col "status" .== str "cancelled")
            )
        # with_ "paid"
            ( select' (cols [ "user_id" ])
                # from "orders"
                # where_ (col "status" .== str "paid")
            )
    }

  -- A set operation is a query like any other, so it nests wherever one can.
  , { name: "set-op-derived-table"
    , query: select' [ as countStar "n" ]
        # fromSub
            ( select' (cols [ "id" ])
                # from "users"
                # union (select' (cols [ "user_id" ]) # from "orders")
            )
            "ids"
    }

  -- Subquery parameters must keep numbering in step with the outer query.
  , { name: "sub-parameter-ordering"
    , query: select' [ star ]
        # fromAs "users" "u"
        # where_
            ( and
                [ tcol "u" "active" .== bool true
                , exists
                    ( select' [ expr (raw "1") ]
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

  -- Window functions -----------------------------------------------------------

  , { name: "window-row-number"
    , query: select'
        ( cols [ "name", "department" ] <>
            [ as
                ( rowNumber `over'`
                    ( partitionBy [ col "department" ]
                        >>> orderWindow [ desc (col "age") ]
                    )
                )
                "rn"
            ]
        )
        # from "users"
    }

  -- An empty window is `OVER ()`: one partition, unordered, unframed.
  , { name: "window-empty"
    , query: select' (cols [ "id" ] <> [ as (countStar `over` emptyWindow) "total" ])
        # from "users"
    }

  , { name: "window-rank-dense-rank"
    , query: select'
        ( cols [ "name" ] <>
            [ as (rank `over'` orderWindow [ desc (col "score") ]) "rank"
            , as (denseRank `over'` orderWindow [ desc (col "score") ]) "dense_rank"
            ]
        )
        # from "users"
    }

  -- A named window, shared by two columns: `over` takes the `Window` itself.
  , { name: "window-lag-lead"
    , query: select'
        ( cols [ "placed_at", "total" ] <>
            [ as (lag (col "total") 1 `over` byUser) "previous_total"
            , as (lead (col "total") 1 `over` byUser) "next_total"
            ]
        )
        # from "orders"
    }

  -- A running total: the frame runs from the start of the partition to the
  -- current row.
  , { name: "window-frame-rows"
    , query: select'
        ( cols [ "user_id", "total" ] <>
            [ as
                ( sum_ (col "total")
                    `over` (byUser # withFrame (rows unboundedPreceding currentRow))
                )
                "running_total"
            ]
        )
        # from "orders"
    }

  -- Offset bounds are emitted literally rather than as parameters.
  , { name: "window-frame-rows-offsets"
    , query: select'
        [ as
            ( avg (col "total") `over'`
                ( orderWindow [ asc (col "placed_at") ]
                    >>> withFrame (rows (preceding 3) (following 1))
                )
            )
            "moving_average"
        ]
        # from "orders"
    }

  , { name: "window-frame-range"
    , query: select'
        [ as
            ( sum_ (col "total") `over'`
                ( orderWindow [ asc (col "placed_at") ]
                    >>> withFrame (range currentRow unboundedFollowing)
                )
            )
            "remaining_total"
        ]
        # from "orders"
    }

  -- PostgreSQL requires an ordered window in GROUPS mode, and the harness is
  -- what holds us to that.
  , { name: "window-frame-groups"
    , query: select'
        [ as
            ( sum_ (col "total") `over'`
                ( orderWindow [ asc (col "placed_at") ]
                    >>> withFrame (groups unboundedPreceding currentRow)
                )
            )
            "total_to_date"
        ]
        # from "orders"
    }

  -- The one-bound form, `ROWS UNBOUNDED PRECEDING`, runs to the current row.
  , { name: "window-frame-one-bound"
    , query: select'
        [ as
            ( sum_ (col "total") `over'`
                ( orderWindow [ asc (col "placed_at") ]
                    >>> withFrame (frameFrom Rows unboundedPreceding)
                )
            )
            "running_total"
        ]
        # from "orders"
    }

  -- A window function is legal in ORDER BY as well as in SELECT.
  , { name: "window-in-order-by"
    , query: select' (cols [ "name" ])
        # from "users"
        # orderBy [ asc (rank `over'` orderWindow [ desc (col "score") ]) ]
    }

  -- A window's parameters sit in the select list, so they are numbered before
  -- the WHERE clause's.
  , { name: "window-parameter-ordering"
    , query: select'
        [ as
            ( countStar `over'`
                partitionBy [ coalesce [ col "department", str "unknown" ] ]
            )
            "headcount"
        ]
        # from "users"
        # where_ (col "active" .== bool true)
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
  Over f w -> ("Expr.Over" : exprTags f) <> windowTags w
  Raw _ -> [ "Expr.Raw" ]
  where
  node tag kids = tag : Array.concatMap exprTags kids
  nodes tags kids = tags <> Array.concatMap exprTags kids

windowTags :: Window -> Array String
windowTags w =
  clause "Window.partitionBy" (Array.concatMap exprTags w.partitionBy) (Array.null w.partitionBy)
    <> clause "Window.orderBy" (Array.concatMap orderTags w.orderBy) (Array.null w.orderBy)
    <> case w.frame of
         Nothing -> []
         Just f -> frameTags f
  where
  clause tag inner isEmpty = if isEmpty then [] else tag : inner

-- | The one-bound and `BETWEEN` forms are tagged apart, so the ratchet holds
-- | each to a corpus entry of its own.
frameTags :: Frame -> Array String
frameTags f =
  [ "Window.frame", frameModeTag f.mode, frameBoundTag f.start ]
    <> case f.end of
         Nothing -> []
         Just b -> [ "Window.frame.between", frameBoundTag b ]

frameModeTag :: FrameMode -> String
frameModeTag = case _ of
  Rows -> "FrameMode.Rows"
  Range -> "FrameMode.Range"
  Groups -> "FrameMode.Groups"

frameBoundTag :: FrameBound -> String
frameBoundTag = case _ of
  UnboundedPreceding -> "FrameBound.UnboundedPreceding"
  Preceding _ -> "FrameBound.Preceding"
  CurrentRow -> "FrameBound.CurrentRow"
  Following _ -> "FrameBound.Following"
  UnboundedFollowing -> "FrameBound.UnboundedFollowing"

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

setOpTag :: SetOp -> String
setOpTag = case _ of
  Union -> "SetOp.Union"
  Intersect -> "SetOp.Intersect"
  Except -> "SetOp.Except"

-- | `ALL` is tagged separately from the operator, so the ratchet holds each
-- | spelling to a corpus entry of its own.
setOperationTags :: SetOperation -> Array String
setOperationTags (SetOperation so) =
  (tag : (if so.all then [ tag <> ".all" ] else []))
    <> queryTags so.left
    <> queryTags so.right
  where
  tag = setOpTag so.op

cteTags :: Cte -> Array String
cteTags (Cte c) =
  [ "Query.with" ]
    <> (if c.recursive then [ "Query.with.recursive" ] else [])
    <> (if Array.null c.columns then [] else [ "Query.with.columns" ])
    <> queryTags c.query

queryTags :: Query -> Array String
queryTags q =
  Array.concatMap cteTags q.with
    <> foldClause "Query.setOp" (map setOperationTags q.setOp)
    <> Array.concatMap selectTags q.select
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
  , "Expr.Over"
  , "Expr.Raw"
  , "Window.partitionBy"
  , "Window.orderBy"
  , "Window.frame"
  , "Window.frame.between"
  , "FrameMode.Rows"
  , "FrameMode.Range"
  , "FrameMode.Groups"
  , "FrameBound.UnboundedPreceding"
  , "FrameBound.Preceding"
  , "FrameBound.CurrentRow"
  , "FrameBound.Following"
  , "FrameBound.UnboundedFollowing"
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
  , "Query.with"
  , "Query.with.columns"
  , "Query.with.recursive"
  , "Query.setOp"
  , "SetOp.Union"
  , "SetOp.Union.all"
  , "SetOp.Intersect"
  , "SetOp.Intersect.all"
  , "SetOp.Except"
  , "SetOp.Except.all"
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
