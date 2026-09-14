-- | Writes the validation corpus to disk as JSON so `scripts/validate-sql.mjs`
-- | can replay it against a real PostgreSQL server.
module Test.Sqld.CorpusEmit
  ( corpusPath
  , corpusJson
  , emitCorpusJson
  , examplesPath
  , examplesJson
  , emitExamplesJson
  ) where

import Prelude

import Data.Foldable (intercalate)
import Effect (Effect)
import Node.Encoding (Encoding(..))
import Node.FS.Perms (permsAll)
import Node.FS.Sync (mkdir', writeTextFile)
import Example.Cookbook (DeleteExample, Example, InsertExample, UpdateExample, cookbook, deleteCookbook, insertCookbook, updateCookbook)
import Sqld.Format (format, formatDeleteInline, formatDeletePretty, formatDeleteStmt, formatInline, formatInsert, formatInsertInline, formatInsertPretty, formatPretty, formatUpdateStmt, formatUpdateInline, formatUpdatePretty)
import Test.Sqld.Corpus (CorpusEntry, DeleteEntry, InsertEntry, UpdateEntry, corpus, deleteCorpus, insertCorpus, updateCorpus)
import Test.Sqld.Json (jsonString, literalJson)

corpusDir :: String
corpusDir = "test-artifacts"

corpusPath :: String
corpusPath = corpusDir <> "/corpus.json"

examplesPath :: String
examplesPath = corpusDir <> "/examples.json"

emitCorpusJson :: Effect Unit
emitCorpusJson = do
  mkdir' corpusDir { recursive: true, mode: permsAll }
  writeTextFile UTF8 corpusPath corpusJson

-- | The SQL each cookbook example produces, for `scripts/build-examples.mjs`.
-- | `prettySql` is the multi-line rendering shown in the docs; `sql` and
-- | `params` are what a driver would actually receive.
emitExamplesJson :: Effect Unit
emitExamplesJson = do
  mkdir' corpusDir { recursive: true, mode: permsAll }
  writeTextFile UTF8 examplesPath examplesJson

examplesJson :: String
examplesJson = "[\n" <> intercalate ",\n" (map exampleJson cookbook <> map insertExampleJson insertCookbook <> map updateExampleJson updateCookbook <> map deleteExampleJson deleteCookbook) <> "\n]\n"

exampleJson :: Example -> String
exampleJson example =
  "  { \"name\": " <> jsonString example.name
    <> ", \"sql\": "
    <> jsonString formatted.sql
    <> ", \"params\": ["
    <> intercalate ", " (map literalJson formatted.params)
    <> "]"
    <> ", \"prettySql\": "
    <> jsonString (formatPretty example.query)
    <> " }"
  where
  formatted = format example.query

insertExampleJson :: InsertExample -> String
insertExampleJson example =
  "  { \"name\": " <> jsonString example.name
    <> ", \"sql\": "
    <> jsonString formatted.sql
    <> ", \"params\": ["
    <> intercalate ", " (map literalJson formatted.params)
    <> "]"
    <> ", \"prettySql\": "
    <> jsonString (formatInsertPretty example.insert)
    <> " }"
  where
  formatted = formatInsert example.insert

corpusJson :: String
corpusJson = "[\n" <> intercalate ",\n" (map entryJson corpus <> map insertEntryJson insertCorpus <> map updateEntryJson updateCorpus <> map deleteEntryJson deleteCorpus) <> "\n]\n"

entryJson :: CorpusEntry -> String
entryJson entry =
  "  { \"name\": " <> jsonString entry.name
    <> ", \"sql\": "
    <> jsonString formatted.sql
    <> ", \"params\": ["
    <> intercalate ", " (map literalJson formatted.params)
    <> "]"
    <> ", \"inlineSql\": "
    <> jsonString (formatInline entry.query)
    <> " }"
  where
  formatted = format entry.query

insertEntryJson :: InsertEntry -> String
insertEntryJson entry =
  "  { \"name\": " <> jsonString entry.name
    <> ", \"sql\": "
    <> jsonString formatted.sql
    <> ", \"params\": ["
    <> intercalate ", " (map literalJson formatted.params)
    <> "]"
    <> ", \"inlineSql\": "
    <> jsonString (formatInsertInline entry.insert)
    <> " }"
  where
  formatted = formatInsert entry.insert

updateExampleJson :: UpdateExample -> String
updateExampleJson example =
  "  { \"name\": " <> jsonString example.name
    <> ", \"sql\": "
    <> jsonString formatted.sql
    <> ", \"params\": ["
    <> intercalate ", " (map literalJson formatted.params)
    <> "]"
    <> ", \"prettySql\": "
    <> jsonString (formatUpdatePretty example.update)
    <> " }"
  where
  formatted = formatUpdateStmt example.update

deleteExampleJson :: DeleteExample -> String
deleteExampleJson example =
  "  { \"name\": " <> jsonString example.name
    <> ", \"sql\": "
    <> jsonString formatted.sql
    <> ", \"params\": ["
    <> intercalate ", " (map literalJson formatted.params)
    <> "]"
    <> ", \"prettySql\": "
    <> jsonString (formatDeletePretty example.delete)
    <> " }"
  where
  formatted = formatDeleteStmt example.delete

updateEntryJson :: UpdateEntry -> String
updateEntryJson entry =
  "  { \"name\": " <> jsonString entry.name
    <> ", \"sql\": "
    <> jsonString formatted.sql
    <> ", \"params\": ["
    <> intercalate ", " (map literalJson formatted.params)
    <> "]"
    <> ", \"inlineSql\": "
    <> jsonString (formatUpdateInline entry.update)
    <> " }"
  where
  formatted = formatUpdateStmt entry.update

deleteEntryJson :: DeleteEntry -> String
deleteEntryJson entry =
  "  { \"name\": " <> jsonString entry.name
    <> ", \"sql\": "
    <> jsonString formatted.sql
    <> ", \"params\": ["
    <> intercalate ", " (map literalJson formatted.params)
    <> "]"
    <> ", \"inlineSql\": "
    <> jsonString (formatDeleteInline entry.delete)
    <> " }"
  where
  formatted = formatDeleteStmt entry.delete
