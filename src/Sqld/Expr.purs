-- | Named, discoverable helpers over the generic `Sqld.Core` AST nodes.
-- |
-- | `Sqld.Core` keeps the AST small — `App`, `BinOp`, `Cast` and `Sub` cover
-- | most of PostgreSQL's expression grammar between them. This module is the
-- | typed surface over that: `.==` builds a `BinOp "="`, `count` builds an
-- | `App "COUNT"`, and anything without a helper is still reachable through
-- | `binOp`, `app`, `unary` and `postfix` without falling back to `raw`.
module Sqld.Expr where

import Prelude (($), (+), (<<<))
import Data.Maybe (Maybe(..))
import Data.String as String
import Sqld.Core (Expr(..), Frame, FrameBound(..), FrameMode(..), Literal(..), OrderExpr, Query, Window, emptyWindow)

-- ---------------------------------------------------------------------------
-- Column references
-- ---------------------------------------------------------------------------

colRef :: Maybe String -> String -> Expr
colRef t c = Col { table: t, column: c }

-- | A column reference. A dot qualifies the column with a table name or alias,
-- | so `col "u.id"` is `tcol "u" "id"` and renders `"u"."id"` — which is what
-- | makes `cols [ "u.id", "u.name" ]` read like the SQL it produces.
-- |
-- | Splitting happens at the first dot. An identifier that genuinely contains
-- | one must go through `tcol` or `colRef`, which never split.
col :: String -> Expr
col name = case String.indexOf (String.Pattern ".") name of
  Nothing -> colRef Nothing name
  Just i  -> tcol (String.take i name) (String.drop (i + 1) name)

tcol :: String -> String -> Expr
tcol t = colRef $ Just t

-- ---------------------------------------------------------------------------
-- Literals
-- ---------------------------------------------------------------------------

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

-- | Escape hatch for SQL this module cannot express. Emitted verbatim, so the
-- | caller owns both its correctness and its parenthesisation.
raw :: String -> Expr
raw = Raw

-- ---------------------------------------------------------------------------
-- Generic constructors
-- ---------------------------------------------------------------------------

-- | Any function: `app "COUNT" [col "id"]` renders `COUNT("id")`.
app :: String -> Array Expr -> Expr
app = App

-- | Any infix operator: `binOp "@>" a b` renders `a @> b`. Precedence is
-- | resolved by `Sqld.Format`; unknown operators are treated as PostgreSQL
-- | treats them, at the generic "other operator" level.
binOp :: String -> Expr -> Expr -> Expr
binOp = BinOp

-- | Any prefix operator: `unary "-" e` renders `- e`.
unary :: String -> Expr -> Expr
unary = Unary

-- | Any postfix operator: `postfix "IS TRUE" e` renders `e IS TRUE`.
postfix :: String -> Expr -> Expr
postfix = Postfix

-- | `cast (col "id") "text"` renders `"id"::text`.
cast :: Expr -> String -> Expr
cast = Cast

-- | Parenthesised list: `row [int 1, int 2]` renders `(1, 2)`.
row :: Array Expr -> Expr
row = Row

-- | A subquery in expression position: `(SELECT …)`.
sub :: Query -> Expr
sub = Sub

-- ---------------------------------------------------------------------------
-- Comparison
-- ---------------------------------------------------------------------------

eq :: Expr -> Expr -> Expr
eq = BinOp "="

neq :: Expr -> Expr -> Expr
neq = BinOp "<>"

lt :: Expr -> Expr -> Expr
lt = BinOp "<"

lte :: Expr -> Expr -> Expr
lte = BinOp "<="

gt :: Expr -> Expr -> Expr
gt = BinOp ">"

gte :: Expr -> Expr -> Expr
gte = BinOp ">="

infix 4 eq  as .==
infix 4 neq as .!=
infix 4 lt  as .<
infix 4 lte as .<=
infix 4 gt  as .>
infix 4 gte as .>=

-- ---------------------------------------------------------------------------
-- Logical
-- ---------------------------------------------------------------------------

and :: Array Expr -> Expr
and = And

or :: Array Expr -> Expr
or = Or

not :: Expr -> Expr
not = Unary "NOT"

isNull :: Expr -> Expr
isNull = Postfix "IS NULL"

isNotNull :: Expr -> Expr
isNotNull = Postfix "IS NOT NULL"

-- ---------------------------------------------------------------------------
-- Set membership
-- ---------------------------------------------------------------------------

-- | `e IN (a, b, …)`.
-- |
-- | An empty candidate list folds to `FALSE`: nothing is a member of the empty
-- | set, and `IN ()` is a syntax error PostgreSQL rejects. `Or []` is that
-- | constant — it already renders as the bare keyword `FALSE`, which is an atom
-- | the precedence printer never needs to bracket.
in_ :: Expr -> Array Expr -> Expr
in_ _ [] = Or []
in_ e xs = BinOp "IN" e (Row xs)

-- | `e NOT IN (a, b, …)`. The mirror of `in_`: an empty candidate list folds to
-- | `TRUE`, since everything is a non-member of the empty set.
notIn :: Expr -> Array Expr -> Expr
notIn _ [] = And []
notIn e xs = BinOp "NOT IN" e (Row xs)

-- | `e IN (SELECT …)`.
inSub :: Expr -> Query -> Expr
inSub e = BinOp "IN" e <<< Sub

-- | `e NOT IN (SELECT …)`.
notInSub :: Expr -> Query -> Expr
notInSub e = BinOp "NOT IN" e <<< Sub

exists :: Query -> Expr
exists = Unary "EXISTS" <<< Sub

notExists :: Query -> Expr
notExists = Unary "NOT EXISTS" <<< Sub

-- ---------------------------------------------------------------------------
-- Pattern matching
-- ---------------------------------------------------------------------------

like :: Expr -> String -> Expr
like e = BinOp "LIKE" e <<< str

ilike :: Expr -> String -> Expr
ilike e = BinOp "ILIKE" e <<< str

notLike :: Expr -> String -> Expr
notLike e = BinOp "NOT LIKE" e <<< str

notILike :: Expr -> String -> Expr
notILike e = BinOp "NOT ILIKE" e <<< str

-- ---------------------------------------------------------------------------
-- Ranges
-- ---------------------------------------------------------------------------

between :: Expr -> Expr -> Expr -> Expr
between = Between

-- ---------------------------------------------------------------------------
-- Common functions
-- ---------------------------------------------------------------------------
--
-- A thin convenience layer — every one is a one-line `App`, and any function
-- PostgreSQL knows is reachable with `app` whether or not it is listed here.

count :: Expr -> Expr
count e = App "COUNT" [ e ]

countStar :: Expr
countStar = App "COUNT" [ Raw "*" ]

sum_ :: Expr -> Expr
sum_ e = App "SUM" [ e ]

avg :: Expr -> Expr
avg e = App "AVG" [ e ]

min_ :: Expr -> Expr
min_ e = App "MIN" [ e ]

max_ :: Expr -> Expr
max_ e = App "MAX" [ e ]

coalesce :: Array Expr -> Expr
coalesce = App "COALESCE"

lower :: Expr -> Expr
lower e = App "LOWER" [ e ]

upper :: Expr -> Expr
upper e = App "UPPER" [ e ]

-- ---------------------------------------------------------------------------
-- Window functions
-- ---------------------------------------------------------------------------

-- | Evaluates an aggregate or window function over a window rather than over
-- | the whole group:
-- |
-- |     rowNumber `over`
-- |       ( partitionBy' [ col "department" ]
-- |           # orderWindow [ desc (col "age") ]
-- |       )
-- |     -- ROW_NUMBER() OVER (PARTITION BY "department" ORDER BY "age" DESC)
-- |
-- | The window builders below start from `partitionBy'` or `orderWindow'` and
-- | pipe on with `#`, the way a query is built. Every field is optional, and
-- | `` e `over` emptyWindow `` is `OVER ()`.
-- |
-- | PostgreSQL allows a window function in `SELECT` and `ORDER BY` only, and
-- | rejects one in `WHERE`, `GROUP BY` or `HAVING`. That is not expressed in the
-- | type — an `Over` is an ordinary `Expr` — so it is the database that reports
-- | the mistake.
over :: Expr -> Window -> Expr
over = Over

-- ---------------------------------------------------------------------------
-- Window builders
-- ---------------------------------------------------------------------------
--
-- Plain `Window -> Window` functions that pipe together with `#`, exactly as
-- the `Sqld.Select` builders do, starting from `partitionBy'`, `orderWindow'`
-- or `emptyWindow`. Each replaces its field rather than appending to it.

partitionBy :: Array Expr -> Window -> Window
partitionBy exprs w = w { partitionBy = exprs }

-- | Starts a window from its partition, so the common case need not name
-- | `emptyWindow` — the same shorthand `select'` is for `emptyQuery`:
-- |
-- |     partitionBy' [ col "user_id" ] # orderWindow [ asc (col "placed_at") ]
partitionBy' :: Array Expr -> Window
partitionBy' exprs = partitionBy exprs emptyWindow

-- | A window's `ORDER BY`, which decides both the order rows are numbered in
-- | and, for a `RANGE` or `GROUPS` frame, which rows count as peers.
-- |
-- | Named `orderWindow` rather than `orderBy` because `Sqld.Select` already
-- | uses that name for a query's ordering, and the two would collide in any
-- | module importing both unqualified.
orderWindow :: Array OrderExpr -> Window -> Window
orderWindow orders w = w { orderBy = orders }

-- | Starts a window from its ordering, the counterpart to `partitionBy'` for a
-- | window with no partition — which is what a frame usually wants:
-- |
-- |     orderWindow' [ asc (col "placed_at") ] # withFrame (rows unboundedPreceding currentRow)
-- |
-- | There is deliberately no `withFrame'`: a frame over unordered rows frames
-- | nothing in particular, and `RANGE` and `GROUPS` mode PostgreSQL rejects
-- | outright without an `ORDER BY`.
orderWindow' :: Array OrderExpr -> Window
orderWindow' orders = orderWindow orders emptyWindow

-- | Sets the frame, taking the `Frame` rather than a `Maybe Frame`: a window
-- | either has one or is left alone.
withFrame :: Frame -> Window -> Window
withFrame f w = w { frame = Just f }

-- | `ROW_NUMBER()` — the row's position in its partition, ties broken
-- | arbitrarily.
rowNumber :: Expr
rowNumber = App "ROW_NUMBER" []

-- | `RANK()` — position with gaps after ties.
rank :: Expr
rank = App "RANK" []

-- | `DENSE_RANK()` — position without gaps after ties.
denseRank :: Expr
denseRank = App "DENSE_RANK" []

-- | `LAG(e, n)` — `e` from the row `n` places back in the partition, or `NULL`
-- | at the start of one.
lag :: Expr -> Int -> Expr
lag e n = App "LAG" [ e, int n ]

-- | `LEAD(e, n)` — the mirror of `lag`, looking forward.
lead :: Expr -> Int -> Expr
lead e n = App "LEAD" [ e, int n ]

-- ---------------------------------------------------------------------------
-- Window frames
-- ---------------------------------------------------------------------------

-- | `ROWS BETWEEN start AND end` — a frame counted in physical rows.
rows :: FrameBound -> FrameBound -> Frame
rows = frameBetween Rows

-- | `RANGE BETWEEN start AND end` — a frame counted in `ORDER BY` values, so
-- | peers share a frame. An offset bound needs exactly one `ORDER BY` column.
range :: FrameBound -> FrameBound -> Frame
range = frameBetween Range

-- | `GROUPS BETWEEN start AND end` — a frame counted in peer groups.
-- | PostgreSQL requires the window to be ordered.
groups :: FrameBound -> FrameBound -> Frame
groups = frameBetween Groups

-- | The general form: any mode, both bounds.
frameBetween :: FrameMode -> FrameBound -> FrameBound -> Frame
frameBetween mode start end = { mode, start, end: Just end }

-- | SQL's one-bound form, `ROWS UNBOUNDED PRECEDING`, which runs from `start`
-- | to the current row.
frameFrom :: FrameMode -> FrameBound -> Frame
frameFrom mode start = { mode, start, end: Nothing }

unboundedPreceding :: FrameBound
unboundedPreceding = UnboundedPreceding

preceding :: Int -> FrameBound
preceding = Preceding

currentRow :: FrameBound
currentRow = CurrentRow

following :: Int -> FrameBound
following = Following

unboundedFollowing :: FrameBound
unboundedFollowing = UnboundedFollowing
