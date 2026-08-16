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
  -- | A window function and the window it is evaluated over:
  -- | `f(…) OVER (PARTITION BY … ORDER BY … <frame>)`.
  | Over Expr Window
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

-- | The window a window function is evaluated over: the `(…)` of
-- | `ROW_NUMBER() OVER (PARTITION BY "department" ORDER BY "age" DESC)`.
-- |
-- | A record synonym rather than a `newtype`, unlike `Cte` and `SetOperation`.
-- | Those close a cycle between two synonyms, which PureScript rejects; this
-- | one runs back to `Expr`, and expansion stops at a `data` declaration.
-- |
-- | Every field is optional. `emptyWindow` emits `OVER ()`, which is valid and
-- | means the whole result set is one partition, unordered and unframed.
type Window =
  { partitionBy :: Array Expr
  , orderBy     :: Array OrderExpr
  , frame       :: Maybe Frame
  }

emptyWindow :: Window
emptyWindow = { partitionBy: [], orderBy: [], frame: Nothing }

-- | What a frame counts: physical rows, a range of `ORDER BY` values, or whole
-- | peer groups.
data FrameMode
  = Rows
  | Range
  | Groups

-- | One end of a frame.
-- |
-- | The offsets are emitted literally rather than as parameters, which keeps a
-- | frame out of the bindings entirely. PostgreSQL asks only that an offset
-- | contain no variables, aggregates or window functions, and a literal never
-- | does.
data FrameBound
  = UnboundedPreceding
  | Preceding Int
  | CurrentRow
  | Following Int
  | UnboundedFollowing

-- | Which rows of the partition a window function sees:
-- | `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`, and its kin.
-- |
-- | An absent `end` is SQL's one-bound form, `ROWS UNBOUNDED PRECEDING`, which
-- | runs from `start` to the current row.
type Frame =
  { mode  :: FrameMode
  , start :: FrameBound
  , end   :: Maybe FrameBound
  }

-- | One entry in a `WITH` clause: a named intermediate result set.
-- |
-- | A `newtype` around the record rather than a bare record synonym, because a
-- | CTE holds a `Query` and a `Query` holds CTEs — a synonym would be a
-- | recursive type synonym, which PureScript rejects. `Relation` breaks the
-- | same cycle the same way.
-- |
-- | `columns` is the optional output column list, `WITH "t" ("a", "b") AS (…)`;
-- | empty omits it.
-- |
-- | `recursive` is recorded per entry even though SQL puts `RECURSIVE` on the
-- | whole `WITH` clause. That keeps the builder local — `withRecursive` marks
-- | the one CTE it adds — and `Sqld.Format` folds the flags when it emits the
-- | keyword.
newtype Cte = Cte
  { name      :: String
  , columns   :: Array String
  , recursive :: Boolean
  , query     :: Query
  }

-- | How two result sets are combined. `ALL` is a flag on `SetOperation` rather
-- | than three more constructors here, so `UNION` and `UNION ALL` stay one
-- | operator with two spellings.
data SetOp
  = Union
  | Intersect
  | Except

derive instance Eq SetOp

-- | Two result sets combined: `left UNION right`, and so on.
-- |
-- | A `newtype` for the same reason as `Cte`: it closes a cycle through
-- | `Query`, which a record synonym cannot express.
-- |
-- | Both operands are complete queries, and both are bracketed when emitted.
-- | That makes a chain unambiguous whatever PostgreSQL's own precedence between
-- | `UNION` and `INTERSECT` happens to be, and it leaves each operand its own
-- | `ORDER BY` and `LIMIT`. The `ORDER BY`, `LIMIT` and `OFFSET` of the `Query`
-- | that *holds* the `SetOperation` fall outside the brackets, so they apply to
-- | the combined result.
newtype SetOperation = SetOperation
  { op    :: SetOp
  , all   :: Boolean
  , left  :: Query
  , right :: Query
  }

-- | A `SELECT` statement.
-- |
-- | `setOp` is what makes a query a set operation rather than a single
-- | `SELECT`. When it is present the operands supply the rows, so this record's
-- | `select`, `from`, `joins`, `where_`, `groupBy` and `having` have nothing to
-- | emit; `with`, `orderBy`, `limit` and `offset` still do, and apply to the
-- | combined result. The `Sqld.Select` builders start such a query from
-- | `emptyQuery`, so the unused fields stay empty — applying `select` or `from`
-- | to a set operation afterwards has no effect on the SQL.
type Query =
  { with    :: Array Cte
  , setOp   :: Maybe SetOperation
  , select  :: Array SelectExpr
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
  { with:    []
  , setOp:   Nothing
  , select:  []
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
