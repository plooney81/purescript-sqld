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
import Example.Cookbook (Example, cookbook)
import Sqld.Format (format, formatInline, formatPretty)
import Test.Sqld.Corpus (CorpusEntry, corpus)
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
examplesJson = "[\n" <> intercalate ",\n" (map exampleJson cookbook) <> "\n]\n"

exampleJson :: Example -> String
exampleJson example =
  "  { \"name\": " <> jsonString example.name
    <> ", \"sql\": "
    <> jsonString formatted.sql
    <> ", \"params\": ["
    <> intercalate ", " (map literalJson formatted.params)
    <> "]"
    <> ", \"prettySql\": "
    <> jsonString (formatPretty example.statement)
    <> " }"
  where
  formatted = format example.statement

corpusJson :: String
corpusJson = "[\n" <> intercalate ",\n" (map entryJson corpus) <> "\n]\n"

entryJson :: CorpusEntry -> String
entryJson entry =
  "  { \"name\": " <> jsonString entry.name
    <> ", \"sql\": "
    <> jsonString formatted.sql
    <> ", \"params\": ["
    <> intercalate ", " (map literalJson formatted.params)
    <> "]"
    <> ", \"inlineSql\": "
    <> jsonString (formatInline entry.statement)
    <> " }"
  where
  formatted = format entry.statement
