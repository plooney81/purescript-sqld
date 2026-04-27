module Sqld.Builder where

import Prelude hiding (not, between)
import Data.Array (null) as Array
import Data.Maybe (Maybe(..))
import Sqld.Core

-- ---------------------------------------------------------------------------
-- Query builders — each is Query -> Query so they compose with >>> or #
-- ---------------------------------------------------------------------------

select :: Array SelectExpr -> Query -> Query
select exprs q = q { select = exprs }

from :: String -> Query -> Query
from table q = q { from = Just { name: table, alias: Nothing } }

fromAs :: String -> String -> Query -> Query
fromAs table alias q = q { from = Just { name: table, alias: Just alias } }

-- | Append a WHERE clause; ANDs with any existing condition.
where_ :: Expr -> Query -> Query
where_ expr q = q { where_ = Just $ case q.where_ of
  Nothing   -> expr
  Just prev -> And [prev, expr] }

-- | Replace the WHERE clause entirely.
setWhere :: Expr -> Query -> Query
setWhere expr q = q { where_ = Just expr }

innerJoin :: String -> Expr -> Query -> Query
innerJoin table on q =
  q { joins = q.joins <>
        [{ type_: InnerJoin, relation: { name: table, alias: Nothing }, on }] }

leftJoin :: String -> Expr -> Query -> Query
leftJoin table on q =
  q { joins = q.joins <>
        [{ type_: LeftJoin, relation: { name: table, alias: Nothing }, on }] }

leftJoinAs :: String -> String -> Expr -> Query -> Query
leftJoinAs table alias on q =
  q { joins = q.joins <>
        [{ type_: LeftJoin, relation: { name: table, alias: Just alias }, on }] }

orderBy :: Array OrderExpr -> Query -> Query
orderBy exprs q = q { orderBy = exprs }

groupBy :: Array Expr -> Query -> Query
groupBy exprs q = q { groupBy = exprs }

having :: Expr -> Query -> Query
having expr q = q { having = Just expr }

limit :: Int -> Query -> Query
limit n q = q { limit = Just n }

offset :: Int -> Query -> Query
offset n q = q { offset = Just n }

-- ---------------------------------------------------------------------------
-- Expression constructors
-- ---------------------------------------------------------------------------

col :: String -> Expr
col c = Col { table: Nothing, column: c }

tcol :: String -> String -> Expr
tcol t c = Col { table: Just t, column: c }

star :: SelectExpr
star = SelectStar

starFrom :: String -> SelectExpr
starFrom = SelectStarFrom

s :: Expr -> SelectExpr
s = SelectExpr

as :: Expr -> String -> SelectExpr
as = SelectAs

lit :: Literal -> Expr
lit = Lit

int :: Int -> Expr
int = Lit <<< LitInt

num :: Number -> Expr
num = Lit <<< LitNumber

str :: String -> Expr
str = Lit <<< LitString

bool :: Boolean -> Expr
bool = Lit <<< LitBoolean

null :: Expr
null = Lit LitNull

asc :: Expr -> OrderExpr
asc e = { expr: e, dir: Asc }

desc :: Expr -> OrderExpr
desc e = { expr: e, dir: Desc }

-- ---------------------------------------------------------------------------
-- Infix comparison operators
-- ---------------------------------------------------------------------------

infix 4 Eq  as .==
infix 4 Neq as .!=
infix 4 Lt  as .<
infix 4 Lte as .<=
infix 4 Gt  as .>
infix 4 Gte as .>=

-- ---------------------------------------------------------------------------
-- Logical combinators
-- ---------------------------------------------------------------------------

and :: Array Expr -> Expr
and = And

or :: Array Expr -> Expr
or = Or

not :: Expr -> Expr
not = Not

isNull :: Expr -> Expr
isNull = IsNull

isNotNull :: Expr -> Expr
isNotNull = IsNotNull

in_ :: Expr -> Array Expr -> Expr
in_ = In

notIn :: Expr -> Array Expr -> Expr
notIn = NotIn

like :: Expr -> String -> Expr
like e pattern = Like e (str pattern)

between :: Expr -> Expr -> Expr -> Expr
between = Between

raw :: String -> Expr
raw = Raw

-- ---------------------------------------------------------------------------
-- Merge — right-hand scalars win; arrays concat; WHERE clauses AND together
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
