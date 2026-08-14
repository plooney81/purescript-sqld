module Sqld.Format where

import Prelude
import Data.Array (elem, filter, mapWithIndex, reverse) as Array
import Data.Foldable (foldl, intercalate)
import Data.Maybe (Maybe(..), maybe)
import Data.String as String
import Data.Tuple (Tuple(..))
import Sqld.Core (Expr(..), FormattedQuery, Join, JoinType(..), Literal(..), OrderDir(..), OrderExpr, Query, Relation(..), SelectExpr(..))

-- ---------------------------------------------------------------------------
-- State threading — pure, no Effect
-- ---------------------------------------------------------------------------

type Bindings =
  { params  :: Array Literal
  , counter :: Int
  }

emptyBindings :: Bindings
emptyBindings = { params: [], counter: 0 }

type WithBindings a = Bindings -> Tuple a Bindings

-- ---------------------------------------------------------------------------
-- Public entry points
-- ---------------------------------------------------------------------------

format :: Query -> FormattedQuery
format q = { sql, params: state.params }
  where
  Tuple sql state = formatQuery " " q emptyBindings

-- | Inline all literals directly into the SQL string, single line.
-- | Intended for debugging and logging only — never pass user input through this.
formatInline :: Query -> String
formatInline = inlineWith " "

-- | Like formatInline but with each clause on its own line.
-- | Intended for debugging and logging only — never pass user input through this.
formatPretty :: Query -> String
formatPretty = inlineWith "\n"

inlineWith :: String -> Query -> String
inlineWith sep q = foldl substitute sql subs
  where
  Tuple sql state = formatQuery sep q emptyBindings

  -- Substitute from highest index first so $10 isn't clobbered by $1
  subs = Array.reverse (Array.mapWithIndex (\i l -> Tuple (i + 1) l) state.params)

  substitute acc (Tuple i l) =
    String.replaceAll
      (String.Pattern ("$" <> show i))
      (String.Replacement (inlineLiteral l))
      acc

inlineLiteral :: Literal -> String
inlineLiteral (LitInt n)     = show n
inlineLiteral (LitNumber n)  = show n
inlineLiteral (LitString s)  = "'" <> String.replaceAll (String.Pattern "'") (String.Replacement "''") s <> "'"
inlineLiteral (LitBoolean b) = if b then "TRUE" else "FALSE"
inlineLiteral LitNull        = "NULL"

-- ---------------------------------------------------------------------------
-- Query-level formatter
-- ---------------------------------------------------------------------------

formatQuery :: String -> Query -> WithBindings String
formatQuery sep q state0 = Tuple sql s7
  where
  Tuple selectSql  s1 = formatSelect  q.select    state0
  Tuple fromSql    s2 = formatFrom    q.from      s1
  Tuple joinsSql   s3 = formatJoins   sep q.joins s2
  Tuple whereSql   s4 = formatWhere   q.where_    s3
  Tuple groupBySql s5 = formatGroupBy q.groupBy   s4
  Tuple havingSql  s6 = formatHaving  q.having    s5
  Tuple orderBySql s7 = formatOrderBy q.orderBy   s6

  limitSql  = formatLimit  q.limit
  offsetSql = formatOffset q.offset

  parts = Array.filter (_ /= mempty)
    [ selectSql, fromSql, joinsSql, whereSql
    , groupBySql, havingSql, orderBySql, limitSql, offsetSql ]

  sql = intercalate sep parts

-- ---------------------------------------------------------------------------
-- Clause formatters
-- ---------------------------------------------------------------------------

formatSelect :: Array SelectExpr -> WithBindings String
formatSelect exprs state = Tuple ("SELECT " <> intercalate ", " parts) s'
  where
  Tuple parts s' = mapAccum formatSelectExpr state exprs

formatSelectExpr :: SelectExpr -> WithBindings String
formatSelectExpr SelectStar state =
  Tuple "*" state
formatSelectExpr (SelectStarFrom t) state =
  Tuple (quoteIdent t <> ".*") state
formatSelectExpr (SelectExpr e) state =
  formatExpr e state
formatSelectExpr (SelectAs e alias) state = Tuple (exprSql <> " AS " <> quoteIdent alias) s'
  where
  Tuple exprSql s' = formatExpr e state

formatFrom :: Maybe Relation -> WithBindings String
formatFrom Nothing  state = Tuple mempty state
formatFrom (Just r) state = Tuple ("FROM " <> sql) s'
  where
  Tuple sql s' = formatRelation r state

-- | Threads bindings because a derived table carries parameters of its own,
-- | which must be numbered where they appear in the emitted SQL.
formatRelation :: Relation -> WithBindings String
formatRelation (Table name alias) state =
  Tuple (quoteIdent name <> maybe mempty (\a -> " AS " <> quoteIdent a) alias) state
formatRelation (Derived q alias) state = Tuple ("(" <> sql <> ") AS " <> quoteIdent alias) s'
  where
  Tuple sql s' = formatQuery " " q state

formatJoins :: String -> Array Join -> WithBindings String
formatJoins _ [] state = Tuple mempty state
formatJoins sep joins state = Tuple (intercalate sep parts) s'
  where
  Tuple parts s' = mapAccum formatJoin state joins

formatJoin :: Join -> WithBindings String
formatJoin j state = Tuple (kw <> " " <> relSql <> " ON (" <> onSql <> ")") s2
  where
  kw = case j.type_ of
    InnerJoin -> "JOIN"
    LeftJoin  -> "LEFT JOIN"
    RightJoin -> "RIGHT JOIN"
    FullJoin  -> "FULL JOIN"

  -- Relation before condition: a derived join target's parameters appear
  -- earlier in the SQL than the ON clause's.
  Tuple relSql s1 = formatRelation j.relation state
  Tuple onSql  s2 = formatExpr j.on s1

formatWhere :: Maybe Expr -> WithBindings String
formatWhere Nothing  state = Tuple mempty state
formatWhere (Just e) state = Tuple ("WHERE " <> sql) s'
  where
  Tuple sql s' = formatExpr e state

formatGroupBy :: Array Expr -> WithBindings String
formatGroupBy [] state = Tuple mempty state
formatGroupBy exprs state = Tuple ("GROUP BY " <> intercalate ", " parts) s'
  where
  Tuple parts s' = mapAccum formatExpr state exprs

formatHaving :: Maybe Expr -> WithBindings String
formatHaving Nothing  state = Tuple mempty state
formatHaving (Just e) state = Tuple ("HAVING " <> sql) s'
  where
  Tuple sql s' = formatExpr e state

formatOrderBy :: Array OrderExpr -> WithBindings String
formatOrderBy [] state = Tuple mempty state
formatOrderBy exprs state = Tuple ("ORDER BY " <> intercalate ", " parts) s'
  where
  Tuple parts s' = mapAccum formatOrderExpr state exprs

formatOrderExpr :: OrderExpr -> WithBindings String
formatOrderExpr { expr, dir } state = Tuple (sql <> " " <> dirSql) s'
  where
  Tuple sql s' = formatExpr expr state

  dirSql = case dir of
    Asc  -> "ASC"
    Desc -> "DESC"

formatLimit :: Maybe Int -> String
formatLimit Nothing  = mempty
formatLimit (Just n) = "LIMIT " <> show n

formatOffset :: Maybe Int -> String
formatOffset Nothing  = mempty
formatOffset (Just n) = "OFFSET " <> show n

-- ---------------------------------------------------------------------------
-- Operator precedence
-- ---------------------------------------------------------------------------
--
-- Mirrors PostgreSQL's precedence table so the printer emits parentheses only
-- where they change meaning. Higher binds tighter.
--
-- `And` and `Or` are deliberately absent: they parenthesise themselves, so as
-- far as the surrounding expression is concerned they are atoms. `Raw` is an
-- atom too — its contents are opaque, so its parenthesisation is the caller's
-- responsibility.

atomPrec :: Int
atomPrec = 99

precOf :: Expr -> Int
precOf (BinOp op _ _)  = opPrec op
precOf (Unary op _)    = unaryPrec op
precOf (Postfix _ _)   = 4
precOf (Cast _ _)      = 12
precOf (Between _ _ _) = 6
precOf _               = atomPrec

opPrec :: String -> Int
opPrec op
  | Array.elem op [ "=", "<>", "<", ">", "<=", ">=" ] = 5
  | Array.elem op [ "IN", "NOT IN", "LIKE", "ILIKE", "NOT LIKE", "NOT ILIKE", "SIMILAR TO" ] = 6
  | Array.elem op [ "+", "-" ] = 8
  | Array.elem op [ "*", "/", "%" ] = 9
  | op == "^" = 10
  -- PostgreSQL groups every other operator at a single level between the
  -- pattern operators and arithmetic, which is where user-supplied operators
  -- such as `@>` and `->>` land.
  | otherwise = 7

unaryPrec :: String -> Int
unaryPrec op
  | op == "NOT" = 3
  | Array.elem op [ "EXISTS", "NOT EXISTS" ] = 4
  | otherwise = 11

-- ---------------------------------------------------------------------------
-- Expression formatter — recursive, left-to-right param numbering
-- ---------------------------------------------------------------------------

formatExpr :: Expr -> WithBindings String
formatExpr (Col { table: Nothing, column }) state =
  Tuple (quoteIdent column) state
formatExpr (Col { table: Just t, column }) state =
  Tuple (quoteIdent t <> "." <> quoteIdent column) state
formatExpr (Lit literal) state =
  Tuple ("$" <> show idx) { params: state.params <> [ literal ], counter: idx }
  where
  idx = state.counter + 1
formatExpr (App name args) state = Tuple (name <> "(" <> intercalate ", " parts <> ")") s'
  where
  Tuple parts s' = mapAccum formatExpr state args
formatExpr (BinOp op l r) state = Tuple (lSql <> " " <> op <> " " <> rSql) s2
  where
  prec = opPrec op
  Tuple lSql s1 = formatChild prec l state
  -- Left-associative: an equal-precedence right operand needs bracketing.
  Tuple rSql s2 = formatChild (prec + 1) r s1
formatExpr (Unary op e) state = Tuple (op <> " " <> sql) s'
  where
  Tuple sql s' = formatChild (unaryPrec op) e state
formatExpr (Postfix op e) state = Tuple (sql <> " " <> op) s'
  where
  Tuple sql s' = formatChild 4 e state
formatExpr (Cast e ty) state = Tuple (sql <> "::" <> ty) s'
  where
  Tuple sql s' = formatChild 12 e state
formatExpr (Row exprs) state = Tuple ("(" <> intercalate ", " parts <> ")") s'
  where
  Tuple parts s' = mapAccum formatExpr state exprs
formatExpr (Sub q) state = Tuple ("(" <> sql <> ")") s'
  where
  -- Subqueries render on one line regardless of the outer separator: a nested
  -- SELECT reads better inline than broken across the parent's clauses.
  Tuple sql s' = formatQuery " " q state
formatExpr (And [])    state = Tuple "TRUE"  state
formatExpr (And exprs) state = Tuple ("(" <> intercalate " AND " parts <> ")") s'
  where
  Tuple parts s' = mapAccum formatExpr state exprs
formatExpr (Or [])    state = Tuple "FALSE" state
formatExpr (Or exprs) state = Tuple ("(" <> intercalate " OR " parts <> ")") s'
  where
  Tuple parts s' = mapAccum formatExpr state exprs
formatExpr (Between e lo hi) state =
  Tuple (eSql <> " BETWEEN " <> loSql <> " AND " <> hiSql) s3
  where
  Tuple eSql  s1 = formatChild 7 e  state
  Tuple loSql s2 = formatChild 7 lo s1
  Tuple hiSql s3 = formatChild 7 hi s2
formatExpr (Raw sql) state = Tuple sql state

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Formats a sub-expression, parenthesising it only if it binds more loosely
-- | than its position allows.
formatChild :: Int -> Expr -> WithBindings String
formatChild minPrec e state =
  Tuple (if precOf e < minPrec then "(" <> sql <> ")" else sql) s'
  where
  Tuple sql s' = formatExpr e state

mapAccum :: ∀ a. (a -> WithBindings String) -> Bindings -> Array a -> Tuple (Array String) Bindings
mapAccum f s0 xs = foldl step (Tuple [] s0) xs
  where
  step (Tuple acc st) x = Tuple (acc <> [ r ]) st'
    where
    Tuple r st' = f x st

quoteIdent :: String -> String
quoteIdent ident =
  "\"" <> String.replaceAll (String.Pattern "\"") (String.Replacement "\"\"") ident <> "\""
