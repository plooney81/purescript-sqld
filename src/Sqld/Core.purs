module Sqld.Core where

import Prelude
import Data.Maybe (Maybe(..))

type ColumnRef = { table :: Maybe String, column :: String }

-- | Anything that can appear in `FROM` or as a join target.
-- |
-- | `Derived` takes its alias as a plain `String` rather than a `Maybe`:
-- | PostgreSQL rejects a subquery in `FROM` without one, so the type rules out
-- | a query that could never run.
data Relation
  = Table String (Maybe String)
  | Derived Query String

-- | The expression AST.
-- |
-- | Rather than one constructor per SQL feature, the bulk of PostgreSQL's
-- | expression grammar is covered by a handful of generic nodes:
-- |
-- |   * `App`    — any function in `pg_proc`
-- |   * `BinOp`  — any operator in `pg_operator`
-- |   * `Cast`   — `expr::type` for any type
-- |   * `Sub`    — scalar subqueries, `IN (SELECT …)`, `EXISTS (…)`
-- |
-- | `Sqld.Expr` layers named, discoverable helpers (`.==`, `like`, `count`)
-- | on top, so the builder API stays typed and readable.
data Expr
  = Col ColumnRef
  | Lit Literal
  -- | Function application: `name(arg, …)`.
  | App String (Array Expr)
  -- | Infix operator: `left op right`.
  | BinOp String Expr Expr
  -- | Prefix operator: `op operand` (`NOT`, `EXISTS`, unary `-`).
  | Unary String Expr
  -- | Postfix operator: `operand op` (`IS NULL`, `IS NOT NULL`).
  | Postfix String Expr
  -- | Type cast: `expr::type`.
  | Cast Expr String
  -- | Parenthesised list: `(a, b, c)`. Gives `IN` an ordinary right operand.
  | Row (Array Expr)
  -- | Subquery in expression position: `(SELECT …)`.
  | Sub Query
  | And (Array Expr)
  | Or (Array Expr)
  | Between Expr Expr Expr
  | Raw String

data Literal
  = LitInt Int
  | LitNumber Number
  | LitString String
  | LitBoolean Boolean
  | LitNull

derive instance Eq Literal

instance Show Literal where
  show (LitInt n)     = "(LitInt " <> show n <> ")"
  show (LitNumber n)  = "(LitNumber " <> show n <> ")"
  show (LitString s)  = "(LitString " <> show s <> ")"
  show (LitBoolean b) = "(LitBoolean " <> show b <> ")"
  show LitNull        = "LitNull"

data SelectExpr
  = SelectExpr Expr
  | SelectAs Expr String
  | SelectStar
  | SelectStarFrom String

data JoinType
  = InnerJoin
  | LeftJoin
  | RightJoin
  | FullJoin

type Join =
  { type_     :: JoinType
  , relation  :: Relation
  , on        :: Expr
  }

data OrderDir = Asc | Desc

type OrderExpr = { expr :: Expr, dir :: OrderDir }

type Query =
  { select  :: Array SelectExpr
  , from    :: Maybe Relation
  , joins   :: Array Join
  , where_  :: Maybe Expr
  , groupBy :: Array Expr
  , having  :: Maybe Expr
  , orderBy :: Array OrderExpr
  , limit   :: Maybe Int
  , offset  :: Maybe Int
  }

emptyQuery :: Query
emptyQuery =
  { select:  []
  , from:    Nothing
  , joins:   []
  , where_:  Nothing
  , groupBy: []
  , having:  Nothing
  , orderBy: []
  , limit:   Nothing
  , offset:  Nothing
  }

type FormattedQuery =
  { sql    :: String
  , params :: Array Literal
  }
