-- | Writes the generated queries to disk as JSON, so `scripts/validate-sql.mjs`
-- | can replay them against PostgreSQL alongside the corpus.
-- |
-- | The seed travels with them. A property test is only worth running if a
-- | failure can be reproduced, and the seed is the whole of what it takes:
-- | `Test.Sqld.Generate.generate` is pure, so `SQLD_GEN_SEED=<n>` regenerates
-- | exactly the queries that failed.
-- |
-- | Shrinking is opt-in for the same reason it is useful — it costs something.
-- | Emitting the candidates means formatting tens of thousands of queries that
-- | nothing will read on a run where nothing fails, so `SQLD_GEN_SHRINK=1`
-- | turns it on once there is a failure to shrink.
module Test.Sqld.GenerateEmit
  ( generatedPath
  , GenSettings
  , readSettings
  , generatedJson
  , emitGeneratedJson
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (intercalate)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Node.Encoding (Encoding(..))
import Node.FS.Perms (permsAll)
import Node.FS.Sync (mkdir', writeTextFile)
import Node.Process (lookupEnv)
import Random.LCG (Seed, mkSeed, randomSeed, unSeed)
import Sqld.Core (Query)
import Sqld.Format (format, formatInline)
import Test.Sqld.Generate (generate, shrinkClosure)
import Test.Sqld.Json (jsonArray, jsonInt, jsonObject, jsonString, literalJson)

generatedDir :: String
generatedDir = "test-artifacts"

generatedPath :: String
generatedPath = generatedDir <> "/generated.json"

type GenSettings =
  { seed :: Seed
  , count :: Int
  -- | How many shrink candidates to emit per query, or `0` for none.
  , shrinks :: Int
  }

-- | Defaults chosen to be worth running on every build: a few hundred queries
-- | prepare in a couple of seconds when the validator batches them, which is
-- | small beside the corpus replay they run next to.
defaultCount :: Int
defaultCount = 200

defaultShrinks :: Int
defaultShrinks = 60

readSettings :: Effect GenSettings
readSettings = do
  seed <- envInt "SQLD_GEN_SEED" >>= case _ of
    Just n -> pure (mkSeed n)
    Nothing -> randomSeed
  count <- fromMaybe defaultCount <$> envInt "SQLD_GEN_COUNT"
  shrinking <- envFlag "SQLD_GEN_SHRINK"
  shrinks <- fromMaybe (if shrinking then defaultShrinks else 0) <$> envInt "SQLD_GEN_SHRINKS"
  pure { seed, count: max 0 count, shrinks: max 0 shrinks }

envInt :: String -> Effect (Maybe Int)
envInt name = (_ >>= Int.fromString) <$> lookupEnv name

envFlag :: String -> Effect Boolean
envFlag name = (_ == Just "1") <$> lookupEnv name

emitGeneratedJson :: Effect Unit
emitGeneratedJson = do
  settings <- readSettings
  mkdir' generatedDir { recursive: true, mode: permsAll }
  writeTextFile UTF8 generatedPath (generatedJson settings)

generatedJson :: GenSettings -> String
generatedJson settings =
  jsonObject
    [ Tuple "seed" (jsonInt (unSeed settings.seed))
    , Tuple "count" (jsonInt (Array.length queries))
    , Tuple "shrinks" (jsonInt settings.shrinks)
    , Tuple "entries" (indented (Array.mapWithIndex entry queries))
    ]
  where
  queries = generate settings.seed settings.count

  entry i q = jsonObject
    ( formJson ("generated-" <> show i) q
        <>
          if settings.shrinks == 0 then []
          else [ Tuple "shrinks" (jsonArray (map (jsonObject <<< formJson "shrink") (shrinkClosure settings.shrinks q))) ]
    )

  indented xs = "[\n    " <> intercalate ",\n    " xs <> "\n  ]"

-- | The three things the validator needs of a query: the parameterised SQL, the
-- | parameters it binds, and the inline form. Both forms are replayed, because
-- | a printer bug can live in either.
formJson :: String -> Query -> Array (Tuple String String)
formJson name q =
  [ Tuple "name" (jsonString name)
  , Tuple "sql" (jsonString formatted.sql)
  , Tuple "params" (jsonArray (map literalJson formatted.params))
  , Tuple "inlineSql" (jsonString (formatInline q))
  ]
  where
  formatted = format q
