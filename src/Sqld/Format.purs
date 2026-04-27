module Sqld.Format where

import Prelude
import Data.Array (filter) as Array
import Data.Foldable (foldl, intercalate)
import Data.Maybe (Maybe(..), maybe)
import Data.String as String
import Data.Tuple (Tuple(..))
import Sqld.Core

-- ---------------------------------------------------------------------------
-- State threading — pure, no Effect
-- ---------------------------------------------------------------------------

type FormatState =
  { params  :: Array Literal
  , counter :: Int
  }

initialState :: FormatState
initialState = { params: [], counter: 0 }

type WithState a = FormatState -> Tuple a FormatState

-- ---------------------------------------------------------------------------
-- Public entry point
-- ---------------------------------------------------------------------------

format :: Query -> FormattedQuery
format q =
  let Tuple sql state = formatQuery q initialState
  in { sql, params: state.params }

-- ---------------------------------------------------------------------------
-- Query-level formatter
-- ---------------------------------------------------------------------------

formatQuery :: Query -> WithState String
formatQuery q state0 =
  let
    Tuple selectSql  s1 = formatSelect  q.select  state0
    Tuple fromSql    s2 = formatFrom    q.from    s1
    Tuple joinsSql   s3 = formatJoins   q.joins   s2
    Tuple whereSql   s4 = formatWhere   q.where_  s3
    Tuple groupBySql s5 = formatGroupBy q.groupBy s4
    Tuple havingSql  s6 = formatHaving  q.having  s5
    Tuple orderBySql s7 = formatOrderBy q.orderBy s6
    limitSql             = formatLimit  q.limit
    offsetSql            = formatOffset q.offset
    parts = Array.filter (_ /= "")
      [ selectSql, fromSql, joinsSql, whereSql
      , groupBySql, havingSql, orderBySql, limitSql, offsetSql ]
    sql = intercalate " " parts
  in
    Tuple sql s7

-- ---------------------------------------------------------------------------
-- Clause formatters
-- ---------------------------------------------------------------------------

formatSelect :: Array SelectExpr -> WithState String
formatSelect [] state = Tuple "SELECT *" state
formatSelect exprs state =
  let Tuple parts s' = mapAccum formatSelectExpr state exprs
  in Tuple ("SELECT " <> intercalate ", " parts) s'

formatSelectExpr :: SelectExpr -> WithState String
formatSelectExpr SelectStar state =
  Tuple "*" state
formatSelectExpr (SelectStarFrom t) state =
  Tuple (quoteIdent t <> ".*") state
formatSelectExpr (SelectExpr e) state =
  formatExpr e state
formatSelectExpr (SelectAs e alias) state =
  let Tuple exprSql s' = formatExpr e state
  in Tuple (exprSql <> " AS " <> quoteIdent alias) s'

formatFrom :: Maybe Relation -> WithState String
formatFrom Nothing  state = Tuple "" state
formatFrom (Just r) state = Tuple ("FROM " <> formatRelation r) state

formatRelation :: Relation -> String
formatRelation { name, alias } =
  quoteIdent name <> maybe "" (\a -> " " <> quoteIdent a) alias

formatJoins :: Array Join -> WithState String
formatJoins [] state = Tuple "" state
formatJoins joins state =
  let Tuple parts s' = mapAccum formatJoin state joins
  in Tuple (intercalate " " parts) s'

formatJoin :: Join -> WithState String
formatJoin j state =
  let
    kw = case j.type_ of
      InnerJoin -> "JOIN"
      LeftJoin  -> "LEFT JOIN"
      RightJoin -> "RIGHT JOIN"
      FullJoin  -> "FULL JOIN"
    Tuple onSql s' = formatExpr j.on state
  in
    Tuple (kw <> " " <> formatRelation j.relation <> " ON (" <> onSql <> ")") s'

formatWhere :: Maybe Expr -> WithState String
formatWhere Nothing  state = Tuple "" state
formatWhere (Just e) state =
  let Tuple sql s' = formatExpr e state
  in Tuple ("WHERE " <> sql) s'

formatGroupBy :: Array Expr -> WithState String
formatGroupBy [] state = Tuple "" state
formatGroupBy exprs state =
  let Tuple parts s' = mapAccum formatExpr state exprs
  in Tuple ("GROUP BY " <> intercalate ", " parts) s'

formatHaving :: Maybe Expr -> WithState String
formatHaving Nothing  state = Tuple "" state
formatHaving (Just e) state =
  let Tuple sql s' = formatExpr e state
  in Tuple ("HAVING " <> sql) s'

formatOrderBy :: Array OrderExpr -> WithState String
formatOrderBy [] state = Tuple "" state
formatOrderBy exprs state =
  let Tuple parts s' = mapAccum formatOrderExpr state exprs
  in Tuple ("ORDER BY " <> intercalate ", " parts) s'

formatOrderExpr :: OrderExpr -> WithState String
formatOrderExpr { expr, dir } state =
  let
    Tuple sql s' = formatExpr expr state
    dirSql = case dir of
      Asc  -> "ASC"
      Desc -> "DESC"
  in Tuple (sql <> " " <> dirSql) s'

formatLimit :: Maybe Int -> String
formatLimit Nothing  = ""
formatLimit (Just n) = "LIMIT " <> show n

formatOffset :: Maybe Int -> String
formatOffset Nothing  = ""
formatOffset (Just n) = "OFFSET " <> show n

-- ---------------------------------------------------------------------------
-- Expression formatter — recursive, left-to-right param numbering
-- ---------------------------------------------------------------------------

formatExpr :: Expr -> WithState String
formatExpr (Col { table: Nothing, column }) state =
  Tuple (quoteIdent column) state
formatExpr (Col { table: Just t, column }) state =
  Tuple (quoteIdent t <> "." <> quoteIdent column) state
formatExpr (Lit literal) state =
  let idx = state.counter + 1
  in Tuple ("$" <> show idx) { params: state.params <> [literal], counter: idx }
formatExpr (Eq  l r) state = formatBinOp "="  l r state
formatExpr (Neq l r) state = formatBinOp "<>" l r state
formatExpr (Lt  l r) state = formatBinOp "<"  l r state
formatExpr (Lte l r) state = formatBinOp "<=" l r state
formatExpr (Gt  l r) state = formatBinOp ">"  l r state
formatExpr (Gte l r) state = formatBinOp ">=" l r state
formatExpr (And [])    state = Tuple "TRUE"  state
formatExpr (And exprs) state =
  let Tuple parts s' = mapAccum formatExpr state exprs
  in Tuple ("(" <> intercalate " AND " parts <> ")") s'
formatExpr (Or [])    state = Tuple "FALSE" state
formatExpr (Or exprs) state =
  let Tuple parts s' = mapAccum formatExpr state exprs
  in Tuple ("(" <> intercalate " OR " parts <> ")") s'
formatExpr (Not e) state =
  let Tuple sql s' = formatExpr e state
  in Tuple ("NOT " <> sql) s'
formatExpr (IsNull e) state =
  let Tuple sql s' = formatExpr e state
  in Tuple (sql <> " IS NULL") s'
formatExpr (IsNotNull e) state =
  let Tuple sql s' = formatExpr e state
  in Tuple (sql <> " IS NOT NULL") s'
formatExpr (In e vals) state =
  let
    Tuple exprSql s1 = formatExpr e state
    Tuple parts   s2 = mapAccum formatExpr s1 vals
  in Tuple (exprSql <> " IN (" <> intercalate ", " parts <> ")") s2
formatExpr (NotIn e vals) state =
  let
    Tuple exprSql s1 = formatExpr e state
    Tuple parts   s2 = mapAccum formatExpr s1 vals
  in Tuple (exprSql <> " NOT IN (" <> intercalate ", " parts <> ")") s2
formatExpr (Like e pat) state =
  let
    Tuple lSql s1 = formatExpr e state
    Tuple rSql s2 = formatExpr pat s1
  in Tuple (lSql <> " LIKE " <> rSql) s2
formatExpr (Between e lo hi) state =
  let
    Tuple eSql  s1 = formatExpr e   state
    Tuple loSql s2 = formatExpr lo  s1
    Tuple hiSql s3 = formatExpr hi  s2
  in Tuple (eSql <> " BETWEEN " <> loSql <> " AND " <> hiSql) s3
formatExpr (Raw sql) state = Tuple sql state

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

formatBinOp :: String -> Expr -> Expr -> WithState String
formatBinOp op l r state =
  let
    Tuple lSql s1 = formatExpr l state
    Tuple rSql s2 = formatExpr r s1
  in Tuple (lSql <> " " <> op <> " " <> rSql) s2

mapAccum :: forall a. (a -> WithState String) -> FormatState -> Array a -> Tuple (Array String) FormatState
mapAccum f s0 xs = foldl step (Tuple [] s0) xs
  where
  step (Tuple acc st) x =
    let Tuple r st' = f x st
    in Tuple (acc <> [r]) st'

quoteIdent :: String -> String
quoteIdent ident =
  "\"" <> String.replaceAll (String.Pattern "\"") (String.Replacement "\"\"") ident <> "\""
