-- | Writes the validation corpus to disk as JSON so `scripts/validate-sql.mjs`
-- | can replay it against a real PostgreSQL server.
-- |
-- | JSON is hand-rolled rather than pulled in via argonaut: the shape is three
-- | fields wide and this keeps the test suite's dependency footprint small.
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
import Data.String as String
import Effect (Effect)
import Node.Encoding (Encoding(..))
import Node.FS.Perms (permsAll)
import Node.FS.Sync (mkdir', writeTextFile)
import Sqld.Core (Literal(..))
import Example.Cookbook (DeleteExample, Example, InsertExample, UpdateExample, cookbook, deleteCookbook, insertCookbook, updateCookbook)
import Sqld.Format (format, formatDeleteInline, formatDeletePretty, formatDeleteStmt, formatInline, formatInsert, formatInsertInline, formatInsertPretty, formatPretty, formatUpdateStmt, formatUpdateInline, formatUpdatePretty)
import Test.Sqld.Corpus (CorpusEntry, DeleteEntry, InsertEntry, UpdateEntry, corpus, deleteCorpus, insertCorpus, updateCorpus)

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

literalJson :: Literal -> String
literalJson = case _ of
  LitInt n -> show n
  LitNumber n -> show n
  LitString s -> jsonString s
  LitBoolean b -> if b then "true" else "false"
  LitNull -> "null"

-- | Escapes the characters that can appear in generated SQL. Formatted queries
-- | are single-line ASCII-plus-user-literals, so the JSON control-character
-- | escapes that matter are the ones handled here.
jsonString :: String -> String
jsonString s = "\"" <> escaped <> "\""
  where
  escaped =
    replace "\\" "\\\\"
      >>> replace "\"" "\\\""
      >>> replace "\n" "\\n"
      >>> replace "\r" "\\r"
      >>> replace "\t" "\\t"
      $ s

  replace from to =
    String.replaceAll (String.Pattern from) (String.Replacement to)
