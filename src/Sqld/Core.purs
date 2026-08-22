module Sqld.Core where

import Prelude
import Data.Maybe (Maybe(..))

-- | The fixed SQL keyword a value renders as.
-- |
-- | Only for the AST's leaves: a keyword depends on nothing but the value —
-- | no layout, no bindings, and no dependence on where it appears. Anything
-- | whose rendering varies with context belongs in `Sqld.Format`.
class Keyword a where
  keyword :: a -> String

type ColumnRef = { table :: Maybe String, column :: String }

-- | Anything that can appear in `FROM` or as a join target.
-- |
-- | `Derived` takes its alias as a plain `String` rather than a `Maybe`:
-- | PostgreSQL rejects a subquery in `FROM` without one, so the type rules out
-- | a query that could never run. `Lateral` is that same subquery marked
-- | `LATERAL`, which lets it reference columns of the relations to its left.
-- |
-- | `Lateral` is a constructor of its own rather than a flag on `Derived`,
-- | because `Table` has no lateral form: only a subquery can be marked, and a
-- | flag would have to sit somewhere that admits both.
data Relation
  = Table String (Maybe String)
  | Derived Query String
  | Lateral Query String

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
  -- | An aggregate and the rows it is allowed to see:
  -- | `COUNT(*) FILTER (WHERE "active")`.
  -- |
  -- | Two `Expr`s rather than an aggregate and a predicate, because the AST has
  -- | no aggregate of its own: `App` covers every function in `pg_proc`, and
  -- | which of them aggregate is PostgreSQL's to say. A `FILTER` on a scalar
  -- | function is therefore expressible, and it is the database that rejects
  -- | it.
  | Filter Expr Expr
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

instance Keyword JoinType where
  keyword InnerJoin = "JOIN"
  keyword LeftJoin  = "LEFT JOIN"
  keyword RightJoin = "RIGHT JOIN"
  keyword FullJoin  = "FULL JOIN"

-- | How a join finds the rows it pairs — and, because SQL ties the two
-- | together, which spelling of `JOIN` carries it.
-- |
-- | The kind of join sits inside the condition rather than beside it, so the
-- | combinations SQL has no syntax for cannot be written down. `Cross` takes no
-- | `JoinType`, because `CROSS JOIN` is neither outer nor conditional;
-- | `Natural` takes one but no expression, because `NATURAL` *is* the
-- | condition. A `JoinType` field alongside an independent condition would let
-- | `CROSS JOIN … ON (…)` be built and leave PostgreSQL to reject it.
-- |
-- | `Using` holds column names, not expressions: `USING` matches columns
-- | present in both relations, so its contents are identifiers and are quoted
-- | as such.
data JoinCondition
  = On JoinType Expr
  | Using JoinType (Array String)
  | Natural JoinType
  | Cross

type Join =
  { relation  :: Relation
  , condition :: JoinCondition
  }

data OrderDir = Asc | Desc

instance Keyword OrderDir where
  keyword Asc  = "ASC"
  keyword Desc = "DESC"

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

instance Keyword FrameMode where
  keyword Rows   = "ROWS"
  keyword Range  = "RANGE"
  keyword Groups = "GROUPS"

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

-- | Not a pure lookup — `Preceding` and `Following` carry an offset — but the
-- | result still depends on nothing but the value.
instance Keyword FrameBound where
  keyword UnboundedPreceding = "UNBOUNDED PRECEDING"
  keyword (Preceding n)      = show n <> " PRECEDING"
  keyword CurrentRow         = "CURRENT ROW"
  keyword (Following n)      = show n <> " FOLLOWING"
  keyword UnboundedFollowing = "UNBOUNDED FOLLOWING"

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

instance Keyword SetOp where
  keyword Union     = "UNION"
  keyword Intersect = "INTERSECT"
  keyword Except    = "EXCEPT"

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

-- | Which rows a `SELECT` keeps.
-- |
-- | `Distinct` is SQL's own `DISTINCT`: duplicate rows collapse to one.
-- | `DistinctOn` is PostgreSQL's, and keeps the first row of each group of the
-- | given expressions — where "first" is whatever the `ORDER BY` says, which is
-- | why PostgreSQL requires its leading expressions to match these.
-- |
-- | The two are one field rather than two, because a `SELECT` is one or the
-- | other and never both. Absent is `ALL`, the default: every row survives.
data Distinct
  = Distinct
  | DistinctOn (Array Expr)

-- | One element of a `GROUP BY` clause.
-- |
-- | A `GROUP BY` is a list of these rather than a flat list of expressions,
-- | because SQL lets the forms sit side by side: `GROUP BY "a", ROLLUP ("b")`
-- | is one clause of two elements, and only the first is a bare expression.
-- |
-- | `GroupingSets` names its groupings one by one — `Array (Array Expr)`, one
-- | grouping per set, and the result holds every group of every set. The inner
-- | array is what makes the empty grouping set `()` expressible, which is the
-- | one group holding every row: the grand total. `Cube` and
-- | `Rollup` are shorthands for two families of those sets: `ROLLUP (a, b)` is
-- | `(a, b), (a), ()`, the subtotals down one hierarchy, and `CUBE (a, b)` adds
-- | `(b)` — every combination rather than every prefix.
data GroupingElement
  = GroupingExpr Expr
  | GroupingSets (Array (Array Expr))
  | Cube (Array Expr)
  | Rollup (Array Expr)

-- | How strongly `FOR UPDATE` and its kin lock the rows a `SELECT` returns.
-- |
-- | `ForUpdate` is the strongest: the rows are locked as if for `UPDATE` or
-- | `DELETE`, and no other transaction may lock, modify or delete them.
-- | `ForNoKeyUpdate` is weaker only in that it does not block a `FOR KEY SHARE`
-- | — which is the lock a foreign key reference takes — so a child row may
-- | still be inserted against a parent locked this way. `ForShare` and
-- | `ForKeyShare` are the shared counterparts of the two: several transactions
-- | may hold them at once, and they block writers rather than each other.
data LockStrength
  = ForUpdate
  | ForNoKeyUpdate
  | ForShare
  | ForKeyShare

instance Keyword LockStrength where
  keyword ForUpdate      = "FOR UPDATE"
  keyword ForNoKeyUpdate = "FOR NO KEY UPDATE"
  keyword ForShare       = "FOR SHARE"
  keyword ForKeyShare    = "FOR KEY SHARE"

-- | What a locking clause does when a row it wants is already locked.
-- |
-- | Absent, it waits. `NoWait` raises an error instead, and `SkipLocked` leaves
-- | the row out of the result — which is what makes a work queue work, since
-- | each worker then claims rows no other worker holds rather than queueing
-- | behind them.
-- |
-- | One field rather than two flags, because SQL admits one or the other and
-- | never both.
data LockWait
  = NoWait
  | SkipLocked

instance Keyword LockWait where
  keyword NoWait     = "NOWAIT"
  keyword SkipLocked = "SKIP LOCKED"

-- | One locking clause: `FOR UPDATE OF "orders" SKIP LOCKED`.
-- |
-- | `tables` is the optional `OF` list, naming which of the query's `FROM`
-- | items the clause applies to; empty locks every one of them. They are the
-- | names — or aliases — those items go by, so they are identifiers and are
-- | quoted as such rather than bound.
type Locking =
  { strength :: LockStrength
  , tables   :: Array String
  , wait     :: Maybe LockWait
  }

-- | A `SELECT` statement.
-- |
-- | `setOp` is what makes a query a set operation rather than a single
-- | `SELECT`. When it is present the operands supply the rows, so this record's
-- | `distinct`, `select`, `from`, `joins`, `where_`, `groupBy` and `having` have
-- | nothing to emit; `with`, `orderBy`, `limit` and `offset` still do, and apply
-- | to the combined result. The `Sqld.Select` builders start such a query from
-- | `emptyQuery`, so the unused fields stay empty — applying `select` or `from`
-- | to a set operation afterwards has no effect on the SQL.
-- |
-- | `locking` is emitted last, after `LIMIT` and `OFFSET`, which is where SQL
-- | puts it. It is a list because SQL allows more than one clause — `FOR UPDATE
-- | OF "a" FOR SHARE OF "b"` locks two relations two ways — and each entry
-- | stands on its own. PostgreSQL rejects a locking clause on a query that also
-- | uses `DISTINCT`, `GROUP BY`, `HAVING`, a window function or a set
-- | operation, since none of those return rows a lock could be placed on; that
-- | is a rule it enforces itself rather than one this type expresses.
type Query =
  { with     :: Array Cte
  , setOp    :: Maybe SetOperation
  , distinct :: Maybe Distinct
  , select   :: Array SelectExpr
  , from     :: Maybe Relation
  , joins    :: Array Join
  , where_   :: Maybe Expr
  , groupBy  :: Array GroupingElement
  , having   :: Maybe Expr
  , orderBy  :: Array OrderExpr
  , limit    :: Maybe Int
  , offset   :: Maybe Int
  , locking  :: Array Locking
  }

emptyQuery :: Query
emptyQuery =
  { with:     []
  , setOp:    Nothing
  , distinct: Nothing
  , select:   []
  , from:     Nothing
  , joins:    []
  , where_:   Nothing
  , groupBy:  []
  , having:   Nothing
  , orderBy:  []
  , limit:    Nothing
  , offset:   Nothing
  , locking:  []
  }

type FormattedQuery =
  { sql    :: String
  , params :: Array Literal
  }
