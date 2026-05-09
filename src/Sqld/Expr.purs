module Sqld.Expr where

import Data.Maybe (Maybe(..))
import Prelude (($), (<<<))
import Sqld.Core (Expr(..), Literal(..))

colRef :: Maybe String -> String -> Expr
colRef t c = Col { table: t, column: c }

col :: String -> Expr
col = colRef Nothing

tcol :: String -> String -> Expr
tcol t = colRef $ Just t

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

raw :: String -> Expr
raw = Raw

infix 4 Eq  as .==
infix 4 Neq as .!=
infix 4 Lt  as .<
infix 4 Lte as .<=
infix 4 Gt  as .>
infix 4 Gte as .>=

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
