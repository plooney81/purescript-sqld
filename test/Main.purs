module Test.Main where

import Prelude
import Effect (Effect)
import Effect.Aff (launchAff_)
import Test.Spec.Reporter (consoleReporter)
import Test.Spec.Runner (runSpec)
import Test.Sqld.CorpusEmit (emitCorpusJson, emitExamplesJson)
import Test.Sqld.CorpusSpec (corpusSpec)
import Test.Sqld.DeleteSpec (deleteSpec)
import Test.Sqld.ExprSpec (exprSpec)
import Test.Sqld.FormatSpec (formatSpec)
import Test.Sqld.InsertSpec (insertSpec)
import Test.Sqld.SelectSpec (selectSpec)
import Test.Sqld.UpdateSpec (updateSpec)

main :: Effect Unit
main = do
  -- Emitted before the suite runs so `scripts/validate-sql.mjs` has a corpus to
  -- replay even when a golden test fails.
  emitCorpusJson
  emitExamplesJson
  launchAff_ $ runSpec [consoleReporter] do
    exprSpec
    selectSpec
    formatSpec
    insertSpec
    updateSpec
    deleteSpec
    corpusSpec
