-- | The hand-rolled JSON the test suite writes to `test-artifacts/`.
-- |
-- | Hand-rolled rather than pulled in via argonaut: the shapes are a few fields
-- | wide, and this keeps the test suite's dependency footprint small.
module Test.Sqld.Json
  ( jsonString
  , jsonInt
  , literalJson
  , jsonArray
  , jsonObject
  ) where

import Prelude

import Data.Foldable (intercalate)
import Data.String as String
import Data.Tuple (Tuple(..))
import Sqld.Core (Literal(..))

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

jsonInt :: Int -> String
jsonInt = show

literalJson :: Literal -> String
literalJson = case _ of
  LitInt n -> show n
  LitNumber n -> show n
  LitString s -> jsonString s
  LitBoolean b -> if b then "true" else "false"
  LitNull -> "null"

jsonArray :: Array String -> String
jsonArray xs = "[" <> intercalate ", " xs <> "]"

-- | An object from already-encoded values, so a caller mixes strings, numbers
-- | and nested arrays without a `Json` type standing between them.
jsonObject :: Array (Tuple String String) -> String
jsonObject fields = "{ " <> intercalate ", " (map field fields) <> " }"
  where
  field (Tuple k v) = jsonString k <> ": " <> v
