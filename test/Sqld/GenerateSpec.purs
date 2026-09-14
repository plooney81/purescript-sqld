-- | What can be asserted about generated queries without a database.
-- |
-- | The real property — PostgreSQL accepts every one — needs a server, so
-- | `scripts/validate-sql.mjs` runs it. These are the checks that hold purely,
-- | and they earn their place by failing fast: a generator that has drifted
-- | from the fixture schema, or a formatter that binds the wrong number of
-- | parameters, is caught here in milliseconds rather than in a replay that
-- | needs Docker.
module Test.Sqld.GenerateSpec (generateSpec) where

import Prelude

import Data.Array as Array
import Data.Foldable (for_)
import Data.Int (toNumber)
import Data.String as String
import Effect.Class (liftEffect)
import Node.Encoding (Encoding(..))
import Node.FS.Sync (readTextFile)
import Random.LCG (mkSeed)
import Sqld.Core (Query)
import Sqld.Format (format, formatInline)
import Test.Sqld.Fixture (RawTable, fixtureSchema, parseSchemaSql, schemaPath, typeName)
import Test.Sqld.Generate (generate, shrinkClosure)
import Test.Spec (Spec, describe, it)
import Test.Spec.Assertions (fail, shouldEqual)

-- | A fixed seed, so the suite is deterministic. The randomised run is the one
-- | the validator does; this is a regression net over a sample large enough to
-- | reach every shape.
sample :: Array Query
sample = generate (mkSeed 20240913) 300

sampleSql :: Array String
sampleSql = map formatInline sample

-- | `Test.Sqld.Fixture` as the SQL file would spell it.
expectedSchema :: Array RawTable
expectedSchema = map table fixtureSchema
  where
  table t = { name: t.name, columns: map column t.columns }
  column c = { name: c.name, ty: typeName c.ty }

-- | Shapes the generator is meant to reach, and a fragment of SQL that only
-- | that shape produces. A weighting change that quietly stops producing joins
-- | would otherwise leave every other check here passing.
shapes :: Array { name :: String, needle :: String }
shapes =
  [ { name: "a join", needle: " JOIN " }
  , { name: "a subquery", needle: "(SELECT " }
  , { name: "GROUP BY", needle: "GROUP BY" }
  , { name: "a set operation", needle: "UNION" }
  , { name: "a CTE", needle: "WITH " }
  , { name: "a window function", needle: " OVER (" }
  , { name: "DISTINCT", needle: "DISTINCT" }
  , { name: "a locking clause", needle: "FOR UPDATE" }
  , { name: "an aggregate FILTER", needle: "FILTER (WHERE" }
  , { name: "a window frame", needle: "ROWS " }
  ]

generateSpec :: Spec Unit
generateSpec = describe "Test.Sqld.Generate" do

  describe "fixture schema" do
    -- The generators draw every name from `Test.Sqld.Fixture`, and PostgreSQL
    -- checks them against `schema.sql`. If the two drift, every generated query
    -- fails for a reason that says nothing about sqld.
    it "matches test/fixtures/schema.sql" do
      sql <- liftEffect (readTextFile UTF8 schemaPath)
      parseSchemaSql sql `shouldEqual` expectedSchema

  describe "the sample" do
    -- A generator that collapsed onto a handful of shapes would still pass
    -- every other check here while testing almost nothing.
    it "is not degenerate" do
      let distinct = Array.length (Array.nub sampleSql)
      when (toNumber distinct < 0.9 * toNumber (Array.length sample)) do
        fail $ "only " <> show distinct <> " distinct queries in a sample of " <> show (Array.length sample)

    it "reaches every query shape" do
      for_ shapes \shape ->
        unless (Array.any (String.contains (String.Pattern shape.needle)) sampleSql) do
          fail $ "no generated query used " <> shape.name

  describe "formatting" do
    it "binds one parameter per placeholder" do
      for_ sample \q -> do
        let
          formatted = format q
          placeholders = Array.length (String.split (String.Pattern "$") formatted.sql) - 1
        placeholders `shouldEqual` Array.length formatted.params

    it "leaves no placeholder behind when inlining" do
      for_ sampleSql \sql ->
        when (String.contains (String.Pattern "$") sql) do
          fail $ "formatInline left a placeholder: " <> sql

    it "never emits an empty query" do
      for_ sample \q -> do
        when (String.null (formatInline q)) (fail "formatInline produced an empty string")
        when (String.null (format q).sql) (fail "format produced an empty string")

  describe "shrinking" do
    -- The validator reports the smallest candidate that still fails, so a
    -- candidate no smaller than the original would be reported in its place
    -- without being any easier to read.
    it "only proposes smaller queries" do
      for_ (Array.take 50 sample) \q ->
        for_ (shrinkClosure 20 q) \candidate ->
          when (String.length (formatInline candidate) >= String.length (formatInline q)) do
            fail $ "shrink is not smaller:\n  " <> formatInline q <> "\n  " <> formatInline candidate
