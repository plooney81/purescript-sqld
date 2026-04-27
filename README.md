# purescript-sqld

[![CI](https://github.com/plooney81/purescript-sqld/actions/workflows/ci.yml/badge.svg)](https://github.com/plooney81/purescript-sqld/actions/workflows/ci.yml)

A PostgreSQL SQL query builder for PureScript, inspired by [HoneySQL](https://github.com/seancorfield/honeysql). Build queries as plain data, compose them with functions, format them to a parameterised SQL string.

## Design

- **PostgreSQL only** — ships fast, does one thing well
- **Pure formatting** — `format` has no `Effect`; param state is explicitly threaded
- **No string interpolation** — literals become numbered params (`$1`, `$2`, …) automatically
- **Composable builders** — every helper is `Query -> Query`; chain with `#` or `>>>`
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
import Sqld.Builder
import Sqld.Core (emptyQuery)
import Sqld.Format (format)

-- SELECT "id", "name" FROM "users" WHERE "id" = $1
query = format $ emptyQuery
  # select [s (col "id"), s (col "name")]
  # from "users"
  # where_ (col "id" .== int 42)

-- { sql: "SELECT \"id\", \"name\" FROM \"users\" WHERE \"id\" = $1"
-- , params: [LitInt 42] }
```

Pass `sql` and `params` directly to your PostgreSQL driver (e.g. `node-postgres`):

```javascript
await pool.query(query.sql, query.params);
```

## API

### Building a query

Start with `emptyQuery` and pipe through helpers:

| Function | Description |
|---|---|
| `select :: Array SelectExpr -> Query -> Query` | SET the SELECT list |
| `from :: String -> Query -> Query` | FROM table |
| `fromAs :: String -> String -> Query -> Query` | FROM with alias |
| `where_ :: Expr -> Query -> Query` | Add WHERE condition (ANDs with any existing) |
| `innerJoin :: String -> Expr -> Query -> Query` | INNER JOIN |
| `leftJoin :: String -> Expr -> Query -> Query` | LEFT JOIN |
| `leftJoinAs :: String -> String -> Expr -> Query -> Query` | LEFT JOIN with alias |
| `groupBy :: Array Expr -> Query -> Query` | GROUP BY |
| `having :: Expr -> Query -> Query` | HAVING |
| `orderBy :: Array OrderExpr -> Query -> Query` | ORDER BY |
| `limit :: Int -> Query -> Query` | LIMIT |
| `offset :: Int -> Query -> Query` | OFFSET |
| `mergeQueries :: Query -> Query -> Query` | Merge two queries; right side wins for scalars |

### Expressions

| Constructor | Example | SQL |
|---|---|---|
| `col :: String -> Expr` | `col "name"` | `"name"` |
| `tcol :: String -> String -> Expr` | `tcol "u" "id"` | `"u"."id"` |
| `int / str / num / bool` | `int 42` | `$1` |
| `null_` | `null_` | `$1` (NULL param) |
| `raw :: String -> Expr` | `raw "NOW()"` | `NOW()` |
| `.== .!= .< .<= .> .>=` | `col "age" .> int 18` | `"age" > $1` |
| `and_ :: Array Expr -> Expr` | `and_ [e1, e2]` | `(e1 AND e2)` |
| `or_ :: Array Expr -> Expr` | `or_ [e1, e2]` | `(e1 OR e2)` |
| `not_ :: Expr -> Expr` | `not_ e` | `NOT e` |
| `isNull / isNotNull` | `isNull (col "deleted_at")` | `"deleted_at" IS NULL` |
| `in_ :: Expr -> Array Expr -> Expr` | `in_ (col "id") [int 1, int 2]` | `"id" IN ($1, $2)` |
| `notIn` | `notIn (col "s") [str "x"]` | `"s" NOT IN ($1)` |
| `between_` | `between_ (col "n") (int 1) (int 10)` | `"n" BETWEEN $1 AND $2` |
| `like` | `like (col "email") "%@acme.com"` | `"email" LIKE $1` |

### SELECT expressions

| Constructor | Example | SQL |
|---|---|---|
| `star` | `select [star]` | `SELECT *` |
| `s :: Expr -> SelectExpr` | `s (col "name")` | `"name"` |
| `as :: Expr -> String -> SelectExpr` | `as (raw "COUNT(*)") "n"` | `COUNT(*) AS "n"` |
| `starFrom :: String -> SelectExpr` | `starFrom "u"` | `"u".*` |

### ORDER BY

```purescript
orderBy [asc (col "name"), desc (col "created_at")]
-- ORDER BY "name" ASC, "created_at" DESC
```

## Composing fragments

The real power is in building reusable query pieces and merging them:

```purescript
baseQuery :: Query -> Query
baseQuery = select [star] >>> from "users"

activeOnly :: Query -> Query
activeOnly = where_ (col "active" .== bool true)

paginate :: Int -> Int -> Query -> Query
paginate size page = limit size >>> offset (size * page)

-- Compose:
result = format $ baseQuery >>> activeOnly >>> paginate 20 0 $ emptyQuery
```

Or use `mergeQueries` to combine fragments built independently:

```purescript
adminFilter = emptyQuery # where_ (col "role" .== str "admin")
result = format (mergeQueries baseQuery adminFilter)
```

## License

MIT — see [LICENSE](LICENSE).
