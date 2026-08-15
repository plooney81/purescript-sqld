module Sqld.Format where

import Prelude
import Data.Array (elem, filter, mapWithIndex, reverse) as Array
import Data.Foldable (foldl, intercalate)
import Data.Maybe (Maybe(..), maybe)
import Data.Monoid (power)
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
-- Layout — how a query's clauses are laid out on the page
-- ---------------------------------------------------------------------------

-- | `Inline` keeps a query on one line. `Pretty` gives each clause its own
-- | line, carrying the nesting depth so a subquery indents one step further
-- | than the query that contains it.
data Layout
  = Inline
  | Pretty Int

-- | What separates one clause from the next.
clauseSep :: Layout -> String
clauseSep Inline           = " "
clauseSep (Pretty depth)   = "\n" <> power indent depth

-- | One level of indentation. Not configurable by design — see issue #6.
indent :: String
indent = "  "

-- | The layout a nested query renders at.
nest :: Layout -> Layout
nest Inline          = Inline
nest (Pretty depth)  = Pretty (depth + 1)

-- | Parenthesises a nested query, giving it an indented block of its own when
-- | the layout is pretty:
-- |
-- | ```
-- | (
-- |   SELECT …
-- | )
-- | ```
parenthesise :: Layout -> String -> String
parenthesise Inline sql = "(" <> sql <> ")"
parenthesise layout sql =
  "(" <> clauseSep (nest layout) <> sql <> clauseSep layout <> ")"

-- ---------------------------------------------------------------------------
-- Public entry points
-- ---------------------------------------------------------------------------

format :: Query -> FormattedQuery
format q = { sql, params: state.params }
  where
  Tuple sql state = formatQuery Inline q emptyBindings

-- | Inline all literals directly into the SQL string, single line.
-- | Intended for debugging and logging only — never pass user input through this.
formatInline :: Query -> String
formatInline = inlineWith Inline

-- | Like formatInline but with each clause on its own line, and nested
-- | subqueries indented one level per level of nesting.
-- | Intended for debugging and logging only — never pass user input through this.
formatPretty :: Query -> String
formatPretty = inlineWith (Pretty 0)

inlineWith :: Layout -> Query -> String
inlineWith layout q = foldl substitute sql subs
  where
  Tuple sql state = formatQuery layout q emptyBindings

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

formatQuery :: Layout -> Query -> WithBindings String
formatQuery layout q state0 = Tuple sql s7
  where
  Tuple selectSql  s1 = formatSelect  layout q.select  state0
  Tuple fromSql    s2 = formatFrom    layout q.from    s1
  Tuple joinsSql   s3 = formatJoins   layout q.joins   s2
  Tuple whereSql   s4 = formatWhere   layout q.where_  s3
  Tuple groupBySql s5 = formatGroupBy layout q.groupBy s4
  Tuple havingSql  s6 = formatHaving  layout q.having  s5
  Tuple orderBySql s7 = formatOrderBy layout q.orderBy s6

  limitSql  = formatLimit  q.limit
  offsetSql = formatOffset q.offset

  parts = Array.filter (_ /= mempty)
    [ selectSql, fromSql, joinsSql, whereSql
    , groupBySql, havingSql, orderBySql, limitSql, offsetSql ]

  sql = intercalate (clauseSep layout) parts

-- ---------------------------------------------------------------------------
-- Clause formatters
-- ---------------------------------------------------------------------------

formatSelect :: Layout -> Array SelectExpr -> WithBindings String
formatSelect layout exprs state = Tuple ("SELECT " <> intercalate ", " parts) s'
  where
  Tuple parts s' = mapAccum (formatSelectExpr layout) state exprs

formatSelectExpr :: Layout -> SelectExpr -> WithBindings String
formatSelectExpr _ SelectStar state =
  Tuple "*" state
formatSelectExpr _ (SelectStarFrom t) state =
  Tuple (quoteIdent t <> ".*") state
formatSelectExpr layout (SelectExpr e) state =
  formatExpr layout e state
formatSelectExpr layout (SelectAs e alias) state = Tuple (exprSql <> " AS " <> quoteIdent alias) s'
  where
  Tuple exprSql s' = formatExpr layout e state

formatFrom :: Layout -> Maybe Relation -> WithBindings String
formatFrom _ Nothing        state = Tuple mempty state
formatFrom layout (Just r)  state = Tuple ("FROM " <> sql) s'
  where
  Tuple sql s' = formatRelation layout r state

-- | Threads bindings because a derived table carries parameters of its own,
-- | which must be numbered where they appear in the emitted SQL.
formatRelation :: Layout -> Relation -> WithBindings String
formatRelation _ (Table name alias) state =
  Tuple (quoteIdent name <> maybe mempty (\a -> " AS " <> quoteIdent a) alias) state
formatRelation layout (Derived q alias) state =
  Tuple (parenthesise layout sql <> " AS " <> quoteIdent alias) s'
  where
  Tuple sql s' = formatQuery (nest layout) q state

formatJoins :: Layout -> Array Join -> WithBindings String
formatJoins _ [] state = Tuple mempty state
formatJoins layout joins state = Tuple (intercalate (clauseSep layout) parts) s'
  where
  Tuple parts s' = mapAccum (formatJoin layout) state joins

formatJoin :: Layout -> Join -> WithBindings String
formatJoin layout j state = Tuple (kw <> " " <> relSql <> " ON (" <> onSql <> ")") s2
  where
  kw = case j.type_ of
    InnerJoin -> "JOIN"
    LeftJoin  -> "LEFT JOIN"
    RightJoin -> "RIGHT JOIN"
    FullJoin  -> "FULL JOIN"

  -- Relation before condition: a derived join target's parameters appear
  -- earlier in the SQL than the ON clause's.
  Tuple relSql s1 = formatRelation layout j.relation state
  Tuple onSql  s2 = formatExpr layout j.on s1

formatWhere :: Layout -> Maybe Expr -> WithBindings String
formatWhere _ Nothing       state = Tuple mempty state
formatWhere layout (Just e) state = Tuple ("WHERE " <> sql) s'
  where
  Tuple sql s' = formatExpr layout e state

formatGroupBy :: Layout -> Array Expr -> WithBindings String
formatGroupBy _ [] state = Tuple mempty state
formatGroupBy layout exprs state = Tuple ("GROUP BY " <> intercalate ", " parts) s'
  where
  Tuple parts s' = mapAccum (formatExpr layout) state exprs

formatHaving :: Layout -> Maybe Expr -> WithBindings String
formatHaving _ Nothing       state = Tuple mempty state
formatHaving layout (Just e) state = Tuple ("HAVING " <> sql) s'
  where
  Tuple sql s' = formatExpr layout e state

formatOrderBy :: Layout -> Array OrderExpr -> WithBindings String
formatOrderBy _ [] state = Tuple mempty state
formatOrderBy layout exprs state = Tuple ("ORDER BY " <> intercalate ", " parts) s'
  where
  Tuple parts s' = mapAccum (formatOrderExpr layout) state exprs

formatOrderExpr :: Layout -> OrderExpr -> WithBindings String
formatOrderExpr layout { expr, dir } state = Tuple (sql <> " " <> dirSql) s'
  where
  Tuple sql s' = formatExpr layout expr state

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

formatExpr :: Layout -> Expr -> WithBindings String
formatExpr _ (Col { table: Nothing, column }) state =
  Tuple (quoteIdent column) state
formatExpr _ (Col { table: Just t, column }) state =
  Tuple (quoteIdent t <> "." <> quoteIdent column) state
formatExpr _ (Lit literal) state =
  Tuple ("$" <> show idx) { params: state.params <> [ literal ], counter: idx }
  where
  idx = state.counter + 1
formatExpr layout (App name args) state = Tuple (name <> "(" <> intercalate ", " parts <> ")") s'
  where
  Tuple parts s' = mapAccum (formatExpr layout) state args
formatExpr layout (BinOp op l r) state = Tuple (lSql <> " " <> op <> " " <> rSql) s2
  where
  prec = opPrec op
  Tuple lSql s1 = formatChild layout prec l state
  -- Left-associative: an equal-precedence right operand needs bracketing.
  Tuple rSql s2 = formatChild layout (prec + 1) r s1
formatExpr layout (Unary op e) state = Tuple (op <> " " <> sql) s'
  where
  Tuple sql s' = formatChild layout (unaryPrec op) e state
formatExpr layout (Postfix op e) state = Tuple (sql <> " " <> op) s'
  where
  Tuple sql s' = formatChild layout 4 e state
formatExpr layout (Cast e ty) state = Tuple (sql <> "::" <> ty) s'
  where
  Tuple sql s' = formatChild layout 12 e state
formatExpr layout (Row exprs) state = Tuple ("(" <> intercalate ", " parts <> ")") s'
  where
  Tuple parts s' = mapAccum (formatExpr layout) state exprs
formatExpr layout (Sub q) state = Tuple (parenthesise layout sql) s'
  where
  -- A nested SELECT is laid out like the query containing it, one level deeper:
  -- inline stays inline, pretty gets its own indented block.
  Tuple sql s' = formatQuery (nest layout) q state
formatExpr _ (And [])           state = Tuple "TRUE"  state
formatExpr layout (And exprs)   state = Tuple ("(" <> intercalate " AND " parts <> ")") s'
  where
  Tuple parts s' = mapAccum (formatExpr layout) state exprs
formatExpr _ (Or [])            state = Tuple "FALSE" state
formatExpr layout (Or exprs)    state = Tuple ("(" <> intercalate " OR " parts <> ")") s'
  where
  Tuple parts s' = mapAccum (formatExpr layout) state exprs
formatExpr layout (Between e lo hi) state =
  Tuple (eSql <> " BETWEEN " <> loSql <> " AND " <> hiSql) s3
  where
  Tuple eSql  s1 = formatChild layout 7 e  state
  Tuple loSql s2 = formatChild layout 7 lo s1
  Tuple hiSql s3 = formatChild layout 7 hi s2
formatExpr _ (Raw sql) state = Tuple sql state

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Formats a sub-expression, parenthesising it only if it binds more loosely
-- | than its position allows.
formatChild :: Layout -> Int -> Expr -> WithBindings String
formatChild layout minPrec e state =
  Tuple (if precOf e < minPrec then "(" <> sql <> ")" else sql) s'
  where
  Tuple sql s' = formatExpr layout e state

mapAccum :: ∀ a. (a -> WithBindings String) -> Bindings -> Array a -> Tuple (Array String) Bindings
mapAccum f s0 xs = foldl step (Tuple [] s0) xs
  where
  step (Tuple acc st) x = Tuple (acc <> [ r ]) st'
    where
    Tuple r st' = f x st

quoteIdent :: String -> String
quoteIdent ident =
  "\"" <> String.replaceAll (String.Pattern "\"") (String.Replacement "\"\"") ident <> "\""
