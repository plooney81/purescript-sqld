-- | Named, discoverable helpers over the generic `Sqld.Core` AST nodes.
-- |
-- | `Sqld.Core` keeps the AST small — `App`, `BinOp`, `Cast` and `Sub` cover
-- | most of PostgreSQL's expression grammar between them. This module is the
-- | typed surface over that: `.==` builds a `BinOp "="`, `count` builds an
-- | `App "COUNT"`, and anything without a helper is still reachable through
-- | `binOp`, `app`, `unary` and `postfix` without falling back to `raw`.
module Sqld.Expr where

import Prelude (($), (<<<))
import Data.Maybe (Maybe(..))
import Sqld.Core (Expr(..), Literal(..), Query)

-- ---------------------------------------------------------------------------
-- Column references
-- ---------------------------------------------------------------------------

colRef :: Maybe String -> String -> Expr
colRef t c = Col { table: t, column: c }

col :: String -> Expr
col = colRef Nothing

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

in_ :: Expr -> Array Expr -> Expr
in_ e vals = BinOp "IN" e (Row vals)

notIn :: Expr -> Array Expr -> Expr
notIn e vals = BinOp "NOT IN" e (Row vals)

-- | `e IN (SELECT …)`.
inSub :: Expr -> Query -> Expr
inSub e q = BinOp "IN" e (Sub q)

-- | `e NOT IN (SELECT …)`.
notInSub :: Expr -> Query -> Expr
notInSub e q = BinOp "NOT IN" e (Sub q)

exists :: Query -> Expr
exists q = Unary "EXISTS" (Sub q)

notExists :: Query -> Expr
notExists q = Unary "NOT EXISTS" (Sub q)

-- ---------------------------------------------------------------------------
-- Pattern matching
-- ---------------------------------------------------------------------------

like :: Expr -> String -> Expr
like e pattern = BinOp "LIKE" e (str pattern)

ilike :: Expr -> String -> Expr
ilike e pattern = BinOp "ILIKE" e (str pattern)

notLike :: Expr -> String -> Expr
notLike e pattern = BinOp "NOT LIKE" e (str pattern)

notILike :: Expr -> String -> Expr
notILike e pattern = BinOp "NOT ILIKE" e (str pattern)

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
