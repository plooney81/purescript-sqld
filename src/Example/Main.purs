module Example.Main where

import Prelude

import Data.Maybe (Maybe(..), maybe)
import Data.Newtype (class Newtype, unwrap)
import Effect (Effect)
import Effect.Console (log)
import Sqld.Core (Query, emptyQuery)
import Sqld.Expr (bool, col, like, str, (.==))
import Sqld.Format (formatPretty)
import Sqld.Select (cols, desc, from, limit, offset, orderBy, select, where_)

-- ---------------------------------------------------------------------------
-- Reusable query fragments
-- ---------------------------------------------------------------------------

activeUsers :: Query -> Query
activeUsers = select (cols ["id", "email", "role", "created_at"])
  >>> from "users"
  >>> where_ (col "active" .== bool true)

byRole :: String -> Query -> Query
byRole role = where_ $ col "role" .== str role

newtype Domain = Domain String
derive instance Newtype Domain _

byEmailDomain :: Domain -> Query -> Query
byEmailDomain domain' = where_ (like (col "email") ("%" <> domain))
  where
  domain = unwrap domain'

newestFirst :: Query -> Query
newestFirst = orderBy [desc (col "created_at")]

paginate :: Int -> Int -> Query -> Query
paginate pageSize page = limit pageSize >>> offset (pageSize * page)

-- ---------------------------------------------------------------------------
-- Compose from optional request params — no string wrangling, no WHERE 1=1
-- ---------------------------------------------------------------------------

buildUserQuery :: Maybe String -> Maybe Domain -> Int -> String
buildUserQuery mRole mDomain page =
  activeUsers
  >>> maybe identity byRole        mRole
  >>> maybe identity byEmailDomain mDomain
  >>> newestFirst
  >>> paginate 20 page
  >>> formatPretty
  $ emptyQuery

-- ---------------------------------------------------------------------------
-- Run it
-- ---------------------------------------------------------------------------

main :: Effect Unit
main = do
  log "-- All active users, page 0"
  log $ buildUserQuery Nothing Nothing 0

  log "\n-- Admins only, page 0"
  log $ buildUserQuery (Just "admin") Nothing 0

  log "\n-- Users from example.com, page 2"
  log $ buildUserQuery Nothing (Just $ Domain "@example.com") 2

  log "\n-- Admins from example.com, page 1"
  log $ buildUserQuery (Just "admin") (Just $ Domain "@example.com") 1
