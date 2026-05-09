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

## Modules

| Module | Contents |
|---|---|
| `Sqld.Core` | Core types: `Query`, `Expr`, `Literal`, `SelectExpr`, `emptyQuery` |
| `Sqld.Expr` | Expression constructors, literals, operators, logical combinators |
| `Sqld.Select` | SELECT query builders and select-list helpers |
| `Sqld.Format` | `format` and `formatInline` |

## API

### Building a query

Start with `emptyQuery` and pipe through helpers from `Sqld.Select`:

| Function | Description |
|---|---|
| `select :: Array SelectExpr -> Query -> Query` | Set the SELECT list |
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
| `like` | `like (col "email") "%@acme.com"` | `"email" LIKE $1` |

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

## License

MIT — see [LICENSE](LICENSE).
