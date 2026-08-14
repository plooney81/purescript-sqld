module Sqld.Select where

import Data.Array (null) as Array
import Data.Maybe (Maybe(..))
import Prelude (($), (<<<), (<>), map)
import Sqld.Core (Expr(..), JoinType(..), OrderDir(..), OrderExpr, Query, Relation(..), SelectExpr(..), emptyQuery)
import Sqld.Expr (col, tcol)

-- ---------------------------------------------------------------------------
-- Relations
-- ---------------------------------------------------------------------------

rel :: String -> Relation
rel name = Table name Nothing

relAs :: String -> String -> Relation
relAs name alias = Table name (Just alias)

-- | A derived table — a subquery in `FROM`. The alias is mandatory because
-- | PostgreSQL requires one.
derived :: Query -> String -> Relation
derived = Derived

-- ---------------------------------------------------------------------------
-- FROM
-- ---------------------------------------------------------------------------

fromRel :: Relation -> Query -> Query
fromRel r q = q { from = Just r }

from :: String -> Query -> Query
from table = fromRel $ rel table

fromAs :: String -> String -> Query -> Query
fromAs table alias = fromRel $ relAs table alias

-- | `FROM (SELECT …) AS alias`.
fromSub :: Query -> String -> Query -> Query
fromSub sub alias = fromRel $ derived sub alias

-- ---------------------------------------------------------------------------
-- SELECT / WHERE
-- ---------------------------------------------------------------------------

select :: Array SelectExpr -> Query -> Query
select exprs q = q { select = q.select <> exprs }

-- | Starts a query from its select list, so the common case need not name
-- | `emptyQuery`:
-- |
-- |     select' (cols [ "id", "name" ]) # from "users"
-- |
-- | `select` is additive, so further `select` calls append as usual. Build
-- | reusable `Query -> Query` fragments with `select` and apply them to
-- | `emptyQuery` at the end.
select' :: Array SelectExpr -> Query
select' exprs = select exprs emptyQuery

where_ :: Expr -> Query -> Query
where_ e q = q { where_ = Just $ case q.where_ of
  Nothing   -> e
  Just prev -> And [prev, e] }

setWhere :: Expr -> Query -> Query
setWhere e q = q { where_ = Just e }

-- ---------------------------------------------------------------------------
-- Joins
-- ---------------------------------------------------------------------------

-- | The general form. The named helpers below cover the common cases; reach
-- | for this one to join against a derived table.
joinOn :: JoinType -> Relation -> Expr -> Query -> Query
joinOn type_ relation on q =
  q { joins = q.joins <> [ { type_, relation, on } ] }

innerJoin :: String -> Expr -> Query -> Query
innerJoin table = joinOn InnerJoin (rel table)

innerJoinAs :: String -> String -> Expr -> Query -> Query
innerJoinAs table alias = joinOn InnerJoin (relAs table alias)

leftJoin :: String -> Expr -> Query -> Query
leftJoin table = joinOn LeftJoin (rel table)

leftJoinAs :: String -> String -> Expr -> Query -> Query
leftJoinAs table alias = joinOn LeftJoin (relAs table alias)

rightJoin :: String -> Expr -> Query -> Query
rightJoin table = joinOn RightJoin (rel table)

rightJoinAs :: String -> String -> Expr -> Query -> Query
rightJoinAs table alias = joinOn RightJoin (relAs table alias)

fullJoin :: String -> Expr -> Query -> Query
fullJoin table = joinOn FullJoin (rel table)

fullJoinAs :: String -> String -> Expr -> Query -> Query
fullJoinAs table alias = joinOn FullJoin (relAs table alias)

-- ---------------------------------------------------------------------------
-- Remaining clauses
-- ---------------------------------------------------------------------------

orderBy :: Array OrderExpr -> Query -> Query
orderBy exprs q = q { orderBy = exprs }

groupBy :: Array Expr -> Query -> Query
groupBy exprs q = q { groupBy = exprs }

having :: Expr -> Query -> Query
having e q = q { having = Just e }

limit :: Int -> Query -> Query
limit n q = q { limit = Just n }

offset :: Int -> Query -> Query
offset n q = q { offset = Just n }

-- ---------------------------------------------------------------------------
-- SELECT list helpers
-- ---------------------------------------------------------------------------

star :: SelectExpr
star = SelectStar

-- | `"t".*` — every column of one relation.
starFrom :: String -> SelectExpr
starFrom = SelectStarFrom

expr :: Expr -> SelectExpr
expr = SelectExpr

-- | The plural of `expr`, for a run of bare expressions.
-- |
-- | A PureScript array is homogeneous, so a select list mixing bare and
-- | aliased items is built by concatenating:
-- |
-- |     select (cols [ "department" ] <> [ as countStar "headcount" ])
-- |
-- | `select` is also additive, so repeated calls append rather than replace.
exprs :: Array Expr -> Array SelectExpr
exprs = map SelectExpr

-- | Plain column references. Names may be dot-qualified: `cols [ "u.id" ]`
-- | renders `"u"."id"`.
cols :: Array String -> Array SelectExpr
cols = map (SelectExpr <<< col)

-- | Columns sharing one table qualifier: `tcols "u" [ "id", "name" ]` renders
-- | `"u"."id", "u"."name"`.
tcols :: String -> Array String -> Array SelectExpr
tcols t = map (SelectExpr <<< tcol t)

as :: Expr -> String -> SelectExpr
as = SelectAs

colAs :: String -> String -> SelectExpr
colAs c alias = SelectAs (col c) alias

tcolAs :: String -> String -> String -> SelectExpr
tcolAs t c alias = SelectAs (Col { table: Just t, column: c }) alias

asc :: Expr -> OrderExpr
asc e = { expr: e, dir: Asc }

desc :: Expr -> OrderExpr
desc e = { expr: e, dir: Desc }

-- ---------------------------------------------------------------------------
-- Composition
-- ---------------------------------------------------------------------------

mergeQueries :: Query -> Query -> Query
mergeQueries base override =
  { select:  if Array.null override.select  then base.select  else override.select
  , from:    case override.from of
               Nothing -> base.from
               Just _  -> override.from
  , joins:   base.joins <> override.joins
  , where_:  case base.where_, override.where_ of
               Nothing, Nothing -> Nothing
               Just a,  Nothing -> Just a
               Nothing, Just b  -> Just b
               Just a,  Just b  -> Just (And [a, b])
  , groupBy: base.groupBy <> override.groupBy
  , having:  case override.having of
               Nothing -> base.having
               Just _  -> override.having
  , orderBy: if Array.null override.orderBy then base.orderBy else override.orderBy
  , limit:   case override.limit of
               Nothing -> base.limit
               Just _  -> override.limit
  , offset:  case override.offset of
               Nothing -> base.offset
               Just _  -> override.offset
  }
