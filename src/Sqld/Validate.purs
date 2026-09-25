-- | Optional, opt-in checking of the strings that reach the SQL text.
-- |
-- | `Sqld.Format.format` is total: it quotes what it can quote and emits the
-- | rest as written. This module is the other half of that bargain — a walk
-- | over the same AST that reports the strings PostgreSQL will not accept,
-- | before they are sent.
-- |
-- | ## What it checks
-- |
-- |   * **Identifiers** — table, column, alias, CTE and `USING` names. Two
-- |     conditions, both exact: a name must be non-empty, and must not contain
-- |     a NUL byte. Everything else is safe in a quoted identifier, `"` and `;`
-- |     and `--` included, because `quoteIdent` doubles the quote — so this is
-- |     the whole of what quoting cannot survive.
-- |   * **Function names** — `Sqld.Expr.app` emits its name unquoted, so it
-- |     must look like one: dot-separated parts, each starting with a letter or
-- |     `_` and continuing with letters, digits, `_` or `$`. `COUNT` and
-- |     `pg_catalog.count` pass; `"weird name"` does not, even spelled with its
-- |     own quotes, and has to go through `raw`.
-- |
-- | ## What it does not check, and why
-- |
-- | Operators (`binOp`, `unary`, `postfix`, `orderUsing`, and the operator of a
-- | quantified comparison), type names (`cast`) and `raw` are **trusted input**
-- | — the README's security section says so, and this module does not quietly
-- | promise otherwise.
-- |
-- | The reason is that neither admits a check worth the name. An operator is
-- | either symbols drawn from PostgreSQL's operator set or a keyword, and the
-- | keywords cannot be enumerated: this library's own helpers emit `IN`,
-- | `LIKE`, `IS NULL` and `EXISTS`, and `IS DISTINCT FROM`, `AT TIME ZONE` and
-- | `OPERATOR(pg_catalog.=)` are all legitimate SQL an allowlist would reject.
-- | A type name is worse: `text`, `text[]`, `numeric(10,2)`, `double precision`
-- | and `timestamp with time zone` all have to pass, and once letters, digits,
-- | spaces, dots, brackets, parens and commas are permitted, what is left to
-- | reject is `'`, `"`, `;` and `-`. That is a blacklist wearing an allowlist's
-- | clothes, and a blacklist is the thing this library exists to avoid.
-- |
-- | A checker that rejected those would send callers to `raw` for the cases it
-- | got wrong, which is strictly worse than what it prevents. So the line is
-- | drawn where a check can be exact, and written down where it is not.
-- |
-- | ## Drift
-- |
-- | The walk carries no catch-all case, so a constructor added to `Sqld.Core`
-- | fails to compile here exactly as it does in `Sqld.Format`. A *field* added
-- | to one of the records — `Query`, `Insert`, `Update`, `Delete` — is not
-- | caught that way, since a record pattern does not have to be exhaustive.
-- | `Test.Sqld.ValidateSpec` covers that gap from the other side: every corpus
-- | entry must validate clean, and the corpus is already ratcheted to reach
-- | every constructor.
module Sqld.Validate
  ( IdentRole(..)
  , FormatError(..)
  , validate
  , validateInsert
  , validateUpdate
  , validateDelete
  , formatChecked
  , formatInsertChecked
  , formatUpdateChecked
  , formatDeleteChecked
  , validIdentifier
  , validFunctionName
  ) where

import Prelude

import Data.Array (all, null) as Array
import Data.Array.NonEmpty (NonEmptyArray)
import Data.Array.NonEmpty (fromArray) as NEA
import Data.Either (Either(..))
import Data.Foldable (foldMap)
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.String.CodeUnits (toCharArray, uncons) as CU
import Data.Tuple (Tuple(..))
import Sqld.Core (Cte(..), Delete, Distinct(..), Expr(..), FormattedQuery, GroupingElement(..), Insert, InsertSource(..), Join, JoinCondition(..), Locking, OnConflict(..), OrderExpr, Query, Relation(..), SelectExpr(..), SetOperation(..), Update)
import Sqld.Format (format, formatDeleteStmt, formatInsert, formatUpdateStmt)

-- ---------------------------------------------------------------------------
-- Errors
-- ---------------------------------------------------------------------------

-- | What an identifier was naming, so a report says where to look.
data IdentRole
  = TableName
  | ColumnName
  | AliasName
  | CteName

derive instance Eq IdentRole

instance Show IdentRole where
  show TableName  = "table name"
  show ColumnName = "column name"
  show AliasName  = "alias"
  show CteName    = "CTE name"

-- | A string that cannot reach PostgreSQL as it stands.
-- |
-- | Deliberately without a constructor for an operator, a type name or a `raw`
-- | fragment: those are trusted input, and an error type that named them would
-- | imply a check this module does not make.
data FormatError
  = EmptyIdentifier IdentRole
  | NulInIdentifier IdentRole String
  | BadFunctionName String

derive instance Eq FormatError

-- | Readable rather than round-trippable: these are for a log line or a test
-- | failure, and the value is reconstructible from the constructors anyway.
instance Show FormatError where
  show (EmptyIdentifier role) =
    "empty " <> show role
  show (NulInIdentifier role name) =
    "NUL byte in " <> show role <> ": " <> show name
  show (BadFunctionName name) =
    "not a function name: " <> show name

-- ---------------------------------------------------------------------------
-- Predicates
-- ---------------------------------------------------------------------------

-- | Whether a name survives quoting: non-empty, and free of NUL.
-- |
-- | Every other character is safe once quoted, including the ones that look
-- | dangerous — `quoteIdent` doubles an embedded `"`, which is what keeps
-- | `x" FROM "secrets" --` a single identifier. A name over PostgreSQL's
-- | 63-byte limit is *not* rejected: the server truncates it rather than
-- | failing, that is documented behaviour, and a check here would forbid names
-- | PostgreSQL itself accepts.
-- | Defined through the walk's own leaf rather than beside it, so the
-- | predicate a caller reads cannot drift from the check `validate` makes.
validIdentifier :: String -> Boolean
validIdentifier = Array.null <<< ident ColumnName

-- | The NUL byte, spelled so the escape cannot run into what follows it.
nul :: String
nul = "\x0"

-- | Whether a name can be emitted unquoted as a function: one or more
-- | dot-separated identifier parts.
validFunctionName :: String -> Boolean
validFunctionName name =
  not (Array.null parts) && Array.all part parts
  where
  parts = String.split (String.Pattern ".") name

  part p = case CU.uncons p of
    Nothing            -> false
    Just { head, tail } -> leading head && Array.all following (CU.toCharArray tail)

  leading c = alpha c || c == '_'
  following c = alpha c || digit c || c == '_' || c == '$'

  alpha c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
  digit c = c >= '0' && c <= '9'

-- ---------------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------------

-- | Formats, unless the query names something PostgreSQL cannot be given.
-- |
-- | The check is the module's, and only the module's: see the header for what
-- | it covers. A `Right` says the identifiers and function names are
-- | well-formed, not that the query is safe — an operator or a `raw` fragment
-- | built from untrusted input is still whatever the caller made it.
formatChecked :: Query -> Either (NonEmptyArray FormatError) FormattedQuery
formatChecked = checked validate format

formatInsertChecked :: Insert -> Either (NonEmptyArray FormatError) FormattedQuery
formatInsertChecked = checked validateInsert formatInsert

formatUpdateChecked :: Update -> Either (NonEmptyArray FormatError) FormattedQuery
formatUpdateChecked = checked validateUpdate formatUpdateStmt

formatDeleteChecked :: Delete -> Either (NonEmptyArray FormatError) FormattedQuery
formatDeleteChecked = checked validateDelete formatDeleteStmt

-- | Runs the check, and formats only if it found nothing.
checked
  :: ∀ a
   . (a -> Array FormatError)
  -> (a -> FormattedQuery)
  -> a
  -> Either (NonEmptyArray FormatError) FormattedQuery
checked check emit x = case NEA.fromArray (check x) of
  Just errs -> Left errs
  Nothing   -> Right (emit x)

-- ---------------------------------------------------------------------------
-- The walk
-- ---------------------------------------------------------------------------

-- | Every problem in a query, in the order the SQL emits them.
validate :: Query -> Array FormatError
validate q =
  foldMap cte q.with
    <> foldMap setOp q.setOp
    <> foldMap distinct q.distinct
    <> foldMap selectExpr q.select
    <> foldMap relation q.from
    <> foldMap joinItem q.joins
    <> foldMap expr q.where_
    <> foldMap grouping q.groupBy
    <> foldMap expr q.having
    <> foldMap orderExpr q.orderBy
    <> foldMap expr q.limit
    <> foldMap expr q.offset
    <> foldMap locking q.locking

validateInsert :: Insert -> Array FormatError
validateInsert i =
  ident TableName i.table
    <> foldMap (ident ColumnName) i.columns
    <> insertSource i.source
    <> foldMap onConflict i.onConflict
    <> foldMap selectExpr i.returning

validateUpdate :: Update -> Array FormatError
validateUpdate u =
  ident TableName u.table
    <> foldMap assignment u.set
    <> foldMap (ident TableName) u.from
    <> foldMap expr u.where_
    <> foldMap selectExpr u.returning

validateDelete :: Delete -> Array FormatError
validateDelete d =
  ident TableName d.table
    <> foldMap (ident TableName) d.using
    <> foldMap expr d.where_
    <> foldMap selectExpr d.returning

-- ---------------------------------------------------------------------------
-- One case per constructor — no catch-all, so a new one breaks the build
-- ---------------------------------------------------------------------------

expr :: Expr -> Array FormatError
expr (Col { table, column }) = foldMap (ident TableName) table <> ident ColumnName column
expr (Lit _)                 = []
expr (App name args)         = fn name <> foldMap expr args
expr (BinOp _ l r)           = expr l <> expr r
expr (Quantified _ _ l r)    = expr l <> expr r
expr (Unary _ e)             = expr e
expr (Postfix _ e)           = expr e
expr (Cast e _)              = expr e
expr (Row es)                = foldMap expr es
expr (Sub q)                 = validate q
expr (And es)                = foldMap expr es
expr (Or es)                 = foldMap expr es
expr (Between e lo hi)       = expr e <> expr lo <> expr hi
expr (Over e w)              = expr e <> foldMap expr w.partitionBy <> foldMap orderExpr w.orderBy
expr (Filter e p)            = expr e <> expr p
expr (Raw _)                 = []
expr Default                 = []

selectExpr :: SelectExpr -> Array FormatError
selectExpr (SelectExpr e)      = expr e
selectExpr (SelectAs e alias)  = expr e <> ident AliasName alias
selectExpr SelectStar          = []
selectExpr (SelectStarFrom t)  = ident TableName t

relation :: Relation -> Array FormatError
relation (Table name alias) = ident TableName name <> foldMap (ident AliasName) alias
relation (Derived q alias)  = validate q <> ident AliasName alias
relation (Lateral q alias)  = validate q <> ident AliasName alias

joinItem :: Join -> Array FormatError
joinItem j = relation j.relation <> joinCondition j.condition

joinCondition :: JoinCondition -> Array FormatError
joinCondition (On _ e)        = expr e
joinCondition (Using _ cols)  = foldMap (ident ColumnName) cols
joinCondition (Natural _)     = []
joinCondition Cross           = []

grouping :: GroupingElement -> Array FormatError
grouping (GroupingExpr e)  = expr e
grouping (GroupingSets es) = foldMap (foldMap expr) es
grouping (Cube es)         = foldMap expr es
grouping (Rollup es)       = foldMap expr es

distinct :: Distinct -> Array FormatError
distinct Distinct        = []
distinct (DistinctOn es) = foldMap expr es

orderExpr :: OrderExpr -> Array FormatError
orderExpr o = expr o.expr

locking :: Locking -> Array FormatError
locking l = foldMap (ident TableName) l.tables

cte :: Cte -> Array FormatError
cte (Cte c) =
  ident CteName c.name
    <> foldMap (ident ColumnName) c.columns
    <> validate c.query

setOp :: SetOperation -> Array FormatError
setOp (SetOperation s) = validate s.left <> validate s.right

insertSource :: InsertSource -> Array FormatError
insertSource (InsertValues rows) = foldMap (foldMap expr) rows
insertSource (InsertQuery q)     = validate q

onConflict :: OnConflict -> Array FormatError
onConflict DoNothing = []
onConflict (DoUpdate targets assignments) =
  foldMap (ident ColumnName) targets <> foldMap assignment assignments

assignment :: Tuple String Expr -> Array FormatError
assignment (Tuple column e) = ident ColumnName column <> expr e

-- ---------------------------------------------------------------------------
-- Leaves
-- ---------------------------------------------------------------------------

ident :: IdentRole -> String -> Array FormatError
ident role name
  | String.null name                                 = [ EmptyIdentifier role ]
  | String.contains (String.Pattern nul) name        = [ NulInIdentifier role name ]
  | otherwise                                        = []

fn :: String -> Array FormatError
fn name = if validFunctionName name then [] else [ BadFunctionName name ]
