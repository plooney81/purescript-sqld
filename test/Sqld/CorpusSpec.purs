module Test.Sqld.CorpusSpec where

import Prelude

import Data.Array (length, nub) as Array
import Data.Foldable (for_)
import Data.String as String
import Sqld.Format (format, formatInline, formatInsert, formatInsertInline, formatUpdateStmt, formatUpdateInline)
import Test.Sqld.Corpus (corpus, insertCorpus, updateCorpus, missingTags)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (shouldEqual, shouldNotEqual)

corpusSpec :: Spec Unit
corpusSpec = describe "Sqld.Corpus" do

  describe "coverage" do
    -- If this fails, an AST constructor exists that no corpus entry builds,
    -- which means PostgreSQL never sees the SQL that constructor emits.
    it "exercises every required AST constructor" do
      missingTags `shouldEqual` []

    it "has a non-empty corpus" do
      Array.length corpus `shouldNotEqual` 0

    it "has unique entry names" do
      let names = map _.name corpus
      Array.length (Array.nub names) `shouldEqual` Array.length names

  describe "well-formedness" do
    for_ corpus \entry -> it entry.name do
      let
        formatted = format entry.query
        placeholders = Array.length (String.split (String.Pattern "$") formatted.sql) - 1

      formatted.sql `shouldNotEqual` ""
      formatInline entry.query `shouldNotEqual` ""
      -- Every bound literal must have a placeholder and vice versa; a mismatch
      -- means `format` would hand the driver the wrong number of parameters.
      placeholders `shouldEqual` Array.length formatted.params

  describe "insert well-formedness" do
    for_ insertCorpus \entry -> it entry.name do
      let
        formatted = formatInsert entry.insert
        placeholders = Array.length (String.split (String.Pattern "$") formatted.sql) - 1

      formatted.sql `shouldNotEqual` ""
      formatInsertInline entry.insert `shouldNotEqual` ""
      placeholders `shouldEqual` Array.length formatted.params

  describe "update well-formedness" do
    for_ updateCorpus \entry -> it entry.name do
      let
        formatted = formatUpdateStmt entry.update
        placeholders = Array.length (String.split (String.Pattern "$") formatted.sql) - 1

      formatted.sql `shouldNotEqual` ""
      formatUpdateInline entry.update `shouldNotEqual` ""
      placeholders `shouldEqual` Array.length formatted.params
