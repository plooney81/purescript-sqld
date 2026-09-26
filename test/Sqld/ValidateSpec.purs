-- | What `Sqld.Validate` accepts, and the short list of what it rejects.
-- |
-- | The corpus sweep is the important half. It runs the checker over every
-- | entry the validation harness replays — including the adversarial
-- | identifiers, which are legal PostgreSQL and must therefore pass — so a
-- | checker that started rejecting real queries would fail here rather than in
-- | a caller's application.
module Test.Sqld.ValidateSpec (validateSpec) where

import Prelude

import Data.Array (fromFoldable) as Array
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Tuple (Tuple(..))
import Sqld.Core (Statement(..))
import Sqld.Expr (app, col, int, str, tcol, (.==))
import Sqld.Select (as, cols, deleteFrom, deleteWhere, from, insertInto, select', set, update, where_, with_)
import Sqld.Validate (FormatError(..), IdentRole(..), formatChecked, validFunctionName, validate)
import Test.Sqld.Corpus (corpus)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

-- | A NUL byte, spelled so the escape cannot run into the character after it.
nul :: String
nul = "\x0"

validateSpec :: Spec Unit
validateSpec = describe "Sqld.Validate" do

  describe "the corpus validates clean" do
    for_ corpus \entry -> it entry.name do
      validate entry.statement `shouldEqual` []

  -- The names the security work added are hostile to read and perfectly legal
  -- to run. A checker that rejected them would be reporting its own dislike of
  -- the spelling rather than anything PostgreSQL cares about.
  describe "hostile but legal names pass" do
    it "an embedded double quote" do
      validate (select' (cols [ "a\"b" ]) # from "quo\"ted") `shouldEqual` []

    it "a statement terminator and a line comment" do
      validate
        ( select' [ as (tcol "q" "; DROP TABLE users; --") "-- alias" ]
            # from "users"
        ) `shouldEqual` []

    it "a value that looks like an attack" do
      validate
        ( select' (cols [ "id" ])
            # from "users"
            # where_ (col "name" .== str "'; DROP TABLE users; --")
        ) `shouldEqual` []

  -- The corpus sweep only ever asserts `[]`, and every case below it used to
  -- take a `Query`, so nothing held the other three walks — or the dispatch
  -- that reaches them — to reporting anything at all.
  describe "the other statement types" do
    it "rejects an empty INSERT target, bare and wrapped" do
      validate (insertInto "" [ "a" ]) `shouldEqual` [ EmptyIdentifier TableName ]
      validate (InsertStmt (insertInto "" [ "a" ])) `shouldEqual` [ EmptyIdentifier TableName ]

    it "rejects an empty INSERT column, bare and wrapped" do
      validate (insertInto "users" [ "" ]) `shouldEqual` [ EmptyIdentifier ColumnName ]
      validate (InsertStmt (insertInto "users" [ "" ])) `shouldEqual` [ EmptyIdentifier ColumnName ]

    it "rejects an empty UPDATE target, bare and wrapped" do
      validate (update "") `shouldEqual` [ EmptyIdentifier TableName ]
      validate (UpdateStmt (update "")) `shouldEqual` [ EmptyIdentifier TableName ]

    it "rejects an empty DELETE target, bare and wrapped" do
      validate (deleteFrom "") `shouldEqual` [ EmptyIdentifier TableName ]
      validate (DeleteStmt (deleteFrom "")) `shouldEqual` [ EmptyIdentifier TableName ]

    it "reaches inside an UPDATE, not just its table name" do
      validate (update "orders" # set [ Tuple "status" (app "" [ col "id" ]) ])
        `shouldEqual` [ BadFunctionName "" ]

    it "reaches inside a DELETE, not just its table name" do
      validate (deleteFrom "orders" # deleteWhere (col "" .== int 1))
        `shouldEqual` [ EmptyIdentifier ColumnName ]

    it "a SELECT wrapped in a Statement reports what the bare one does" do
      validate (SelectStmt (select' (cols [ "" ]) # from "users"))
        `shouldEqual` [ EmptyIdentifier ColumnName ]

  describe "formatChecked on every statement type" do
    it "refuses an INSERT that names nothing" do
      case formatChecked (insertInto "" [ "a" ]) of
        Left errs -> Array.fromFoldable errs `shouldEqual` [ EmptyIdentifier TableName ]
        Right _ -> fail "expected the empty table name to be rejected"

    it "refuses an UPDATE that names nothing" do
      case formatChecked (update "") of
        Left errs -> Array.fromFoldable errs `shouldEqual` [ EmptyIdentifier TableName ]
        Right _ -> fail "expected the empty table name to be rejected"

    it "refuses a DELETE that names nothing" do
      case formatChecked (deleteFrom "") of
        Left errs -> Array.fromFoldable errs `shouldEqual` [ EmptyIdentifier TableName ]
        Right _ -> fail "expected the empty table name to be rejected"

    it "refuses a Statement that names nothing, and formats one that does" do
      case formatChecked (DeleteStmt (deleteFrom "")) of
        Left errs -> Array.fromFoldable errs `shouldEqual` [ EmptyIdentifier TableName ]
        Right _ -> fail "expected the empty table name to be rejected"
      case formatChecked (DeleteStmt (deleteFrom "orders")) of
        Left _ -> fail "expected a well-formed DELETE to format"
        Right { sql } -> sql `shouldEqual` "DELETE FROM \"orders\""

  describe "identifiers" do
    it "rejects an empty column name" do
      validate (select' (cols [ "" ]) # from "users")
        `shouldEqual` [ EmptyIdentifier ColumnName ]

    it "rejects an empty table name" do
      validate (select' (cols [ "id" ]) # from "")
        `shouldEqual` [ EmptyIdentifier TableName ]

    it "rejects an empty alias" do
      validate (select' [ as (col "id") "" ] # from "users")
        `shouldEqual` [ EmptyIdentifier AliasName ]

    it "rejects an empty CTE name" do
      validate (select' (cols [ "id" ]) # with_ "" (select' (cols [ "id" ]) # from "users"))
        `shouldEqual` [ EmptyIdentifier CteName ]

    it "rejects a NUL byte, naming the role and the name" do
      validate (select' (cols [ "id" ]) # from ("us" <> nul <> "ers"))
        `shouldEqual` [ NulInIdentifier TableName ("us" <> nul <> "ers") ]

    -- The walk reaches subqueries, CTE bodies and join targets, not only the
    -- clauses of the outermost SELECT.
    it "reaches into a CTE body" do
      validate
        ( select' (cols [ "id" ])
            # from "t"
            # with_ "t" (select' (cols [ "" ]) # from "users")
        ) `shouldEqual` [ EmptyIdentifier ColumnName ]

    it "reports every problem, in emitted order" do
      validate (select' (cols [ "", "id" ]) # from "")
        `shouldEqual` [ EmptyIdentifier ColumnName, EmptyIdentifier TableName ]

  describe "function names" do
    for_ [ "COUNT", "count", "pg_catalog.count", "date_trunc", "x1", "_f", "f$1" ] \name ->
      it ("accepts " <> show name) do
        validFunctionName name `shouldEqual` true

    for_ [ "", "count(*)", "we ird", "1up", "\"quoted\"", "a..b", "a;b", "DROP TABLE users" ] \name ->
      it ("rejects " <> show name) do
        validFunctionName name `shouldEqual` false

    it "reports the name it rejected" do
      validate (select' [ as (app "count(*) --" []) "n" ] # from "users")
        `shouldEqual` [ BadFunctionName "count(*) --" ]

  -- What the checker does not promise. These are trusted input, and a checker
  -- that quietly rejected them would be making a promise the README does not.
  describe "trusted input is not checked" do
    it "an operator passes through" do
      validate (select' (cols [ "id" ]) # from "users" # where_ (col "age" .== int 1))
        `shouldEqual` []

    it "a raw fragment passes through" do
      validate (select' [ as (app "COUNT" []) "n" ] # from "users") `shouldEqual` []

  describe "formatChecked" do
    it "formats a well-formed query" do
      case formatChecked (select' (cols [ "id" ]) # from "users" # where_ (col "id" .== int 1)) of
        Left errs -> fail ("unexpected errors: " <> show (Array.fromFoldable errs))
        Right { sql, params } -> do
          sql `shouldEqual` "SELECT \"id\" FROM \"users\" WHERE \"id\" = $1"
          show params `shouldEqual` "[(LitInt 1)]"

    it "refuses one that is not, and says why" do
      case formatChecked (select' (cols [ "" ]) # from "users") of
        Left errs -> Array.fromFoldable errs `shouldEqual` [ EmptyIdentifier ColumnName ]
        Right _ -> fail "expected the empty column name to be rejected"
