-- Fixture schema for the PostgreSQL validation harness.
--
-- Every table and column referenced by `test/Sqld/Corpus.purs` must exist here.
-- Because the harness validates with PREPARE, PostgreSQL runs full parse
-- analysis: unknown columns, ambiguous references, invalid GROUP BY and
-- operator type mismatches all surface as failures. That is stronger than a
-- syntax check, and it is why the schema is worth maintaining.
--
-- WARNING: this file drops and recreates the `public` schema. It is only ever
-- applied to a throwaway validation database — `scripts/validate-sql.mjs`
-- refuses to run against a database whose name does not look disposable.

DROP SCHEMA IF EXISTS public CASCADE;
CREATE SCHEMA public;

CREATE TABLE users
  ( id          integer PRIMARY KEY
  , name        text NOT NULL
  , email       text
  , active      boolean NOT NULL DEFAULT true
  , age         integer
  , score       numeric
  , department  text
  , created_at  timestamptz NOT NULL DEFAULT now()
  );

CREATE TABLE profiles
  ( id       integer PRIMARY KEY
  , user_id  integer NOT NULL REFERENCES users (id)
  , bio      text
  );

CREATE TABLE orders
  ( id        integer PRIMARY KEY
  , user_id   integer NOT NULL REFERENCES users (id)
  , status    text NOT NULL
  , total     numeric NOT NULL
  , placed_at timestamptz NOT NULL DEFAULT now()
  );

CREATE TABLE articles
  ( id           integer PRIMARY KEY
  , title        text NOT NULL
  , published_at timestamptz
  );
