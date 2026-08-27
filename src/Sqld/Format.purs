module Sqld.Format where

import Prelude
import Data.Array (elem, filter, mapWithIndex, null, reverse) as Array
import Data.Foldable (any, foldl, intercalate)
import Data.Maybe (Maybe(..), maybe)
import Data.Monoid (power)
import Data.String as String
import Data.Tuple (Tuple(..))
import Sqld.Core (Cte(..), Distinct(..), Expr(..), FormattedQuery, Frame, GroupingElement(..), Join, JoinCondition(..), Literal(..), Locking, OrderExpr, Query, Relation(..), SelectExpr(..), SetOperation(..), Window, keyword)

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
formatQuery layout q state0 = Tuple sql s5
  where
  Tuple withSql    s1 = formatWith    layout q.with    state0
  Tuple bodySql    s2 = formatBody    layout q         s1
  Tuple orderBySql s3 = formatOrderBy layout q.orderBy s2
  Tuple limitSql   s4 = formatLimit   layout q.limit   s3
  Tuple offsetSql  s5 = formatOffset  layout q.offset  s4
  lockingSql = formatLocking layout q.locking

  parts = Array.filter (_ /= mempty)
    [ withSql, bodySql, orderBySql, limitSql, offsetSql, lockingSql ]

  sql = intercalate (clauseSep layout) parts

-- | The rows a query produces: a single `SELECT`, or two of them combined by a
-- | set operation.
-- |
-- | `WITH`, `ORDER BY`, `LIMIT` and `OFFSET` sit outside the body, which is
-- | what makes them apply to the combined result rather than to the last
-- | operand.
formatBody :: Layout -> Query -> WithBindings String
formatBody layout q state = case q.setOp of
  Nothing -> formatSelectBody layout q state
  Just so -> formatSetOperation layout so state

formatSelectBody :: Layout -> Query -> WithBindings String
formatSelectBody layout q state0 = Tuple sql s6
  where
  Tuple selectSql  s1 = formatSelect  layout q.distinct q.select state0
  Tuple fromSql    s2 = formatFrom    layout q.from    s1
  Tuple joinsSql   s3 = formatJoins   layout q.joins   s2
  Tuple whereSql   s4 = formatWhere   layout q.where_  s3
  Tuple groupBySql s5 = formatGroupBy layout q.groupBy s4
  Tuple havingSql  s6 = formatHaving  layout q.having  s5

  parts = Array.filter (_ /= mempty)
    [ selectSql, fromSql, joinsSql, whereSql, groupBySql, havingSql ]

  sql = intercalate (clauseSep layout) parts

-- | `(left) UNION ALL (right)`.
-- |
-- | Both operands are bracketed, so the meaning does not depend on
-- | PostgreSQL's precedence between the set operators, and an operand keeps any
-- | `ORDER BY` and `LIMIT` of its own.
formatSetOperation :: Layout -> SetOperation -> WithBindings String
formatSetOperation layout (SetOperation so) state =
  Tuple (leftSql <> sep <> kw <> sep <> rightSql) s2
  where
  sep = clauseSep layout
  kw  = keyword so.op <> if so.all then " ALL" else mempty

  Tuple leftSql  s1 = formatOperand layout so.left  state
  Tuple rightSql s2 = formatOperand layout so.right s1

formatOperand :: Layout -> Query -> WithBindings String
formatOperand layout q state = Tuple (parenthesise layout sql) s'
  where
  Tuple sql s' = formatQuery (nest layout) q state

-- ---------------------------------------------------------------------------
-- Clause formatters
-- ---------------------------------------------------------------------------

-- | `RECURSIVE` belongs to the clause, not to one CTE, so a single recursive
-- | entry makes the whole `WITH` recursive.
formatWith :: Layout -> Array Cte -> WithBindings String
formatWith _ [] state = Tuple mempty state
formatWith layout ctes state = Tuple (kw <> intercalate ("," <> clauseSep layout) parts) s'
  where
  kw = if any (\(Cte c) -> c.recursive) ctes then "WITH RECURSIVE " else "WITH "

  Tuple parts s' = mapAccum (formatCte layout) state ctes

formatCte :: Layout -> Cte -> WithBindings String
formatCte layout (Cte c) state =
  Tuple (quoteIdent c.name <> columnList <> " AS " <> parenthesise layout sql) s'
  where
  columnList =
    if Array.null c.columns then mempty
    else " (" <> intercalate ", " (map quoteIdent c.columns) <> ")"

  Tuple sql s' = formatQuery (nest layout) c.query state

formatSelect :: Layout -> Maybe Distinct -> Array SelectExpr -> WithBindings String
formatSelect layout d exprs state0 = Tuple ("SELECT " <> distinctSql <> intercalate ", " parts) s2
  where
  -- The `DISTINCT ON` expressions precede the select list in the emitted SQL,
  -- so their parameters are numbered first.
  Tuple distinctSql s1 = formatDistinct layout d      state0
  Tuple parts       s2 = mapAccum (formatSelectExpr layout) s1 exprs

-- | `DISTINCT`, or `DISTINCT ON (…)`, carrying the space that separates it from
-- | the select list. Absent is SQL's `ALL`, which is the default and emits
-- | nothing.
formatDistinct :: Layout -> Maybe Distinct -> WithBindings String
formatDistinct _ Nothing               state = Tuple mempty state
formatDistinct _ (Just Distinct)       state = Tuple "DISTINCT " state
formatDistinct layout (Just (DistinctOn exprs)) state =
  Tuple ("DISTINCT ON (" <> intercalate ", " parts <> ") ") s'
  where
  Tuple parts s' = mapAccum (formatExpr layout) state exprs

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
-- `LATERAL` is a marker on the derived form and nothing more, so it is emitted
-- as one: the relation renders exactly as it would without it.
formatRelation layout (Lateral q alias) state = Tuple ("LATERAL " <> sql) s'
  where
  Tuple sql s' = formatRelation layout (Derived q alias) state

formatJoins :: Layout -> Array Join -> WithBindings String
formatJoins _ [] state = Tuple mempty state
formatJoins layout joins state = Tuple (intercalate (clauseSep layout) parts) s'
  where
  Tuple parts s' = mapAccum (formatJoin layout) state joins

formatJoin :: Layout -> Join -> WithBindings String
formatJoin layout j state = Tuple (joinKeyword j.condition <> " " <> relSql <> conditionSql) s2
  where
  -- Relation before condition: a derived join target's parameters appear
  -- earlier in the SQL than the ON clause's.
  Tuple relSql       s1 = formatRelation layout j.relation state
  Tuple conditionSql s2 = formatJoinCondition layout j.condition s1

-- | The keyword a join leads with. Not a `Keyword` instance: `NATURAL` sits in
-- | front of the join type rather than replacing it, so the string comes from
-- | two values rather than one.
joinKeyword :: JoinCondition -> String
joinKeyword (On type_ _)    = keyword type_
joinKeyword (Using type_ _) = keyword type_
joinKeyword (Natural type_) = "NATURAL " <> keyword type_
joinKeyword Cross           = "CROSS JOIN"

-- | What follows the join target: an `ON` or `USING` clause, or nothing at all
-- | — `NATURAL` and `CROSS` have said everything in the keyword.
-- |
-- | Only `ON` carries parameters. `USING` names columns, which are identifiers
-- | and so are quoted rather than bound.
formatJoinCondition :: Layout -> JoinCondition -> WithBindings String
formatJoinCondition layout (On _ e) state = Tuple (" ON (" <> sql <> ")") s'
  where
  Tuple sql s' = formatExpr layout e state
formatJoinCondition _ (Using _ columns) state =
  Tuple (" USING (" <> intercalate ", " (map quoteIdent columns) <> ")") state
formatJoinCondition _ (Natural _) state = Tuple mempty state
formatJoinCondition _ Cross       state = Tuple mempty state

formatWhere :: Layout -> Maybe Expr -> WithBindings String
formatWhere _ Nothing       state = Tuple mempty state
formatWhere layout (Just e) state = Tuple ("WHERE " <> sql) s'
  where
  Tuple sql s' = formatExpr layout e state

formatGroupBy :: Layout -> Array GroupingElement -> WithBindings String
formatGroupBy _ [] state = Tuple mempty state
formatGroupBy layout elements state = Tuple ("GROUP BY " <> intercalate ", " parts) s'
  where
  Tuple parts s' = mapAccum (formatGroupingElement layout) state elements

-- | One element of a `GROUP BY` list.
-- |
-- | `GROUPING SETS` brackets each of its sets, which is what gives the empty set
-- | somewhere to be written: `GROUPING SETS (("a"), ())`. `CUBE` and `ROLLUP`
-- | bracket a single list apiece.
formatGroupingElement :: Layout -> GroupingElement -> WithBindings String
formatGroupingElement layout (GroupingExpr e) state = formatExpr layout e state
formatGroupingElement layout (GroupingSets sets) state =
  Tuple ("GROUPING SETS (" <> intercalate ", " parts <> ")") s'
  where
  Tuple parts s' = mapAccum (formatExprList layout) state sets
formatGroupingElement layout (Cube exprs) state = Tuple ("CUBE " <> sql) s'
  where
  Tuple sql s' = formatExprList layout exprs state
formatGroupingElement layout (Rollup exprs) state = Tuple ("ROLLUP " <> sql) s'
  where
  Tuple sql s' = formatExprList layout exprs state

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
formatOrderExpr layout { expr, dir, nulls } state = Tuple (sql <> " " <> dirSql <> nullsSql) s'
  where
  Tuple sql s' = formatExpr layout expr state

  dirSql = keyword dir
  nullsSql = maybe mempty (\n -> " " <> keyword n) nulls

formatLimit :: Layout -> Maybe Expr -> WithBindings String
formatLimit _ Nothing       state = Tuple mempty state
formatLimit layout (Just e) state = Tuple ("LIMIT " <> sql) s'
  where
  Tuple sql s' = formatExpr layout e state

formatOffset :: Layout -> Maybe Expr -> WithBindings String
formatOffset _ Nothing       state = Tuple mempty state
formatOffset layout (Just e) state = Tuple ("OFFSET " <> sql) s'
  where
  Tuple sql s' = formatExpr layout e state

-- | The locking clauses, last of all — after `LIMIT` and `OFFSET`, which is
-- | where SQL puts them. Each is a clause in its own right, so a pretty layout
-- | gives each its own line.
-- |
-- | Carries no bindings: a locking clause holds nothing but keywords and the
-- | names of relations already named in `FROM`, so there is nothing here to
-- | parameterise.
formatLocking :: Layout -> Array Locking -> String
formatLocking layout ls = intercalate (clauseSep layout) (map formatLock ls)

formatLock :: Locking -> String
formatLock { strength, tables, wait } = intercalate " " (Array.filter (_ /= mempty) parts)
  where
  parts = [ keyword strength, ofSql, maybe mempty keyword wait ]

  ofSql =
    if Array.null tables then mempty
    else "OF " <> intercalate ", " (map quoteIdent tables)

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
-- responsibility. So are `Over` and `Filter`, which bind to the function call
-- itself and so tighter in PostgreSQL than any operator that could contain
-- them.

atomPrec :: Int
atomPrec = 99

precOf :: Expr -> Int
precOf (BinOp op _ _)         = opPrec op
precOf (Quantified _ op _ _)  = opPrec op
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
formatExpr layout (Quantified qop op l r) state =
  Tuple (lSql <> " " <> op <> " " <> keyword qop <> " " <> rSql) s2
  where
  prec = opPrec op
  Tuple lSql s1 = formatChild layout prec l state
  Tuple rSql s2 = formatQuantArg layout r s1
formatExpr layout (Unary op e) state = Tuple (op <> " " <> sql) s'
  where
  Tuple sql s' = formatChild layout (unaryPrec op) e state
formatExpr layout (Postfix op e) state = Tuple (sql <> " " <> op) s'
  where
  Tuple sql s' = formatChild layout 4 e state
formatExpr layout (Cast e ty) state = Tuple (sql <> "::" <> ty) s'
  where
  Tuple sql s' = formatChild layout 12 e state
formatExpr layout (Row exprs) state = formatExprList layout exprs state
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
formatExpr layout (Over e w) state = Tuple (fnSql <> " OVER " <> windowSql) s2
  where
  -- `OVER` binds tighter than any operator, so its function is formatted at
  -- atom level: anything looser brackets itself.
  Tuple fnSql     s1 = formatChild layout atomPrec e state
  Tuple windowSql s2 = formatWindow layout w s1
formatExpr layout (Filter e predicate) state =
  Tuple (aggSql <> " FILTER (WHERE " <> predicateSql <> ")") s2
  where
  -- `FILTER` binds to the aggregate call, so its operand is formatted at atom
  -- level for the same reason `OVER`'s is. The predicate is not: the brackets
  -- around it are the modifier's own, and nothing outside them can reach in.
  Tuple aggSql       s1 = formatChild layout atomPrec e state
  Tuple predicateSql s2 = formatExpr layout predicate s1
formatExpr _ (Raw sql) state = Tuple sql state

-- ---------------------------------------------------------------------------
-- Windows
-- ---------------------------------------------------------------------------

-- | The `(…)` of an `OVER` clause. Always bracketed, and always on one line —
-- | a window is part of an expression, not a clause of its own, so `Pretty` does
-- | not break it up.
-- |
-- | An empty window emits `()`, which PostgreSQL accepts.
formatWindow :: Layout -> Window -> WithBindings String
formatWindow layout w state0 = Tuple ("(" <> intercalate " " parts <> ")") s2
  where
  Tuple partitionSql s1 = formatPartitionBy layout w.partitionBy state0
  Tuple orderBySql   s2 = formatOrderBy     layout w.orderBy     s1

  parts = Array.filter (_ /= mempty)
    [ partitionSql, orderBySql, maybe mempty formatFrame w.frame ]

formatPartitionBy :: Layout -> Array Expr -> WithBindings String
formatPartitionBy _ [] state = Tuple mempty state
formatPartitionBy layout exprs state = Tuple ("PARTITION BY " <> intercalate ", " parts) s'
  where
  Tuple parts s' = mapAccum (formatExpr layout) state exprs

-- | Carries no bindings: a frame's offsets are literal integers, so there is
-- | nothing here to parameterise.
formatFrame :: Frame -> String
formatFrame { mode, start, end } = keyword mode <> " " <> boundsSql
  where
  boundsSql = case end of
    Nothing -> keyword start
    Just e  -> "BETWEEN " <> keyword start <> " AND " <> keyword e

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | The right operand of `ANY` / `ALL`: a subquery gets the same indented
-- | block that `Sub` gives it, anything else gets simple parentheses.
formatQuantArg :: Layout -> Expr -> WithBindings String
formatQuantArg layout (Sub q) state = Tuple (parenthesise layout sql) s'
  where
  Tuple sql s' = formatQuery (nest layout) q state
formatQuantArg layout e state = Tuple ("(" <> sql <> ")") s'
  where
  Tuple sql s' = formatExpr layout e state

-- | A bracketed, comma-separated list of expressions: the `(a, b)` of a row
-- | constructor, of `CUBE`, and of one grouping set. An empty list gives `()`,
-- | which is a row of no columns in the first case and the grand total in the
-- | others.
formatExprList :: Layout -> Array Expr -> WithBindings String
formatExprList layout exprs state = Tuple ("(" <> intercalate ", " parts <> ")") s'
  where
  Tuple parts s' = mapAccum (formatExpr layout) state exprs

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
