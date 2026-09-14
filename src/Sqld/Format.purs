module Sqld.Format where

import Prelude
import Data.Array (elem, filter, null) as Array
import Data.Foldable (any, foldl, intercalate)
import Data.Maybe (Maybe(..), maybe)
import Data.Monoid (power)
import Data.String as String
import Data.Tuple (Tuple(..), fst)
import Sqld.Core (Cte(..), Delete, Distinct(..), Expr(..), FormattedQuery, Frame, GroupingElement(..), Insert, InsertSource(..), Join, JoinCondition(..), Literal(..), Locking, OnConflict(..), OrderExpr, Query, Relation(..), SelectExpr(..), SetOperation(..), Update, Window, keyword)

-- ---------------------------------------------------------------------------
-- State threading — pure, no Effect
-- ---------------------------------------------------------------------------

-- | How a literal reaches the SQL string.
-- |
-- | `Bound` is the one a driver ever sees: the literal becomes a numbered
-- | placeholder and travels out of band, so no value can be read as SQL.
-- | `Inlined` writes the value into the string itself, which is what the
-- | debugging formatters print — and why their output must never be handed to
-- | a driver. See the security section of the README.
data ValueMode = Bound | Inlined

type Bindings =
  { params  :: Array Literal
  , counter :: Int
  , values  :: ValueMode
  }

emptyBindings :: Bindings
emptyBindings = { params: [], counter: 0, values: Bound }

-- | The starting state for the debugging formatters. Literals are still
-- | counted, so a caller inspecting the final state sees the same bindings the
-- | parameterised form would have produced; they are simply printed in place
-- | rather than referred to.
inlineBindings :: Bindings
inlineBindings = emptyBindings { values = Inlined }

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

-- | The formatter to hand a driver: every literal becomes a numbered
-- | placeholder and travels beside the SQL rather than inside it, so no value
-- | can be read as SQL. Identifiers are quoted by `quoteIdent`. Operator,
-- | function and type names, and anything given to `Sqld.Expr.raw`, are
-- | emitted as written — see the security section of the README for the whole
-- | boundary in one place.
format :: Query -> FormattedQuery
format q = { sql, params: state.params }
  where
  Tuple sql state = formatQuery Inline q emptyBindings

-- | Inline all literals directly into the SQL string, single line.
-- |
-- | **Debugging and logging only.** The output is a string with the values
-- | written into it: handing it to a driver gives up the one guarantee
-- | `format` provides, so a single quote in a value is all that stands between
-- | the query and an injection. There is no version of this that is safe to
-- | execute — use `format`.
formatInline :: Query -> String
formatInline = inlineWith Inline

-- | Like `formatInline` but with each clause on its own line, and nested
-- | subqueries indented one level per level of nesting. **Debugging and
-- | logging only**, for the reason `formatInline` gives.
formatPretty :: Query -> String
formatPretty = inlineWith (Pretty 0)

-- | Formats with the literals written in place rather than bound.
-- |
-- | The value is printed where the placeholder would have gone, in the one pass
-- | that builds the string. Substituting `$1` … `$n` afterwards would be the
-- | obvious alternative and is wrong: each pass re-reads what the pass before
-- | it wrote, so a string value — or a `raw` fragment — whose own text contains
-- | `$1` would be rewritten again as though it were a placeholder.
inlineWith :: Layout -> Query -> String
inlineWith layout q = fst (formatQuery layout q inlineBindings)

-- | A literal as SQL text, for the debugging formatters.
-- |
-- | A string is single-quoted with any `'` it contains doubled, which is the
-- | whole of PostgreSQL's escaping under `standard_conforming_strings` — on by
-- | default since 9.1, and the setting under which a backslash in a plain
-- | `'…'` string is an ordinary character rather than an escape. No `E''`
-- | string is ever emitted, so nothing here depends on backslash processing.
-- | A server with `standard_conforming_strings = off` reads backslashes back,
-- | and this output is not correct for it — one more reason the inline forms
-- | are for reading, not for executing.
inlineLiteral :: Literal -> String
inlineLiteral (LitInt n)     = bracketNegative (show n)
inlineLiteral (LitNumber n)  = bracketNegative (show n)
inlineLiteral (LitString s)  = "'" <> String.replaceAll (String.Pattern "'") (String.Replacement "''") s <> "'"
inlineLiteral (LitBoolean b) = if b then "TRUE" else "FALSE"
inlineLiteral LitNull        = "NULL"

-- | Brackets a negative number.
-- |
-- | A placeholder is an atom, so the printer never brackets it; the value it
-- | stands for is not. `::` binds tighter than a leading minus, so substituting
-- | `-1` into `$1::text` gives `-1::text`, which PostgreSQL reads as
-- | `-(1::text)` — a different expression, and one it cannot type. Every
-- | postfix operator has the same reach, so the brackets go on the literal
-- | rather than on the one operator that exposed it.
-- |
-- | Only the inline forms need this. `format` binds the literal, and `$1` is an
-- | atom whatever it is bound to.
bracketNegative :: String -> String
bracketNegative s = if String.take 1 s == "-" then "(" <> s <> ")" else s

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
precOf (Between _ _ _) = matchingPrec
precOf _               = atomPrec

opPrec :: String -> Int
opPrec op
  | Array.elem op [ "=", "<>", "<", ">", "<=", ">=" ] = comparisonPrec
  | Array.elem op [ "IN", "NOT IN", "LIKE", "ILIKE", "NOT LIKE", "NOT ILIKE", "SIMILAR TO" ] = matchingPrec
  | Array.elem op [ "+", "-" ] = 8
  | Array.elem op [ "*", "/", "%" ] = 9
  | op == "^" = 10
  -- PostgreSQL groups every other operator at a single level between the
  -- pattern operators and arithmetic, which is where user-supplied operators
  -- such as `@>` and `->>` land.
  | otherwise = 7

-- | The precedence a left operand is formatted at.
-- |
-- | For a left-associative operator that is its own precedence: `a - b - c`
-- | needs no brackets on the left. PostgreSQL declares two of its levels
-- | non-associative, though — comparison, and the range/membership/matching
-- | group — and there an equal-precedence operand is a syntax error rather than
-- | an expression that groups one way or the other. `1 < 2 = TRUE` and
-- | `"age" BETWEEN 1 AND 5 IN (TRUE)` are both rejected by the parser, so the
-- | left operand is bracketed on those levels exactly as the right one is.
leftPrec :: Int -> Int
leftPrec prec = if nonAssoc prec then prec + 1 else prec

nonAssoc :: Int -> Boolean
nonAssoc prec = prec == comparisonPrec || prec == matchingPrec

comparisonPrec :: Int
comparisonPrec = 5

matchingPrec :: Int
matchingPrec = 6

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
formatExpr _ (Lit literal) state = Tuple rendered bound
  where
  idx = state.counter + 1
  bound = state { params = state.params <> [ literal ], counter = idx }
  rendered = case state.values of
    Bound   -> "$" <> show idx
    Inlined -> inlineLiteral literal
formatExpr layout (App name args) state = Tuple (name <> "(" <> intercalate ", " parts <> ")") s'
  where
  Tuple parts s' = mapAccum (formatExpr layout) state args
formatExpr layout (BinOp op l r) state = Tuple (lSql <> " " <> op <> " " <> rSql) s2
  where
  prec = opPrec op
  Tuple lSql s1 = formatChild layout (leftPrec prec) l state
  -- An equal-precedence right operand always needs bracketing; whether the left
  -- one does depends on the level, which is what `leftPrec` answers.
  Tuple rSql s2 = formatChild layout (prec + 1) r s1
formatExpr layout (Quantified qop op l r) state =
  Tuple (lSql <> " " <> op <> " " <> keyword qop <> " " <> rSql) s2
  where
  prec = opPrec op
  Tuple lSql s1 = formatChild layout (leftPrec prec) l state
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
  -- One level tighter than BETWEEN's own, so an operand from its level — a
  -- comparison, an `IN`, another `BETWEEN` — is bracketed.
  Tuple eSql  s1 = formatChild layout (matchingPrec + 1) e  state
  Tuple loSql s2 = formatChild layout (matchingPrec + 1) lo s1
  Tuple hiSql s3 = formatChild layout (matchingPrec + 1) hi s2
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
formatExpr _ Default state = Tuple "DEFAULT" state

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

-- | Quotes an identifier, doubling any `"` it contains.
-- |
-- | This is what lets a table, column, alias or CTE name carry untrusted data.
-- | PostgreSQL ends a quoted identifier at the first undoubled `"`, so a name
-- | such as `x" FROM "secrets" --` would close the quoting and continue as SQL
-- | of its own; doubled, it is one identifier that happens to be spelled
-- | `x" FROM "secrets" --`, and PostgreSQL rejects it as an unknown column
-- | rather than running it.
-- |
-- | Three things it does not do, none of them an injection:
-- |
-- |   * A NUL byte passes through. The wire protocol cannot carry one, so the
-- |     statement is rejected or truncated by the driver — and the NUL is
-- |     always inside the quotes, so a truncation leaves an unterminated
-- |     identifier and a syntax error rather than a shorter query that runs.
-- |   * The empty string becomes `""`, which PostgreSQL rejects as a
-- |     zero-length delimited identifier.
-- |   * A name longer than `NAMEDATALEN - 1` (63 bytes by default) is
-- |     truncated by the server, so two long names can collide into one.
quoteIdent :: String -> String
quoteIdent ident =
  "\"" <> String.replaceAll (String.Pattern "\"") (String.Replacement "\"\"") ident <> "\""

-- ---------------------------------------------------------------------------
-- INSERT
-- ---------------------------------------------------------------------------

formatInsert :: Insert -> FormattedQuery
formatInsert i = { sql, params: state.params }
  where
  Tuple sql state = formatInsertSql Inline i emptyBindings

-- | **Debugging and logging only**, for the reason `formatInline` gives.
formatInsertInline :: Insert -> String
formatInsertInline = inlineInsertWith Inline

-- | **Debugging and logging only**, for the reason `formatInline` gives.
formatInsertPretty :: Insert -> String
formatInsertPretty = inlineInsertWith (Pretty 0)

-- | As `inlineWith`, for an `Insert`.
inlineInsertWith :: Layout -> Insert -> String
inlineInsertWith layout i = fst (formatInsertSql layout i inlineBindings)

formatInsertSql :: Layout -> Insert -> WithBindings String
formatInsertSql layout i state0 = Tuple sql s3
  where
  intro = "INSERT INTO " <> quoteIdent i.table
    <> " (" <> intercalate ", " (map quoteIdent i.columns) <> ")"

  Tuple sourceSql   s1 = formatInsertSource layout i.source   state0
  Tuple conflictSql s2 = formatOnConflict   layout i.onConflict s1
  Tuple returningSql s3 = formatReturning   layout i.returning  s2

  parts = Array.filter (_ /= mempty)
    [ intro, sourceSql, conflictSql, returningSql ]

  sql = intercalate (clauseSep layout) parts

formatInsertSource :: Layout -> InsertSource -> WithBindings String
formatInsertSource layout (InsertValues rows) state =
  Tuple ("VALUES " <> intercalate ", " parts) s'
  where
  Tuple parts s' = mapAccum (formatValuesRow layout) state rows
formatInsertSource layout (InsertQuery q) state = formatQuery layout q state

formatValuesRow :: Layout -> Array Expr -> WithBindings String
formatValuesRow layout exprs state = Tuple ("(" <> intercalate ", " parts <> ")") s'
  where
  Tuple parts s' = mapAccum (formatExpr layout) state exprs

formatOnConflict :: Layout -> Maybe OnConflict -> WithBindings String
formatOnConflict _ Nothing state = Tuple mempty state
formatOnConflict _ (Just DoNothing) state =
  Tuple "ON CONFLICT DO NOTHING" state
formatOnConflict layout (Just (DoUpdate targets assignments)) state =
  Tuple ("ON CONFLICT (" <> targetSql <> ") DO UPDATE SET " <> assignmentSql) s'
  where
  targetSql = intercalate ", " (map quoteIdent targets)
  Tuple assignmentSql s' = formatAssignments layout assignments state

formatAssignments :: Layout -> Array (Tuple String Expr) -> WithBindings String
formatAssignments layout assignments state = Tuple (intercalate ", " parts) s'
  where
  Tuple parts s' = mapAccum (formatAssignment layout) state assignments

formatAssignment :: Layout -> Tuple String Expr -> WithBindings String
formatAssignment layout (Tuple col expr) state = Tuple (quoteIdent col <> " = " <> exprSql) s'
  where
  Tuple exprSql s' = formatExpr layout expr state

formatReturning :: Layout -> Array SelectExpr -> WithBindings String
formatReturning _ [] state = Tuple mempty state
formatReturning layout exprs state = Tuple ("RETURNING " <> intercalate ", " parts) s'
  where
  Tuple parts s' = mapAccum (formatSelectExpr layout) state exprs

-- ---------------------------------------------------------------------------
-- UPDATE
-- ---------------------------------------------------------------------------

formatUpdateStmt :: Update -> FormattedQuery
formatUpdateStmt u = { sql, params: state.params }
  where
  Tuple sql state = formatUpdateSql Inline u emptyBindings

-- | **Debugging and logging only**, for the reason `formatInline` gives.
formatUpdateInline :: Update -> String
formatUpdateInline = inlineUpdateWith Inline

-- | **Debugging and logging only**, for the reason `formatInline` gives.
formatUpdatePretty :: Update -> String
formatUpdatePretty = inlineUpdateWith (Pretty 0)

-- | As `inlineWith`, for an `Update`.
inlineUpdateWith :: Layout -> Update -> String
inlineUpdateWith layout u = fst (formatUpdateSql layout u inlineBindings)

formatUpdateSql :: Layout -> Update -> WithBindings String
formatUpdateSql layout u state0 = Tuple sql s4
  where
  intro = "UPDATE " <> quoteIdent u.table

  Tuple setSql       s1 = formatSetClause  layout u.set       state0
  Tuple fromSql      s2 = formatUpdateFrom layout u.from      s1
  Tuple whereSql     s3 = formatWhere      layout u.where_    s2
  Tuple returningSql s4 = formatReturning  layout u.returning  s3

  parts = Array.filter (_ /= mempty)
    [ intro, setSql, fromSql, whereSql, returningSql ]

  sql = intercalate (clauseSep layout) parts

formatSetClause :: Layout -> Array (Tuple String Expr) -> WithBindings String
formatSetClause _ [] state = Tuple mempty state
formatSetClause layout assignments state = Tuple ("SET " <> assignmentSql) s'
  where
  Tuple assignmentSql s' = formatAssignments layout assignments state

formatUpdateFrom :: Layout -> Maybe String -> WithBindings String
formatUpdateFrom _ Nothing      state = Tuple mempty state
formatUpdateFrom _ (Just table) state = Tuple ("FROM " <> quoteIdent table) state

-- ---------------------------------------------------------------------------
-- DELETE
-- ---------------------------------------------------------------------------

formatDeleteStmt :: Delete -> FormattedQuery
formatDeleteStmt d = { sql, params: state.params }
  where
  Tuple sql state = formatDeleteSql Inline d emptyBindings

-- | **Debugging and logging only**, for the reason `formatInline` gives.
formatDeleteInline :: Delete -> String
formatDeleteInline = inlineDeleteWith Inline

-- | **Debugging and logging only**, for the reason `formatInline` gives.
formatDeletePretty :: Delete -> String
formatDeletePretty = inlineDeleteWith (Pretty 0)

-- | As `inlineWith`, for a `Delete`.
inlineDeleteWith :: Layout -> Delete -> String
inlineDeleteWith layout d = fst (formatDeleteSql layout d inlineBindings)

formatDeleteSql :: Layout -> Delete -> WithBindings String
formatDeleteSql layout d state0 = Tuple sql s3
  where
  intro = "DELETE FROM " <> quoteIdent d.table

  Tuple usingSql     s1 = formatDeleteUsing layout d.using     state0
  Tuple whereSql     s2 = formatWhere       layout d.where_    s1
  Tuple returningSql s3 = formatReturning   layout d.returning s2

  parts = Array.filter (_ /= mempty)
    [ intro, usingSql, whereSql, returningSql ]

  sql = intercalate (clauseSep layout) parts

formatDeleteUsing :: Layout -> Array String -> WithBindings String
formatDeleteUsing _ [] state = Tuple mempty state
formatDeleteUsing _ tables state =
  Tuple ("USING " <> intercalate ", " (map quoteIdent tables)) state
