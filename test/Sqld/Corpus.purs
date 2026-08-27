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
import Data.Array (concatMap, difference, length, nub, null, sort) as Array
import Data.Maybe (Maybe(..), isJust, maybe)
import Example.Cookbook (cookbook) as Cookbook
import Sqld.Core (Cte(..), Distinct(..), Expr(..), Frame, FrameBound(..), FrameMode(..), GroupingElement(..), Join, JoinCondition(..), JoinType(..), Literal(..), LockStrength(..), LockWait(..), Locking, NullOrder(..), OrderDir(..), OrderExpr, QuantOp(..), Query, Relation(..), SelectExpr(..), SetOp(..), SetOperation(..), Window, emptyWindow)
import Sqld.Expr (allOf, and, anyOf, app, avg, between, binOp, bool, cast, coalesce, col, count, countStar, currentRow, denseRank, eqAny, exists, filterWhere, following, frameFrom, groups, ilike, in_, inSub, int, isNotNull, isNull, lag, lead, like, not, notExists, notILike, notIn, notInSub, notLike, null, num, or, orderWindow, orderWindow', over, partitionBy', preceding, range, rank, raw, rowNumber, rows, str, sub, sum_, tcol, unboundedFollowing, unboundedPreceding, upper, withFrame, (.!=), (.<), (.<=), (.==), (.>), (.>=))
import Sqld.Select (as, asc, ascNullsFirst, ascNullsLast, colAs, cols, crossJoin, cte, cteColumns, cteRecursive, derived, desc, descNullsFirst, descNullsLast, distinct, distinctOn, except, exceptAll, expr, exprs, forKeyShare, forNoKeyUpdate, forShare, forUpdate, from, fromAs, fromLateral, fromSub, fullJoinAs, groupBy, groupByCube, groupByRollup, groupBySets, having, innerJoin, intersect, intersectAll, joinLateral, joinOn, joinRel, joinUsing, lateral, leftJoinAs, leftJoinLateral, limit, limitAll, lockOf, naturalJoin, noWait, offset, orderBy, orderUsing, rightJoin, select', skipLocked, star, starFrom, tcolAs, tcols, union, unionAll, where_, with_, withCte, withRecursive)

type CorpusEntry = { name :: String, query :: Query }

-- | A window shared by more than one corpus entry, so a named `Window` is
-- | exercised alongside the ones built inline.
byUser :: Window
byUser = partitionBy' [ col "user_id" ] # orderWindow [ asc (col "placed_at") ]

-- | A parameterised subquery, for the entries that join a derived table and
-- | care where its bindings are numbered.
paidOrders :: Query
paidOrders =
  select' (cols [ "user_id" ]) # from "orders" # where_ (col "status" .== str "paid")

-- | The per-row subquery behind the `LATERAL` entries: the three most recent
-- | orders of whichever user the join is pairing with.
-- |
-- | The reference to `"u"."id"` is what makes it lateral. Drop the marker and
-- | PostgreSQL rejects the query — an ordinary derived table cannot see the
-- | relations beside it — so these entries fail without the feature rather than
-- | merely emitting different SQL.
recentOrdersOfUser :: Query
recentOrdersOfUser =
  select' (cols [ "total" ])
    # from "orders"
    # where_ (tcol "orders" "user_id" .== tcol "u" "id")
    # orderBy [ desc (col "placed_at") ]
    # limit 3

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

  -- DISTINCT -----------------------------------------------------------------

  , { name: "distinct"
    , query: select' (cols [ "department" ]) # distinct # from "users"
    }

  -- PostgreSQL requires the leading ORDER BY expressions to match the
  -- DISTINCT ON ones, which is the rule this entry is here to hold us to:
  -- swap the two ORDER BY terms and PREPARE fails.
  , { name: "distinct-on"
    , query: select' (cols [ "user_id", "total" ])
        # distinctOn [ col "user_id" ]
        # from "orders"
        # orderBy [ asc (col "user_id"), desc (col "placed_at") ]
    }

  -- A DISTINCT ON expression sits ahead of the select list in the emitted SQL,
  -- so its parameters are numbered before the WHERE clause's. No ORDER BY
  -- here: two occurrences of the same expression would carry different
  -- parameter numbers, and PostgreSQL matches them as written.
  , { name: "distinct-on-parameter-ordering"
    , query: select' (cols [ "user_id", "total" ])
        # distinctOn [ coalesce [ col "status", str "unknown" ] ]
        # from "orders"
        # where_ (col "total" .> num 10.0)
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

  , { name: "cross-join"
    , query: select' [ starFrom "users" ]
        # from "users"
        # crossJoin "departments"
    }

  -- A derived join target carries parameters; a CROSS JOIN carries none of its
  -- own, so the WHERE clause's are numbered after the subquery's.
  , { name: "cross-join-derived"
    , query: select' [ star ]
        # fromAs "users" "u"
        # joinRel (derived paidOrders "paid") Cross
        # where_ (tcol "u" "active" .== bool true)
    }

  -- USING collapses the joined column to one, which is why "user_id" is
  -- unambiguous in the select list here and would not be under ON.
  , { name: "join-using"
    , query: select' (cols [ "user_id" ])
        # from "orders"
        # joinUsing InnerJoin "profiles" [ "user_id" ]
    }

  , { name: "join-using-multiple-columns"
    , query: select' [ star ]
        # from "orders"
        # joinUsing LeftJoin "profiles" [ "id", "user_id" ]
    }

  -- `users` and `departments` share exactly one column name, `department`,
  -- which is what NATURAL finds. PostgreSQL rejects a natural join with no
  -- common column at all, so this entry is also a check on the fixture schema.
  , { name: "natural-join"
    , query: select' [ star ]
        # from "users"
        # naturalJoin LeftJoin "departments"
    }

  -- Grouping -----------------------------------------------------------------

  , { name: "group-by-having"
    , query: select' [ expr (col "department"), as (raw "COUNT(*)") "headcount" ]
        # from "users"
        # groupBy [ col "department" ]
        # having (raw "COUNT(*)" .> int 5)
        # orderBy [ desc (col "headcount") ]
    }

  -- PostgreSQL requires every select-list column to appear in some grouping
  -- set, so these entries are a check on the bracketing as much as on the
  -- keyword: a set that swallowed its neighbour would group by the wrong
  -- columns and be rejected.
  , { name: "group-by-grouping-sets"
    , query: select' (cols [ "department", "active" ] <> [ as countStar "headcount" ])
        # from "users"
        # groupBySets
            [ [ col "department" ]
            , [ col "department", col "active" ]
            , []
            ]
    }

  , { name: "group-by-rollup"
    , query: select' (cols [ "department", "active" ] <> [ as countStar "headcount" ])
        # from "users"
        # groupByRollup [ col "department", col "active" ]
    }

  , { name: "group-by-cube"
    , query: select' (cols [ "department", "active" ] <> [ as countStar "headcount" ])
        # from "users"
        # groupByCube [ col "department", col "active" ]
    }

  -- A plain grouping and a ROLLUP in the one clause: `GROUP BY "department",
  -- ROLLUP ("active")`, which is what making `groupBy` additive buys.
  , { name: "group-by-plain-and-rollup"
    , query: select' (cols [ "department", "active" ] <> [ as countStar "headcount" ])
        # from "users"
        # groupBy [ col "department" ]
        # groupByRollup [ col "active" ]
    }

  -- `GROUPING(…)` is what tells a subtotal row apart from a real NULL in the
  -- data: it is 1 where the column was rolled up and 0 where it was grouped by.
  -- No builder of its own — the generic `app` node already reaches it.
  , { name: "group-by-grouping-function"
    , query: select'
        ( cols [ "department" ] <>
            [ as (app "GROUPING" [ col "department" ]) "is_total"
            , as countStar "headcount"
            ]
        )
        # from "users"
        # groupByRollup [ col "department" ]
    }

  -- A grouping element carrying a parameter: the WHERE clause's is numbered
  -- first because it is emitted first, the ROLLUP's second. Only aggregates are
  -- selected, so the grouped expression need not be repeated in the select list
  -- — where it would carry a different parameter number and PostgreSQL, which
  -- matches the two as written, would reject the query.
  , { name: "group-by-rollup-parameters"
    , query: select' [ as countStar "headcount" ]
        # from "users"
        # where_ (col "active" .== bool true)
        # groupByRollup [ coalesce [ col "department", str "unknown" ] ]
    }

  -- Aggregate FILTER -----------------------------------------------------------

  -- The conditional count: one aggregate over the rows the predicate keeps and
  -- one over the whole group, both from the single pass a `WHERE` clause would
  -- have narrowed for all of them.
  , { name: "aggregate-filter-count"
    , query: select'
        ( cols [ "department" ] <>
            [ as (countStar `filterWhere` (col "active" .== bool true)) "active_count"
            , as countStar "total"
            ]
        )
        # from "users"
        # groupBy [ col "department" ]
    }

  , { name: "aggregate-filter-sum"
    , query: select'
        ( cols [ "user_id" ] <>
            [ as (sum_ (col "total") `filterWhere` (col "status" .== str "paid")) "paid_total" ]
        )
        # from "orders"
        # groupBy [ col "user_id" ]
    }

  -- `FILTER` precedes `OVER`, which is the order PostgreSQL's grammar fixes:
  -- the modifier belongs to the aggregate call and the window to what is done
  -- with its result. Emitting the two the other way round would not parse, so
  -- this entry is what holds the ordering.
  , { name: "aggregate-filter-over"
    , query: select'
        ( cols [ "user_id", "total" ] <>
            [ as
                ( ( sum_ (col "total") `filterWhere` (col "status" .== str "paid")
                  ) `over` partitionBy' [ col "user_id" ]
                )
                "paid_total"
            ]
        )
        # from "orders"
    }

  -- A filtered aggregate is legal in `HAVING`, where it decides which groups
  -- survive rather than what they report.
  , { name: "aggregate-filter-having"
    , query: select' (cols [ "department" ] <> [ as countStar "headcount" ])
        # from "users"
        # groupBy [ col "department" ]
        # having ((countStar `filterWhere` (col "active" .== bool true)) .> int 1)
    }

  -- `FILTER` binds to the aggregate call, tighter than any operator, so the
  -- subtraction around it brackets nothing — and PostgreSQL parses what we
  -- emit.
  , { name: "aggregate-filter-in-expression"
    , query: select'
        ( cols [ "department" ] <>
            [ as
                ( binOp "-" countStar
                    (countStar `filterWhere` (col "active" .== bool true))
                )
                "inactive_count"
            ]
        )
        # from "users"
        # groupBy [ col "department" ]
    }

  -- The predicate's parameter sits in the select list, so it is numbered ahead
  -- of the WHERE clause's.
  , { name: "aggregate-filter-parameters"
    , query: select' [ as (countStar `filterWhere` (col "age" .>= int 21)) "adults" ]
        # from "users"
        # where_ (col "active" .== bool true)
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

  , { name: "order-by-desc-nulls-last"
    , query: select' [ star ]
        # from "articles"
        # orderBy [ descNullsLast (col "published_at"), asc (col "title") ]
    }

  , { name: "order-by-asc-nulls-first"
    , query: select' [ star ]
        # from "users"
        # orderBy [ ascNullsFirst (col "email") ]
    }

  , { name: "order-by-desc-nulls-first"
    , query: select' [ star ]
        # from "users"
        # orderBy [ descNullsFirst (col "score") ]
    }

  , { name: "order-by-asc-nulls-last"
    , query: select' [ star ]
        # from "users"
        # orderBy [ ascNullsLast (col "email") ]
    }

  , { name: "order-by-using"
    , query: select' [ star ]
        # from "users"
        # orderBy [ orderUsing "<" (col "name") ]
    }

  , { name: "limit-offset"
    , query: select' [ star ]
        # from "articles"
        # orderBy [ desc (col "published_at") ]
        # limit 10
        # offset 20
    }

  -- `LIMIT ALL` is PostgreSQL's way of saying "no limit", equivalent to omitting
  -- the clause. It is a keyword, not a parameter, so it adds no bindings.
  , { name: "limit-all"
    , query: select' [ star ]
        # from "articles"
        # limitAll
    }

  -- Row locking ---------------------------------------------------------------

  -- The locking clause is emitted last, after LIMIT and OFFSET. PREPARE runs
  -- full parse analysis, so an entry misplacing it fails here — and PostgreSQL
  -- checks more than placement: it rejects a locking clause alongside DISTINCT,
  -- GROUP BY, HAVING, a window function or a set operation, which is why every
  -- entry below is a plain row-returning SELECT.

  , { name: "for-update"
    , query: select' [ star ]
        # from "orders"
        # where_ (col "status" .== str "pending")
        # forUpdate
    }

  -- The work queue: `LIMIT … FOR UPDATE SKIP LOCKED` hands each worker the
  -- first rows no other worker holds, rather than making it wait behind them.
  , { name: "for-update-skip-locked"
    , query: select' (cols [ "id", "total" ])
        # from "orders"
        # where_ (col "status" .== str "pending")
        # orderBy [ asc (col "placed_at") ]
        # limit 10
        # forUpdate
        # skipLocked
    }

  , { name: "for-update-nowait"
    , query: select' [ star ] # from "orders" # forUpdate # noWait
    }

  , { name: "for-no-key-update"
    , query: select' [ star ] # from "users" # forNoKeyUpdate
    }

  , { name: "for-share"
    , query: select' [ star ] # from "users" # forShare
    }

  , { name: "for-key-share"
    , query: select' [ star ] # from "users" # forKeyShare
    }

  -- `OF` names FROM items by the name they go by in the query, so this locks
  -- the orders and leaves the users it joins untouched. PostgreSQL rejects a
  -- name that is not in the FROM list — and rejects the table name of an
  -- aliased relation — so the quoting of the alias is what this entry holds.
  , { name: "for-update-of"
    , query: select' [ starFrom "o" ]
        # fromAs "orders" "o"
        # innerJoin "users" (tcol "o" "user_id" .== tcol "users" "id")
        # forUpdate
        # lockOf [ "o" ]
    }

  -- Two clauses at once, which is the whole reason `locking` is a list: the
  -- order is locked for writing while the user it belongs to is merely held
  -- against change.
  , { name: "for-update-of-and-for-share-of"
    , query: select' [ star ]
        # from "orders"
        # innerJoin "users" (tcol "orders" "user_id" .== tcol "users" "id")
        # forUpdate
        # lockOf [ "orders" ]
        # forShare
        # lockOf [ "users" ]
    }

  -- A locking clause carries no parameters of its own, so the WHERE clause's
  -- keep the numbers they would have had without it — which is what this entry
  -- is here to confirm.
  , { name: "for-update-after-parameters"
    , query: select' (cols [ "id" ])
        # from "orders"
        # where_ (and [ col "status" .== str "pending", col "total" .> num 10.0 ])
        # limit 5
        # offset 5
        # forUpdate
        # skipLocked
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

  -- Quantified comparisons (ANY / ALL) ----------------------------------------

  , { name: "any-subquery"
    , query: select' [ star ]
        # from "users"
        # where_
            ( eqAny (col "id")
                ( sub
                    ( select' [ expr (col "user_id") ] # from "orders" )
                )
            )
    }

  , { name: "all-subquery"
    , query: select' [ star ]
        # from "orders"
        # where_
            ( allOf ">" (col "total")
                ( sub
                    ( select' [ expr (col "total") ]
                        # from "orders"
                        # where_ (col "status" .== str "paid")
                    )
                )
            )
    }

  -- Parameters inside a quantified subquery are numbered in step with the
  -- outer query, as they are for IN (SELECT …).
  , { name: "any-subquery-parameter-ordering"
    , query: select' [ star ]
        # fromAs "users" "u"
        # where_
            ( and
                [ tcol "u" "active" .== bool true
                , eqAny (tcol "u" "id")
                    ( sub
                        ( select' [ expr (col "user_id") ]
                            # from "orders"
                            # where_ (col "status" .== str "paid")
                        )
                    )
                ]
            )
    }

  -- The general `anyOf` with an operator other than `=`.
  , { name: "any-subquery-operator"
    , query: select' [ star ]
        # from "orders"
        # where_
            ( anyOf "<" (col "total")
                ( sub
                    ( select' [ expr (col "total") ]
                        # from "orders"
                        # where_ (col "status" .== str "paid")
                    )
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

  -- LATERAL ------------------------------------------------------------------

  -- The shape LATERAL exists for: a per-row subquery, joined ON TRUE because
  -- the correlation inside it is the whole of the matching.
  , { name: "join-lateral"
    , query: select' [ expr (tcol "u" "name"), expr (tcol "recent" "total") ]
        # fromAs "users" "u"
        # joinLateral recentOrdersOfUser "recent"
    }

  -- The outer form keeps a user whose subquery finds nothing, which the inner
  -- one drops. RIGHT and FULL have no lateral form at all — PostgreSQL rejects
  -- a lateral reference from the right operand of either — so these two
  -- builders are the whole of it.
  , { name: "left-join-lateral"
    , query: select' [ expr (tcol "u" "name"), expr (tcol "recent" "total") ]
        # fromAs "users" "u"
        # leftJoinLateral recentOrdersOfUser "recent"
    }

  -- CROSS JOIN LATERAL says the same thing as `joinLateral` without the ON
  -- clause, and is how the comma form of a lateral join is spelled here.
  , { name: "cross-join-lateral"
    , query: select' [ expr (tcol "u" "name"), expr (tcol "recent" "total") ]
        # fromAs "users" "u"
        # joinRel (lateral recentOrdersOfUser "recent") Cross
    }

  -- A lateral join target sits ahead of its own ON clause in the emitted SQL,
  -- and both sit ahead of the outer WHERE: $1 is the subquery's, $2 the ON
  -- clause's, $3 the WHERE's.
  , { name: "join-lateral-parameter-ordering"
    , query: select' [ expr (tcol "u" "name"), expr (tcol "recent" "total") ]
        # fromAs "users" "u"
        # joinOn InnerJoin
            ( lateral
                ( select' (cols [ "total" ])
                    # from "orders"
                    # where_
                        ( and
                            [ tcol "orders" "user_id" .== tcol "u" "id"
                            , tcol "orders" "status" .== str "paid"
                            ]
                        )
                    # orderBy [ desc (col "placed_at") ]
                    # limit 3
                )
                "recent"
            )
            (tcol "recent" "total" .> int 100)
        # where_ (tcol "u" "active" .== bool true)
    }

  -- Nothing stands to the left of the first FROM item, so LATERAL there
  -- references nothing — PostgreSQL accepts it, which is what this entry
  -- confirms.
  , { name: "from-lateral"
    , query: select' [ starFrom "recent" ]
        # fromLateral
            ( select' (cols [ "id", "user_id", "total" ])
                # from "orders"
                # where_ (col "status" .== str "paid")
            )
            "recent"
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
                ( rowNumber `over`
                    ( partitionBy' [ col "department" ]
                        # orderWindow [ desc (col "age") ]
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
            [ as (rank `over` orderWindow' [ desc (col "score") ]) "rank"
            , as (denseRank `over` orderWindow' [ desc (col "score") ]) "dense_rank"
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
            ( avg (col "total") `over`
                ( orderWindow' [ asc (col "placed_at") ]
                    # withFrame (rows (preceding 3) (following 1))
                )
            )
            "moving_average"
        ]
        # from "orders"
    }

  , { name: "window-frame-range"
    , query: select'
        [ as
            ( sum_ (col "total") `over`
                ( orderWindow' [ asc (col "placed_at") ]
                    # withFrame (range currentRow unboundedFollowing)
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
            ( sum_ (col "total") `over`
                ( orderWindow' [ asc (col "placed_at") ]
                    # withFrame (groups unboundedPreceding currentRow)
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
            ( sum_ (col "total") `over`
                ( orderWindow' [ asc (col "placed_at") ]
                    # withFrame (frameFrom Rows unboundedPreceding)
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
        # orderBy [ asc (rank `over` orderWindow' [ desc (col "score") ]) ]
    }

  -- A window's parameters sit in the select list, so they are numbered before
  -- the WHERE clause's.
  , { name: "window-parameter-ordering"
    , query: select'
        [ as
            ( countStar `over` partitionBy' [ coalesce [ col "department", str "unknown" ] ]
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
  Quantified qop op l r -> nodes [ "Expr.Quantified", "Expr.Quantified." <> quantOpTag qop ] [ l, r ]
  Unary op x -> nodes [ "Expr.Unary", "Expr.Unary." <> op ] [ x ]
  Postfix op x -> nodes [ "Expr.Postfix", "Expr.Postfix." <> op ] [ x ]
  Cast x _ -> node "Expr.Cast" [ x ]
  Row xs -> node "Expr.Row" xs
  Sub q -> "Expr.Sub" : queryTags q
  And xs -> node (if Array.null xs then "Expr.And.empty" else "Expr.And") xs
  Or xs -> node (if Array.null xs then "Expr.Or.empty" else "Expr.Or") xs
  Between x lo hi -> node "Expr.Between" [ x, lo, hi ]
  Over f w -> ("Expr.Over" : exprTags f) <> windowTags w
  Filter agg predicate -> node "Expr.Filter" [ agg, predicate ]
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

-- | Each `GROUP BY` form is tagged apart, so the ratchet holds the plain,
-- | `GROUPING SETS`, `CUBE` and `ROLLUP` spellings each to a corpus entry of its
-- | own — and the empty grouping set apart from a populated one, since `()` is
-- | the bracketing the formatter is easiest to get wrong.
groupingTags :: GroupingElement -> Array String
groupingTags g = case g of
  GroupingExpr e -> "GroupingElement.GroupingExpr" : exprTags e
  GroupingSets sets -> "GroupingElement.GroupingSets" : Array.concatMap setTags sets
  Cube es -> "GroupingElement.Cube" : Array.concatMap exprTags es
  Rollup es -> "GroupingElement.Rollup" : Array.concatMap exprTags es
  where
  setTags [] = [ "GroupingElement.GroupingSets.empty" ]
  setTags es = Array.concatMap exprTags es

distinctTags :: Distinct -> Array String
distinctTags = case _ of
  Distinct -> [ "Query.distinct" ]
  DistinctOn exprs -> "Query.distinctOn" : Array.concatMap exprTags exprs

quantOpTag :: QuantOp -> String
quantOpTag = case _ of
  Any -> "ANY"
  All -> "ALL"

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

-- | Each join form is tagged apart, so the ratchet holds `ON`, `USING`,
-- | `NATURAL` and `CROSS` each to a corpus entry of its own. `Cross` carries no
-- | join type, which is why the type tag comes from the condition rather than
-- | from the join.
joinTags :: Join -> Array String
joinTags j = relationTags "Query.join" j.relation <> case j.condition of
  On type_ e -> [ "JoinCondition.On", joinTypeTag type_ ] <> exprTags e
  Using type_ _ -> [ "JoinCondition.Using", joinTypeTag type_ ]
  Natural type_ -> [ "JoinCondition.Natural", joinTypeTag type_ ]
  Cross -> [ "JoinCondition.Cross" ]

orderDirTag :: OrderDir -> String
orderDirTag = case _ of
  Asc -> "OrderDir.Asc"
  Desc -> "OrderDir.Desc"
  OrderUsing _ -> "OrderDir.OrderUsing"

nullOrderTag :: NullOrder -> String
nullOrderTag = case _ of
  NullsFirst -> "NullOrder.NullsFirst"
  NullsLast -> "NullOrder.NullsLast"

orderTags :: OrderExpr -> Array String
orderTags o = (orderDirTag o.dir : exprTags o.expr)
  <> maybe [] (\n -> [nullOrderTag n]) o.nulls

relationTags :: String -> Relation -> Array String
relationTags prefix (Table _ alias) = case alias of
  Nothing -> [ prefix ]
  Just _ -> [ prefix, prefix <> ".alias" ]
relationTags prefix (Derived q _) = (prefix <> ".derived") : queryTags q
relationTags prefix (Lateral q _) = (prefix <> ".lateral") : queryTags q

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

lockStrengthTag :: LockStrength -> String
lockStrengthTag = case _ of
  ForUpdate -> "LockStrength.ForUpdate"
  ForNoKeyUpdate -> "LockStrength.ForNoKeyUpdate"
  ForShare -> "LockStrength.ForShare"
  ForKeyShare -> "LockStrength.ForKeyShare"

lockWaitTag :: LockWait -> String
lockWaitTag = case _ of
  NoWait -> "LockWait.NoWait"
  SkipLocked -> "LockWait.SkipLocked"

lockingTags :: Locking -> Array String
lockingTags l =
  lockStrengthTag l.strength
    : (if Array.null l.tables then [] else [ "Query.locking.of" ])
    <> maybe [] (\w -> [ lockWaitTag w ]) l.wait

-- | More than one locking clause is tagged apart from a single one, so the
-- | ratchet holds the multi-clause form to a corpus entry of its own — the SQL
-- | it emits is a second `FOR …` after the first, which nothing else exercises.
lockingClauseTags :: Array Locking -> Array String
lockingClauseTags [] = []
lockingClauseTags ls =
  "Query.locking"
    : (if Array.length ls > 1 then [ "Query.locking.multiple" ] else [])
    <> Array.concatMap lockingTags ls

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
    <> (case q.distinct of
          Nothing -> []
          Just d -> distinctTags d)
    <> Array.concatMap selectTags q.select
    <> foldClause "Query.from" (map (relationTags "Query.from") q.from)
    <> Array.concatMap joinTags q.joins
    <> foldClause "Query.where" (map exprTags q.where_)
    <> clause "Query.groupBy" (Array.concatMap groupingTags q.groupBy) (Array.null q.groupBy)
    <> foldClause "Query.having" (map exprTags q.having)
    <> clause "Query.orderBy" (Array.concatMap orderTags q.orderBy) (Array.null q.orderBy)
    <> foldClause "Query.limit" (map exprTags q.limit)
    <> foldClause "Query.offset" (map exprTags q.offset)
    <> lockingClauseTags q.locking
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
  , "Expr.Filter"
  , "Expr.Quantified"
  , "Expr.Quantified.ANY"
  , "Expr.Quantified.ALL"
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
  , "JoinCondition.On"
  , "JoinCondition.Using"
  , "JoinCondition.Natural"
  , "JoinCondition.Cross"
  , "NullOrder.NullsFirst"
  , "NullOrder.NullsLast"
  , "OrderDir.Asc"
  , "OrderDir.Desc"
  , "OrderDir.OrderUsing"
  , "Query.with"
  , "Query.with.columns"
  , "Query.with.recursive"
  , "Query.distinct"
  , "Query.distinctOn"
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
  , "Query.join.lateral"
  , "Query.from.derived"
  , "Query.from.lateral"
  , "Query.where"
  , "Query.groupBy"
  , "GroupingElement.GroupingExpr"
  , "GroupingElement.GroupingSets"
  , "GroupingElement.GroupingSets.empty"
  , "GroupingElement.Cube"
  , "GroupingElement.Rollup"
  , "Query.having"
  , "Query.orderBy"
  , "Query.limit"
  , "Query.offset"
  , "Query.locking"
  , "Query.locking.of"
  , "Query.locking.multiple"
  , "LockStrength.ForUpdate"
  , "LockStrength.ForNoKeyUpdate"
  , "LockStrength.ForShare"
  , "LockStrength.ForKeyShare"
  , "LockWait.NoWait"
  , "LockWait.SkipLocked"
  ]

-- | Required tags with no corpus entry. Must be empty.
missingTags :: Array String
missingTags = Array.difference requiredTags coveredTags
