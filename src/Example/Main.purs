-- | Runs every cookbook example and prints the SQL it produces.
-- |
-- |     spago run
-- |
-- | The same examples are rendered into `EXAMPLES.md` by
-- | `scripts/build-examples.mjs` and validated against PostgreSQL by the
-- | corpus harness.
module Example.Main where

import Prelude

import Data.Foldable (for_)
import Effect (Effect)
import Effect.Console (log)
import Example.Cookbook (cookbook)
import Sqld.Format (formatPretty)

main :: Effect Unit
main = for_ cookbook \example -> do
  log ("-- " <> example.name)
  log (formatPretty example.query)
  log ""
