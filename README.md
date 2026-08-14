# purescript-sqld

[![CI](https://github.com/plooney81/purescript-sqld/actions/workflows/ci.yml/badge.svg)](https://github.com/plooney81/purescript-sqld/actions/workflows/ci.yml)

A PostgreSQL SQL query builder for PureScript, inspired by [HoneySQL](https://github.com/seancorfield/honeysql). Build queries as plain data, compose them with functions, format them to a parameterised SQL string.

## Design

- **PostgreSQL only** — ships fast, does one thing well
- **Pure formatting** — `format` has no `Effect`; param state is explicitly threaded
- **No string interpolation** — literals become numbered params (`$1`, `$2`, …) automatically
- **Composable builders** — every helper is `Query -> Query`; chain with `#` or `>>>`
- **Explicit select list** — no implicit `SELECT *`; use `select [star]` when you want it
- **`raw` escape hatch** — opt out of quoting for unsupported SQL fragments

## Installation

Once published to the PureScript registry:

```
spago install sqld
```

Until then, add a path dependency in your `spago.yaml`:

```yaml
workspace:
  extraPackages:
    sqld:
      path: ../purescript-sqld
```

## Quick start

```purescript
import Sqld.Core (emptyQuery)
import Sqld.Expr
import Sqld.Format (format)
import Sqld.Select

-- SELECT "id", "name" FROM "users" WHERE "id" = $1
query = format $ emptyQuery
  # select (cols ["id", "name"])
  # from "users"
  # where_ (col "id" .== int 42)

-- { sql: "SELECT \"id\", \"name\" FROM \"users\" WHERE \"id\" = $1"
-- , params: [LitInt 42] }
```

Pass `sql` and `params` directly to your PostgreSQL driver (e.g. `node-postgres`):

```javascript
await pool.query(query.sql, query.params);
```

## Examples

**[EXAMPLES.md](EXAMPLES.md)** is a worked cookbook — filtering, joins,
aggregation, subqueries, derived tables, composing fragments from optional
parameters, and when to reach for `raw`.

It is generated from [`src/Example/Cookbook.purs`](src/Example/Cookbook.purs),
and every example is replayed against a live PostgreSQL server by the
validation harness. An example that no longer compiles, or that PostgreSQL
would reject, fails CI. Run them yourself with `spago run`.

## Modules

| Module | Contents |
|---|---|
| `Sqld.Core` | Core types: `Query`, `Expr`, `Literal`, `SelectExpr`, `emptyQuery` |
| `Sqld.Expr` | Expression helpers over the generic AST nodes — operators, literals, functions, subqueries |
| `Sqld.Select` | SELECT query builders and select-list helpers |
| `Sqld.Format` | `format`, `formatInline`, `formatPretty` |

## API

### Building a query

Start with `emptyQuery` and pipe through helpers from `Sqld.Select`:

| Function | Description |
|---|---|
| `select :: Array SelectExpr -> Query -> Query` | Append to the SELECT list |
| `from :: String -> Query -> Query` | FROM table |
| `fromAs :: String -> String -> Query -> Query` | FROM with alias |
| `fromSub :: Query -> String -> Query -> Query` | FROM a derived table (subquery + alias) |
| `where_ :: Expr -> Query -> Query` | Add WHERE condition (ANDs with any existing) |
| `innerJoin` / `leftJoin` / `rightJoin` / `fullJoin` | `:: String -> Expr -> Query -> Query` |
| `innerJoinAs` / `leftJoinAs` / `rightJoinAs` / `fullJoinAs` | `:: String -> String -> Expr -> Query -> Query` |
| `joinOn :: JoinType -> Relation -> Expr -> Query -> Query` | General form; use it to join a derived table |
| `groupBy :: Array Expr -> Query -> Query` | GROUP BY |
| `having :: Expr -> Query -> Query` | HAVING |
| `orderBy :: Array OrderExpr -> Query -> Query` | ORDER BY |
| `limit :: Int -> Query -> Query` | LIMIT |
| `offset :: Int -> Query -> Query` | OFFSET |
| `mergeQueries :: Query -> Query -> Query` | Merge two queries; right side wins for scalars |

### SELECT list helpers

From `Sqld.Select`:

| Constructor | Example | SQL |
|---|---|---|
| `star` | `select [star]` | `SELECT *` |
| `cols :: Array String -> Array SelectExpr` | `cols ["id", "name"]` | `"id", "name"` |
| `expr :: Expr -> SelectExpr` | `expr (tcol "u" "id")` | `"u"."id"` |
| `as :: Expr -> String -> SelectExpr` | `as (raw "COUNT(*)") "n"` | `COUNT(*) AS "n"` |
| `colAs :: String -> String -> SelectExpr` | `colAs "created_at" "ts"` | `"created_at" AS "ts"` |
| `tcolAs :: String -> String -> String -> SelectExpr` | `tcolAs "u" "created_at" "ts"` | `"u"."created_at" AS "ts"` |
| `starFrom :: String -> SelectExpr` | `starFrom "u"` | `"u".*` |

### Expressions

From `Sqld.Expr`:

| Constructor | Example | SQL |
|---|---|---|
| `col :: String -> Expr` | `col "name"` | `"name"` |
| `tcol :: String -> String -> Expr` | `tcol "u" "id"` | `"u"."id"` |
| `int / str / num / bool` | `int 42` | `$1` |
| `null` | `null` | `$1` (NULL param) |
| `raw :: String -> Expr` | `raw "NOW()"` | `NOW()` |
| `.== .!= .< .<= .> .>=` | `col "age" .> int 18` | `"age" > $1` |
| `and :: Array Expr -> Expr` | `and [e1, e2]` | `(e1 AND e2)` |
| `or :: Array Expr -> Expr` | `or [e1, e2]` | `(e1 OR e2)` |
| `not :: Expr -> Expr` | `not e` | `NOT e` |
| `isNull / isNotNull` | `isNull (col "deleted_at")` | `"deleted_at" IS NULL` |
| `in_ :: Expr -> Array Expr -> Expr` | `in_ (col "id") [int 1, int 2]` | `"id" IN ($1, $2)` |
| `notIn` | `notIn (col "s") [str "x"]` | `"s" NOT IN ($1)` |
| `between` | `between (col "n") (int 1) (int 10)` | `"n" BETWEEN $1 AND $2` |
| `like / ilike` | `like (col "email") "%@acme.com"` | `"email" LIKE $1` |
| `notLike / notILike` | `notLike (col "email") "%@spam.com"` | `"email" NOT LIKE $1` |

### Generic nodes

The AST keeps only a handful of expression constructors. `App`, `BinOp`, `Cast`
and `Sub` cover most of PostgreSQL's expression grammar between them, so a
feature usually needs no new AST node — and anything without a named helper is
still reachable without falling back to `raw`:

| Constructor | Example | SQL |
|---|---|---|
| `app :: String -> Array Expr -> Expr` | `app "LOWER" [col "email"]` | `LOWER("email")` |
| `binOp :: String -> Expr -> Expr -> Expr` | `binOp "@>" (col "tags") (raw "ARRAY['a']")` | `"tags" @> ARRAY['a']` |
| `unary :: String -> Expr -> Expr` | `unary "-" (col "n")` | `- "n"` |
| `postfix :: String -> Expr -> Expr` | `postfix "IS TRUE" (col "ok")` | `"ok" IS TRUE` |
| `cast :: Expr -> String -> Expr` | `cast (col "id") "text"` | `"id"::text` |
| `row :: Array Expr -> Expr` | `row [int 1, int 2]` | `(1, 2)` |
| `sub :: Query -> Expr` | `sub totals` | `(SELECT …)` |
| `exists / notExists` | `exists orders` | `EXISTS (SELECT …)` |
| `inSub / notInSub` | `inSub (col "id") orders` | `"id" IN (SELECT …)` |

Common aggregates and functions are provided as one-line wrappers over `app`:
`count`, `countStar`, `sum_`, `avg`, `min_`, `max_`, `coalesce`, `lower`,
`upper`.

### Derived tables

A subquery in `FROM`. The alias is a plain `String` rather than a `Maybe`,
because PostgreSQL rejects a `FROM` subquery without one:

```purescript
recent = emptyQuery
  # select [star]
  # from "orders"
  # where_ (col "status" .== str "paid")

emptyQuery
  # select [starFrom "recent"]
  # fromSub recent "recent"
  # where_ (tcol "recent" "total" .> int 100)
-- SELECT "recent".* FROM (SELECT * FROM "orders" WHERE "status" = $1) AS "recent"
--   WHERE "recent"."total" > $2
```

Parameters are numbered in the order they appear in the emitted SQL, so a
derived table's bindings come before the outer query's. Use `joinOn` with
`derived` to join against one:

```purescript
emptyQuery
  # select [star]
  # fromAs "users" "u"
  # joinOn InnerJoin (derived totals "t") (tcol "u" "id" .== tcol "t" "user_id")
```

### Operator precedence

`format` follows PostgreSQL's precedence table and brackets only where the
meaning depends on it:

```purescript
binOp "*" (binOp "+" (col "age") (int 1)) (int 2)
-- ("age" + 1) * 2      -- bracketed: + binds looser than *

binOp "+" (col "a") (binOp "*" (col "b") (int 2))
-- "a" + "b" * 2        -- not bracketed: precedence already agrees

binOp "-" (col "a") (binOp "-" (col "b") (col "c"))
-- "a" - ("b" - "c")    -- bracketed: operators are left-associative
```

`raw` is exempt — its contents are opaque, so its bracketing is yours to get
right.

### ORDER BY

```purescript
orderBy [asc (col "name"), desc (col "created_at")]
-- ORDER BY "name" ASC, "created_at" DESC
```

### Formatting

```purescript
-- Parameterised — use this when passing to a driver
format :: Query -> { sql :: String, params :: Array Literal }

-- Inlined — use this for logging and debugging only, never for user input
formatInline :: Query -> String
```

## Composing fragments

```purescript
baseUsers :: Query -> Query
baseUsers = select [star] >>> from "users"

activeOnly :: Query -> Query
activeOnly = where_ (col "active" .== bool true)

paginate :: Int -> Int -> Query -> Query
paginate size page = limit size >>> offset (size * page)

result = format $ baseUsers >>> activeOnly >>> paginate 20 0 $ emptyQuery
-- SELECT * FROM "users" WHERE "active" = $1 LIMIT 20 OFFSET 0
```

Use `mergeQueries` to combine fragments built independently:

```purescript
adminFilter = emptyQuery # where_ (col "role" .== str "admin")
result = format (mergeQueries baseUsers adminFilter)
```

## Testing

`make help` lists every development target. The common ones:

```
make test            # golden tests; also emits test-artifacts/corpus.json
make validate        # tests + validate every query against real PostgreSQL
make validate-fast   # validate only, reusing the corpus and a warm container
```

### PostgreSQL validation

Golden tests prove sqld emits the string we expected. They do not prove
PostgreSQL accepts it. A second harness closes that gap by replaying every
corpus query against a real server.

`make validate` starts a throwaway Postgres container, runs `spago test`, then
feeds each query to the server with `PREPARE`. Because `PREPARE` runs full parse
*analysis* — not just a syntax check — the harness catches bad syntax, unknown
columns, invalid `GROUP BY`, and operator type mismatches. Both formatter
outputs are validated: the parameterised form from `format` and the debug form
from `formatInline`.

The container is left running between invocations, so `make validate-fast` is
the quick inner loop. `make pg-stop` tears it down.

To narrow a run, or to probe a query without adding a corpus entry:

```
make list                                    # corpus entry names
make validate-fast ONLY=join                 # just the entries matching "join"
make sql SQL='SELECT "u".* FROM "users" AS "u"'   # ad-hoc query
```

`make sql` is the fastest way to answer "will PostgreSQL accept this?" while
working on a formatter change.

Against an existing server, skip the Makefile and drive the validator directly:

```
DATABASE_URL=postgres://user:pass@host:5432/sqld_validate node scripts/validate-sql.mjs
```

It accepts the same `--only`, `--sql` and `--list` flags; `--help` lists them.

The schema in `test/fixtures/schema.sql` drops and recreates `public`, so the
validator refuses to run unless the database name looks disposable. Override
with `SQLD_ALLOW_ANY_DB=1` only if you are certain.

The same steps run in CI on every push and pull request.

### Coverage

`test/Sqld/Corpus.purs` is the single corpus both harnesses consume. Each entry
is tagged with the AST constructors it exercises, and `Test.Sqld.CorpusSpec`
fails if any constructor in `Sqld.Core` has no entry — so a new feature cannot
ship without SQL that PostgreSQL has actually accepted. Adding a constructor
makes the tagging functions non-exhaustive, which the compiler reports, and the
new tag then fails the coverage assertion until a corpus entry exists.

Every table and column the corpus references must exist in
`test/fixtures/schema.sql`.

## License

MIT — see [LICENSE](LICENSE).
