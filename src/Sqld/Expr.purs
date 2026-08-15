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
import Sqld.Core (Expr(..), Literal(..), Query)

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
