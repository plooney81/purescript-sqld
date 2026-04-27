module Sqld.Core where

import Prelude
import Data.Maybe (Maybe(..))

type ColumnRef = { table :: Maybe String, column :: String }

type Relation = { name :: String, alias :: Maybe String }

data Expr
  = Col ColumnRef
  | Lit Literal
  | Eq Expr Expr
  | Neq Expr Expr
  | Lt Expr Expr
  | Lte Expr Expr
  | Gt Expr Expr
  | Gte Expr Expr
  | And (Array Expr)
  | Or (Array Expr)
  | Not Expr
  | IsNull Expr
  | IsNotNull Expr
  | In Expr (Array Expr)
  | NotIn Expr (Array Expr)
  | Like Expr Expr
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
