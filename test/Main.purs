module Test.Main where

import Prelude
import Effect (Effect)
import Effect.Aff (launchAff_)
import Test.Spec.Reporter (consoleReporter)
import Test.Spec.Runner (runSpec)
import Test.Sqld.ExprSpec (exprSpec)
import Test.Sqld.FormatSpec (formatSpec)
import Test.Sqld.SelectSpec (selectSpec)

main :: Effect Unit
main = launchAff_ $ runSpec [consoleReporter] do
  exprSpec
  selectSpec
  formatSpec
