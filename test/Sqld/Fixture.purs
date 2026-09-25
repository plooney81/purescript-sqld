-- | The fixture schema, as a value.
-- |
-- | `test/fixtures/schema.sql` is what PostgreSQL sees; this is what the
-- | generators in `Test.Sqld.Generate` draw table and column names from. The
-- | two must agree — a generated query naming a column the database does not
-- | have fails parse analysis for a reason that has nothing to do with sqld —
-- | so `Test.Sqld.GenerateSpec` parses the SQL file and asserts it matches this
-- | module, rather than leaving the pair to drift.
module Test.Sqld.Fixture
  ( SqlType(..)
  , typeName
  , Column
  , Table
  , RawTable
  , RawColumn
  , fixtureSchema
  , schemaPath
  , parseSchemaSql
  ) where

import Prelude

import Control.Alternative (guard)
import Data.Array as Array
import Data.Foldable (foldl)
import Data.Maybe (Maybe)
import Data.String as String

-- | The column types the fixture schema uses. Small on purpose: the generators
-- | build expressions by type, so every type here needs literals, operators and
-- | functions of its own, and one that earns none of those buys no coverage.
data SqlType
  = TyInt
  | TyNum
  | TyText
  | TyBool
  | TyTime

derive instance Eq SqlType
derive instance Ord SqlType

instance Show SqlType where
  show = typeName

-- | The PostgreSQL spelling, which is also what a `CAST` target must say. It
-- | has to match `schema.sql` exactly, because that is what the drift check
-- | compares.
typeName :: SqlType -> String
typeName TyInt  = "integer"
typeName TyNum  = "numeric"
typeName TyText = "text"
typeName TyBool = "boolean"
typeName TyTime = "timestamptz"

type Column = { name :: String, ty :: SqlType }
type Table = { name :: String, columns :: Array Column }

schemaPath :: String
schemaPath = "test/fixtures/schema.sql"

fixtureSchema :: Array Table
fixtureSchema =
  [ { name: "users"
    , columns:
        [ { name: "id",         ty: TyInt }
        , { name: "name",       ty: TyText }
        , { name: "email",      ty: TyText }
        , { name: "active",     ty: TyBool }
        , { name: "age",        ty: TyInt }
        , { name: "score",      ty: TyNum }
        , { name: "department", ty: TyText }
        , { name: "created_at", ty: TyTime }
        ]
    }
  , { name: "profiles"
    , columns:
        [ { name: "id",      ty: TyInt }
        , { name: "user_id", ty: TyInt }
        , { name: "bio",     ty: TyText }
        ]
    }
  , { name: "orders"
    , columns:
        [ { name: "id",        ty: TyInt }
        , { name: "user_id",   ty: TyInt }
        , { name: "status",    ty: TyText }
        , { name: "total",     ty: TyNum }
        , { name: "placed_at", ty: TyTime }
        ]
    }
  , { name: "departments"
    , columns:
        [ { name: "department", ty: TyText }
        , { name: "building",   ty: TyText }
        , { name: "budget",     ty: TyNum }
        ]
    }
  , { name: "articles"
    , columns:
        [ { name: "id",           ty: TyInt }
        , { name: "title",        ty: TyText }
        , { name: "published_at", ty: TyTime }
        ]
    }
  ]

-- ---------------------------------------------------------------------------
-- Reading the schema back out of the SQL
-- ---------------------------------------------------------------------------

-- | A table as the SQL file spells it: types stay strings, so the drift check
-- | compares `typeName` against the file rather than against a mapping this
-- | module also owns.
type RawColumn = { name :: String, ty :: String }
type RawTable = { name :: String, columns :: Array RawColumn }

-- | Reads the `CREATE TABLE` statements out of `schema.sql`.
-- |
-- | Deliberately not a SQL parser: it knows only the shape the fixture file is
-- | written in — one column per line, the column name first and its type
-- | second. A statement it cannot read yields no columns, which the drift check
-- | reports as a mismatch rather than silently passing.
-- |
-- | A table whose name is quoted is skipped outright. Those exist for the
-- | injection corpus, and their names hold the very characters this reader
-- | splits on — a space, a comma, a `--`. The generator has no business in
-- | them, so the drift check does not ask it to read them.
parseSchemaSql :: String -> Array RawTable
parseSchemaSql = Array.mapMaybe table <<< Array.drop 1 <<< split "CREATE TABLE "
  where
  table chunk = do
    name <- Array.head (words chunk)
    guard (not (String.contains (String.Pattern "\"") name))
    body <- sliceBetween "(" ");" chunk
    pure { name, columns: Array.mapMaybe column (split "\n" body) }

  column line = do
    let parts = words line
    name <- Array.index parts 0
    ty <- Array.index parts 1
    pure { name, ty }

-- | The text between the first `open` and the first `close` after it.
sliceBetween :: String -> String -> String -> Maybe String
sliceBetween open close s = do
  start <- String.indexOf (String.Pattern open) s
  let rest = String.drop (start + String.length open) s
  end <- String.indexOf (String.Pattern close) rest
  pure (String.take end rest)

-- | Splits on whitespace, dropping the empty pieces that runs of it leave
-- | behind. The fixture file aligns its column types with spaces, so those runs
-- | are the common case rather than an edge one.
words :: String -> Array String
words s = Array.filter (_ /= "") (split " " (foldl blank s separators))
  where
  separators = [ "\n", "\r", "\t", "(", ")", "," ]
  blank acc c = String.replaceAll (String.Pattern c) (String.Replacement " ") acc

split :: String -> String -> Array String
split = String.split <<< String.Pattern
