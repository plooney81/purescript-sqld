module Test.Main where

import Prelude
import Effect (Effect)
import Effect.Aff (launchAff_)
import Test.Spec.Reporter (consoleReporter)
import Test.Spec.Runner (runSpec)
import Test.Sqld.CorpusEmit (emitCorpusJson)
import Test.Sqld.CorpusSpec (corpusSpec)
import Test.Sqld.ExprSpec (exprSpec)
import Test.Sqld.FormatSpec (formatSpec)
import Test.Sqld.SelectSpec (selectSpec)

main :: Effect Unit
main = do
  -- Emitted before the suite runs so `scripts/validate-sql.mjs` has a corpus to
  -- replay even when a golden test fails.
  emitCorpusJson
  launchAff_ $ runSpec [consoleReporter] do
    exprSpec
    selectSpec
    formatSpec
    corpusSpec
