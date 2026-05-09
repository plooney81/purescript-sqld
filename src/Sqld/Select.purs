module Sqld.Select where

import Data.Array (null) as Array
import Data.Maybe (Maybe(..))
import Prelude (($), (<<<), (<>), map)
import Sqld.Core (Expr(..), JoinType(..), OrderDir(..), OrderExpr, Query, Relation, SelectExpr(..))
import Sqld.Expr (col)

rel :: String -> Relation
rel name = { name, alias: Nothing }

relAs :: String -> String -> Relation
relAs name alias = { name, alias: Just alias }

select :: Array SelectExpr -> Query -> Query
select exprs q = q { select = q.select <> exprs }

from :: String -> Query -> Query
from table q = q { from = Just $ rel table }

fromAs :: String -> String -> Query -> Query
fromAs table alias q = q { from = Just $ relAs table alias }

where_ :: Expr -> Query -> Query
where_ e q = q { where_ = Just $ case q.where_ of
  Nothing   -> e
  Just prev -> And [prev, e] }

setWhere :: Expr -> Query -> Query
setWhere e q = q { where_ = Just e }

innerJoin :: String -> Expr -> Query -> Query
innerJoin table on q =
  q { joins = q.joins <> [{ type_: InnerJoin, relation: rel table, on }] }

leftJoin :: String -> Expr -> Query -> Query
leftJoin table on q =
  q { joins = q.joins <> [{ type_: LeftJoin, relation: rel table, on }] }

leftJoinAs :: String -> String -> Expr -> Query -> Query
leftJoinAs table alias on q =
  q { joins = q.joins <> [{ type_: LeftJoin, relation: relAs table alias, on }] }

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

star :: SelectExpr
star = SelectStar

expr :: Expr -> SelectExpr
expr = SelectExpr

cols :: Array String -> Array SelectExpr
cols = map (SelectExpr <<< col)

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
