-- | Schema-aware random query generation.
-- |
-- | The corpus proves the queries we thought of are valid. This module tries
-- | the ones we did not: it builds `Query` values at random, and
-- | `scripts/validate-sql.mjs` asserts PostgreSQL accepts every one. The
-- | precedence printer is the reason it exists — its bug surface is
-- | combinatorial, and hand-written cases are exactly the ones a human already
-- | considered.
-- |
-- | Two properties shape every generator here.
-- |
-- | **Schema-aware.** Random identifiers would fail parse analysis for reasons
-- | that say nothing about sqld, so table and column names come from
-- | `Test.Sqld.Fixture` and nowhere else. Every relation carries an alias and
-- | every column reference is qualified with it, which is what keeps a self-join
-- | from turning into an ambiguity error.
-- |
-- | **Well-typed and well-formed by construction.** Generation is driven by
-- | `SqlType`, so a comparison never straddles two incomparable types, and the
-- | query shapes are generated whole rather than assembled from independent
-- | choices — because SQL's validity rules run between clauses. `DISTINCT ON`
-- | constrains `ORDER BY`, `GROUP BY` constrains the select list, and
-- | `FOR UPDATE` is rejected outright on half of them. A generator that made
-- | those choices independently would spend its budget rediscovering
-- | PostgreSQL's rulebook instead of testing the printer.
-- |
-- | Two AST nodes are deliberately unreachable from here. `Raw` is opaque SQL,
-- | so there is nothing to generate but a string PostgreSQL would reject, and
-- | `Default` is only legal in an `INSERT`. Both stay the corpus's job, as do
-- | `Insert`, `Update` and `Delete` themselves.
module Test.Sqld.Generate
  ( genQuery
  , generate
  , shrinkQuery
  , shrinkExpr
  , shrinkClosure
  ) where

import Prelude

import Data.Array as Array
import Data.Array.NonEmpty as NEA
import Data.Foldable (all, any)
import Data.Int (toNumber)
import Data.Maybe (Maybe(..), fromMaybe, isNothing, maybe)
import Data.String as String
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..), fst, snd)
import Random.LCG (Seed)
import Sqld.Core (Cte(..), Distinct(..), Expr(..), Frame, FrameBound(..), FrameMode(..), GroupingElement(..), Join, JoinCondition(..), JoinType(..), Literal(..), LockStrength(..), LockWait(..), Locking, NullOrder(..), OrderDir(..), OrderExpr, QuantOp(..), Query, Relation(..), SelectExpr(..), SetOp(..), SetOperation(..), Window, emptyQuery)
import Sqld.Format (formatInline)
import Test.QuickCheck.Gen (Gen, chooseInt, elements, evalGen, frequency, shuffle, uniform, vectorOf)
import Test.Sqld.Fixture (Column, SqlType(..), Table, fixtureSchema, typeName)

-- ---------------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------------

-- | `n` queries from `seed`. Pure, so the same seed always yields the same
-- | queries — which is what makes a failure reproducible from the seed printed
-- | beside it.
generate :: Seed -> Int -> Array Query
generate seed n = evalGen (vectorOf n genQuery) { newSeed: seed, size: 10 }

genQuery :: Gen Query
genQuery = do
  fuel <- chooseInt 1 3
  weighted (genSimple fuel)
    [ Tuple 6.0 (genSimple fuel)
    , Tuple 3.0 (genGrouped fuel)
    , Tuple 1.0 (genSetOp fuel)
    , Tuple 1.0 (genWithCte fuel)
    ]

-- ---------------------------------------------------------------------------
-- Gen helpers
-- ---------------------------------------------------------------------------

-- | Picks uniformly from `xs`, or runs `fallback` when there is nothing to pick
-- | from. Every use has a real empty case — a scope with no column of the type
-- | in hand, two relations with no column name in common — so the fallback is
-- | an ordinary path rather than an impossible one.
pickOr :: forall a. Gen a -> Array a -> Gen a
pickOr fallback = maybe fallback elements <<< NEA.fromArray

pick :: forall a. a -> Array a -> Gen a
pick x = elements <<< NEA.cons' x

weighted :: forall a. Gen a -> Array (Tuple Number (Gen a)) -> Gen a
weighted fallback = maybe fallback frequency <<< NEA.fromArray

chance :: Number -> Gen Boolean
chance p = (_ < p) <$> uniform

optional :: forall a. Number -> Gen a -> Gen (Maybe a)
optional p g = do
  yes <- chance p
  if yes then Just <$> g else pure Nothing

-- | Between `lo` and `hi` of `xs`, in a random order and never more than there
-- | are.
someOf :: forall a. Int -> Int -> Array a -> Gen (Array a)
someOf lo hi xs = do
  n <- chooseInt (min lo len) (min hi len)
  Array.take n <$> shuffle xs
  where
  len = Array.length xs

listOfBetween :: forall a. Int -> Int -> Gen a -> Gen (Array a)
listOfBetween lo hi g = chooseInt lo hi >>= flip vectorOf g

-- ---------------------------------------------------------------------------
-- Scope
-- ---------------------------------------------------------------------------

-- | One relation visible to the query being generated: what it is called here,
-- | and what columns it offers.
-- |
-- | `plain` records whether it is a bare table rather than a subquery or a CTE
-- | reference. PostgreSQL rejects `FOR UPDATE` on anything else, so the locking
-- | clause is generated only when every relation in scope is one.
type Rel = { alias :: String, columns :: Array Column, plain :: Boolean }

type Scope = Array Rel

-- | Every column in scope, paired with its type.
scopeColumns :: Scope -> Array (Tuple SqlType Expr)
scopeColumns scope = do
  rel <- scope
  column <- rel.columns
  pure (Tuple column.ty (Col { table: Just rel.alias, column: column.name }))

colsOfType :: Scope -> SqlType -> Array Expr
colsOfType scope ty = map snd (Array.filter ((_ == ty) <<< fst) (scopeColumns scope))

-- | Whether an expression can be written into two clauses and still match
-- | itself.
-- |
-- | `format` numbers each literal it meets from left to right, so an expression
-- | holding one is `$1` in the select list and `$7` in the `ORDER BY` — and
-- | PostgreSQL, comparing the two structurally, sees two different expressions.
-- | `DISTINCT` and `GROUP BY` both rest on that comparison, so both draw only
-- | from expressions this admits. Subqueries are excluded wholesale rather than
-- | searched for the literals they almost certainly contain.
literalFree :: Expr -> Boolean
literalFree = case _ of
  Lit _ -> false
  Sub _ -> false
  Col _ -> true
  Raw _ -> true
  Default -> true
  App _ xs -> all literalFree xs
  Row xs -> all literalFree xs
  And xs -> all literalFree xs
  Or xs -> all literalFree xs
  BinOp _ l r -> literalFree l && literalFree r
  Quantified _ _ l r -> literalFree l && literalFree r
  Unary _ e -> literalFree e
  Postfix _ e -> literalFree e
  Cast e _ -> literalFree e
  Between x lo hi -> literalFree x && literalFree lo && literalFree hi
  Filter agg predicate -> literalFree agg && literalFree predicate
  Over f w ->
    literalFree f
      && all literalFree w.partitionBy
      && all (literalFree <<< _.expr) w.orderBy

genTable :: Gen Table
genTable = pickOr (pure { name: "users", columns: [] }) fixtureSchema

allTypes :: Array SqlType
allTypes = [ TyInt, TyNum, TyText, TyBool, TyTime ]

genType :: Gen SqlType
genType = pick TyInt [ TyNum, TyText, TyBool, TyTime ]

-- | The types with a total order, so `<`, `BETWEEN` and `ORDER BY … USING`
-- | apply to them.
genOrderedType :: Gen SqlType
genOrderedType = pick TyInt [ TyNum, TyText, TyTime ]

-- ---------------------------------------------------------------------------
-- Literals
-- ---------------------------------------------------------------------------

-- | The words a `text` literal is drawn from. No quote, backslash or `$`: the
-- | first two would test the escaping rather than the printer, and a `$` inside
-- | a literal collides with the placeholder `formatInline` substitutes it into.
words :: Array String
words = [ "alpha", "beta", "gamma", "engineering", "paid", "pending", "a%", "%b%", "" ]

timestamps :: Array String
timestamps = [ "2024-01-01T00:00:00Z", "2020-06-30T12:34:56Z", "1999-12-31T23:59:59Z" ]

genLit :: SqlType -> Gen Literal
genLit TyInt = LitInt <$> chooseInt (-1000) 1000
genLit TyNum = (\n -> LitNumber (toNumber n / 100.0)) <$> chooseInt (-100000) 100000
genLit TyText = LitString <$> pickOr (pure "alpha") words
genLit TyBool = LitBoolean <$> chance 0.5
genLit TyTime = LitString <$> pickOr (pure "2024-01-01T00:00:00Z") timestamps

-- | A literal wearing its type.
-- |
-- | Bare literals are emitted as `$1`, and PostgreSQL cannot always infer a
-- | placeholder's type from context — `SELECT $1 IS NULL` has nothing to unify
-- | against. A cast settles it, so a generated literal is never the reason a
-- | query fails to prepare.
genTypedLit :: SqlType -> Gen Expr
genTypedLit ty = do
  nul <- chance 0.1
  l <- if nul then pure LitNull else genLit ty
  pure (Cast (Lit l) (typeName ty))

-- | An array literal, which is what makes `= ANY (…)` a comparison PostgreSQL
-- | accepts without a subquery on the right.
genArrayLit :: SqlType -> Gen Expr
genArrayLit ty = do
  elems <- listOfBetween 1 3 (genLit ty)
  pure (Cast (Lit (LitString (braced elems))) (typeName ty <> "[]"))
  where
  braced elems = "{" <> String.joinWith "," (map arrayElem elems) <> "}"

arrayElem :: Literal -> String
arrayElem (LitInt n) = show n
arrayElem (LitNumber n) = show n
arrayElem (LitBoolean b) = if b then "t" else "f"
arrayElem (LitString s) = if s == "" then "\"\"" else s
arrayElem LitNull = "NULL"

-- ---------------------------------------------------------------------------
-- Expressions
-- ---------------------------------------------------------------------------

-- | An expression of the given type over the given scope.
-- |
-- | Every expression this returns is *grounded*: somewhere inside it is a
-- | column reference or a cast literal, so PostgreSQL can always type it. That
-- | is why bare literals only ever appear beside a recursive call — as the
-- | right operand of `LIKE`, an element of an `IN` list, a `LIMIT` — and never
-- | as a node's only child.
genExpr :: Scope -> Int -> SqlType -> Gen Expr
genExpr scope fuel ty
  | fuel <= 0 = genAtom scope ty
  | otherwise = weighted atom (Array.cons (Tuple 3.0 atom) (composites scope fuel ty))
      where
      atom = genAtom scope ty

genAtom :: Scope -> SqlType -> Gen Expr
genAtom scope ty =
  weighted (genTypedLit ty)
    [ Tuple 6.0 (pickOr (genTypedLit ty) (colsOfType scope ty))
    , Tuple 1.0 (genTypedLit ty)
    ]

composites :: Scope -> Int -> SqlType -> Array (Tuple Number (Gen Expr))
composites scope fuel = case _ of
  TyBool -> boolOps scope fuel
  TyText -> textOps scope fuel
  TyTime -> timeOps scope fuel
  ty -> numberOps scope fuel ty

boolOps :: Scope -> Int -> Array (Tuple Number (Gen Expr))
boolOps scope fuel =
  [ Tuple 5.0 do
      t <- genOrderedType
      op <- pick "=" [ "<>", "<", "<=", ">", ">=" ]
      BinOp op <$> sub t <*> sub t
  , Tuple 2.0 do
      t <- genType
      op <- pick "IS NULL" [ "IS NOT NULL" ]
      Postfix op <$> sub t
  , Tuple 2.0 (Unary "NOT" <$> sub TyBool)
  , Tuple 2.5 (And <$> listOfBetween 2 3 (sub TyBool))
  , Tuple 2.0 (Or <$> listOfBetween 2 3 (sub TyBool))
  , Tuple 1.5 do
      t <- genOrderedType
      Between <$> sub t <*> sub t <*> sub t
  , Tuple 2.0 do
      op <- pick "LIKE" [ "ILIKE", "NOT LIKE", "NOT ILIKE" ]
      BinOp op <$> sub TyText <*> (Lit <<< LitString <$> pickOr (pure "%a%") words)
  , Tuple 1.5 do
      t <- genType
      op <- pick "IN" [ "NOT IN" ]
      BinOp op <$> sub t <*> (Row <$> listOfBetween 1 3 (sub t))
  , Tuple 1.0 do
      t <- genOrderedType
      quant <- pick Any [ All ]
      op <- pick "=" [ "<>", "<", ">" ]
      Quantified quant op <$> sub t <*> genArrayLit t
  , Tuple 1.0 do
      op <- pick "EXISTS" [ "NOT EXISTS" ]
      t <- genType
      Unary op <<< Sub <$> genScalarSub scope (fuel - 1) t
  , Tuple 1.0 do
      t <- genType
      op <- pick "IN" [ "NOT IN" ]
      l <- sub t
      BinOp op l <<< Sub <$> genScalarSub scope (fuel - 1) t
  ]
  where
  sub = genExpr scope (fuel - 1)

numberOps :: Scope -> Int -> SqlType -> Array (Tuple Number (Gen Expr))
numberOps scope fuel ty =
  [ Tuple 4.0 do
      op <- pick "+" [ "-", "*" ]
      BinOp op <$> sub ty <*> sub ty
  , Tuple 1.5 (Unary "-" <$> sub ty)
  , Tuple 1.5 (App "ABS" <<< Array.singleton <$> sub ty)
  , Tuple 1.5 do
      f <- pick "GREATEST" [ "LEAST" ]
      a <- sub ty
      b <- sub ty
      pure (App f [ a, b ])
  , Tuple 1.5 (App "COALESCE" <$> listOfBetween 2 3 (sub ty))
  -- `integer` and `numeric` cast to each other in either direction and always
  -- succeed. A cast from `text` would not: `'abc'::integer` is a runtime error,
  -- which is a failure about the literal rather than about the printer.
  , Tuple 1.0 (flip Cast (typeName ty) <$> sub (counterpart ty))
  , Tuple 1.0 (Sub <$> genScalarSub scope (fuel - 1) ty)
  ]
  where
  sub = genExpr scope (fuel - 1)
  counterpart TyInt = TyNum
  counterpart _ = TyInt

textOps :: Scope -> Int -> Array (Tuple Number (Gen Expr))
textOps scope fuel =
  [ Tuple 4.0 (BinOp "||" <$> sub TyText <*> sub TyText)
  , Tuple 2.5 do
      f <- pick "UPPER" [ "LOWER", "INITCAP", "TRIM", "MD5" ]
      App f <<< Array.singleton <$> sub TyText
  , Tuple 1.5 (App "COALESCE" <$> listOfBetween 2 3 (sub TyText))
  , Tuple 1.5 do
      t <- pick TyInt [ TyNum, TyBool, TyTime ]
      flip Cast (typeName TyText) <$> sub t
  , Tuple 1.0 (Sub <$> genScalarSub scope (fuel - 1) TyText)
  ]
  where
  sub = genExpr scope (fuel - 1)

timeOps :: Scope -> Int -> Array (Tuple Number (Gen Expr))
timeOps scope fuel =
  [ Tuple 2.0 (pure (App "NOW" []))
  , Tuple 1.5 do
      f <- pick "GREATEST" [ "LEAST" ]
      a <- sub TyTime
      b <- sub TyTime
      pure (App f [ a, b ])
  , Tuple 1.5 (App "COALESCE" <$> listOfBetween 2 3 (sub TyTime))
  , Tuple 1.5 do
      part <- pick "day" [ "month", "year", "hour" ]
      truncated part <$> sub TyTime
  , Tuple 1.0 (Sub <$> genScalarSub scope (fuel - 1) TyTime)
  ]
  where
  sub = genExpr scope (fuel - 1)
  truncated part e = App "DATE_TRUNC" [ Lit (LitString part), e ]

-- | A subquery in expression position: one column of the requested type, from
-- | one table, optionally correlated with the scope around it.
genScalarSub :: Scope -> Int -> SqlType -> Gen Query
genScalarSub outer fuel ty = do
  tbl <- genTable
  let inner = Array.snoc outer { alias: subAlias outer, columns: tbl.columns, plain: true }
  e <- genExpr inner (min fuel 1) ty
  predicate <- optional 0.6 (genExpr inner (min fuel 1) TyBool)
  pure emptyQuery
    { select = [ SelectExpr e ]
    , from = Just (Table tbl.name (Just (subAlias outer)))
    , where_ = predicate
    , limit = Just (Lit (LitInt 1))
    }

-- | Aliases are unique by construction rather than by a counter: a subquery's
-- | scope is strictly larger than the one it nests inside, and the relations a
-- | query names itself use a different prefix.
subAlias :: Scope -> String
subAlias scope = "s" <> show (Array.length scope)

-- ---------------------------------------------------------------------------
-- Aggregates and windows
-- ---------------------------------------------------------------------------

-- | An aggregate and the type it returns.
-- |
-- | `SUM` and `AVG` are called `numeric` rather than tracked exactly —
-- | `SUM(integer)` is `bigint` — because every use compares them against a
-- | literal, and PostgreSQL compares those two families without complaint.
genAggregate :: Scope -> Int -> Gen (Tuple SqlType Expr)
genAggregate scope fuel = do
  agg <- weighted (pure (Tuple TyInt countStar))
    [ Tuple 3.0 (pure (Tuple TyInt countStar))
    , Tuple 2.0 do
        t <- genType
        e <- genExpr scope fuel t
        pure (Tuple TyInt (App "COUNT" [ e ]))
    , Tuple 2.5 do
        t <- pick TyInt [ TyNum ]
        f <- pick "SUM" [ "AVG" ]
        e <- genExpr scope fuel t
        pure (Tuple TyNum (App f [ e ]))
    , Tuple 2.5 do
        t <- genOrderedType
        f <- pick "MIN" [ "MAX" ]
        e <- genExpr scope fuel t
        pure (Tuple t (App f [ e ]))
    , Tuple 1.0 do
        e <- genExpr scope fuel TyText
        pure (Tuple TyText (App "STRING_AGG" [ e, Lit (LitString ",") ]))
    ]
  filtered <- chance 0.2
  if filtered then do
    predicate <- genExpr scope (min fuel 1) TyBool
    pure (Tuple (fst agg) (Filter (snd agg) predicate))
  else pure agg

countStar :: Expr
countStar = App "COUNT" [ Raw "*" ]

-- | A window function and its window. Only aggregates and the ranking
-- | functions appear under `OVER`, because PostgreSQL rejects it on anything
-- | else.
genWindowFn :: Scope -> Int -> Gen (Tuple SqlType Expr)
genWindowFn scope fuel = do
  fn <- weighted (pure (Tuple TyInt (App "ROW_NUMBER" [])))
    [ Tuple 2.0 (pure (Tuple TyInt (App "ROW_NUMBER" [])))
    , Tuple 1.0 (pure (Tuple TyInt (App "RANK" [])))
    , Tuple 1.0 (pure (Tuple TyInt (App "DENSE_RANK" [])))
    , Tuple 3.0 (genAggregate scope fuel)
    , Tuple 1.5 do
        t <- genType
        f <- pick "LAG" [ "LEAD" ]
        e <- genExpr scope fuel t
        pure (Tuple t (App f [ e, Cast (Lit (LitInt 1)) "integer" ]))
    ]
  w <- genWindow scope fuel
  pure (Tuple (fst fn) (Over (snd fn) w))

genWindow :: Scope -> Int -> Gen Window
genWindow scope fuel = do
  partitionBy <- listOfBetween 0 2 (genType >>= genExpr scope (min fuel 1))
  orderBy <- listOfBetween 0 2 (genOrderExpr scope (min fuel 1))
  -- `GROUPS`, and `RANGE` with an offset, both require the window to be
  -- ordered. Offering a frame only once it is keeps the rule out of the frame
  -- generator.
  frame <- if Array.null orderBy then pure Nothing else optional 0.4 genFrame
  pure { partitionBy, orderBy, frame }

genFrame :: Gen Frame
genFrame = do
  mode <- pick Rows [ Range, Groups ]
  -- An offset in `RANGE` mode has to be addable to the `ORDER BY` column's
  -- type, and the ordering is generated before the frame is. The bounds that
  -- carry no offset dodge the question.
  Tuple start end <- genBounds case mode of
    Range -> rangeBounds
    _ -> rowBounds
  pure { mode, start, end }

-- | The frame bounds in frame order, which is the order PostgreSQL requires a
-- | `BETWEEN` frame's two ends to be given in.
rowBounds :: Array FrameBound
rowBounds = [ UnboundedPreceding, Preceding 3, Preceding 1, CurrentRow, Following 1, Following 3, UnboundedFollowing ]

rangeBounds :: Array FrameBound
rangeBounds = [ UnboundedPreceding, CurrentRow, UnboundedFollowing ]

-- | A start and an optional end, respecting the three rules PostgreSQL applies
-- | to a frame: the start comes no later than the end; `UNBOUNDED FOLLOWING`
-- | cannot start one and `UNBOUNDED PRECEDING` cannot end one; and the
-- | one-bound form runs to the current row, so it cannot start after it.
genBounds :: Array FrameBound -> Gen (Tuple FrameBound (Maybe FrameBound))
genBounds bounds = do
  i <- chooseInt 0 (n - 2)
  j <- chooseInt (max i 1) (n - 1)
  twoSided <- chance 0.75
  pure
    if twoSided || i > currentRowIndex then Tuple (at i) (Just (at j))
    else Tuple (at i) Nothing
  where
  n = Array.length bounds
  at i = fromMaybe CurrentRow (Array.index bounds i)
  currentRowIndex = fromMaybe 0 (Array.findIndex isCurrentRow bounds)
  isCurrentRow CurrentRow = true
  isCurrentRow _ = false

-- ---------------------------------------------------------------------------
-- ORDER BY
-- ---------------------------------------------------------------------------

genOrderExpr :: Scope -> Int -> Gen OrderExpr
genOrderExpr scope fuel = genOrderedType >>= genExpr scope fuel >>= genOrderOf

genOrderOf :: Expr -> Gen OrderExpr
genOrderOf expr = do
  dir <- weighted (pure Asc)
    [ Tuple 4.0 (pure Asc)
    , Tuple 3.0 (pure Desc)
    , Tuple 1.0 (OrderUsing <$> pick "<" [ ">" ])
    ]
  nulls <- optional 0.3 (pick NullsFirst [ NullsLast ])
  pure { expr, dir, nulls }

-- ---------------------------------------------------------------------------
-- Relations and joins
-- ---------------------------------------------------------------------------

type Relations =
  { from :: Relation
  , joins :: Array Join
  , scope :: Scope
  -- | Whether `FOR UPDATE` would be accepted here: every relation a bare table,
  -- | and every join inner or cross. PostgreSQL rejects a lock on a subquery,
  -- | and on the nullable side of an outer join.
  , lockable :: Boolean
  }

genRelations :: Int -> Gen Relations
genRelations fuel = do
  base <- genBaseRelation fuel
  n <- weighted (pure 0) [ Tuple 5.0 (pure 0), Tuple 3.0 (pure 1), Tuple 1.0 (pure 2) ]
  addJoins n base
  where
  addJoins 0 acc = pure acc
  addJoins n acc = do
    j <- genJoin fuel acc.scope ("r" <> show (Array.length acc.scope))
    addJoins (n - 1) acc
      { joins = Array.snoc acc.joins j.join
      , scope = Array.snoc acc.scope j.entry
      , lockable = acc.lockable && j.lockable
      }

genBaseRelation :: Int -> Gen Relations
genBaseRelation fuel = weighted table [ Tuple 8.0 table, Tuple 2.0 derived ]
  where
  table = do
    tbl <- genTable
    -- An unaliased relation goes by its own name, which is the only way
    -- `Table … Nothing` reaches PostgreSQL. Safe in the base position: joined
    -- relations always take an `r`-prefixed alias, which no table is called.
    aliased <- chance 0.75
    let alias = if aliased then "r0" else tbl.name
    pure
      { from: Table tbl.name (if aliased then Just alias else Nothing)
      , joins: []
      , scope: [ { alias, columns: tbl.columns, plain: true } ]
      , lockable: true
      }

  derived = do
    inner <- genSubSelect fuel [] "r0"
    pure
      { from: Derived inner.query "r0"
      , joins: []
      , scope: [ { alias: "r0", columns: inner.columns, plain: false } ]
      , lockable: false
      }

type JoinResult = { join :: Join, entry :: Rel, lockable :: Boolean }

genJoin :: Int -> Scope -> String -> Gen JoinResult
genJoin fuel scope alias =
  weighted joinTable
    [ Tuple 7.0 joinTable
    , Tuple 1.5 joinDerived
    , Tuple 1.5 joinLateral
    ]
  where
  joinTable = do
    tbl <- genTable
    let entry = { alias, columns: tbl.columns, plain: true }
    condition <- genTableCondition scope entry
    pure
      { join: { relation: Table tbl.name (Just alias), condition }
      , entry
      , lockable: isInner condition
      }

  joinDerived = do
    sub <- genSubSelect fuel [] alias
    let entry = { alias, columns: sub.columns, plain: false }
    condition <- genOnOrCross scope entry genJoinType
    pure { join: { relation: Derived sub.query alias, condition }, entry, lockable: false }

  -- A lateral subquery is the one that may reference the relations to its left,
  -- so its inner query is generated against the scope so far rather than an
  -- empty one. PostgreSQL only allows `LATERAL` on an inner or left join.
  joinLateral = do
    sub <- genSubSelect fuel scope alias
    let entry = { alias, columns: sub.columns, plain: false }
    condition <- genOnOrCross scope entry (pick InnerJoin [ LeftJoin ])
    pure { join: { relation: Lateral sub.query alias, condition }, entry, lockable: false }

  isInner (On InnerJoin _) = true
  isInner (Using InnerJoin _) = true
  isInner (Natural InnerJoin) = true
  isInner Cross = true
  isInner _ = false

genOnOrCross :: Scope -> Rel -> Gen JoinType -> Gen JoinCondition
genOnOrCross scope entry joinType =
  weighted (pure Cross)
    [ Tuple 3.0 (genOn scope entry joinType)
    , Tuple 1.0 (pure Cross)
    ]

genTableCondition :: Scope -> Rel -> Gen JoinCondition
genTableCondition scope entry =
  weighted (pure Cross)
    ( [ Tuple 6.0 (genOn scope entry genJoinType)
      , Tuple 1.0 (pure Cross)
      ]
        <> nameBased
    )
  where
  -- `USING` and `NATURAL` match columns by name across the whole left side, so
  -- a name that appears in two relations there is ambiguous. Offering them only
  -- against a single left relation sidesteps that without having to reason
  -- about it.
  nameBased = case scope of
    [ left ] | not (Array.null (shared left)) ->
      [ Tuple 1.5 (Using <$> genJoinType <*> someOf 1 2 (shared left))
      , Tuple 1.0 (Natural <$> genJoinType)
      ]
    _ -> []

  shared left = Array.intersect (map _.name left.columns) (map _.name entry.columns)

-- | An `ON` join. The join type is chosen after the condition, because
-- | PostgreSQL can only plan a `FULL JOIN` whose condition it can hash or merge
-- | on — an equality between two columns, which is what a join usually is
-- | anyway. The fallback condition, for two relations with no type in common,
-- | keeps to the join types that accept anything.
genOn :: Scope -> Rel -> Gen JoinType -> Gen JoinCondition
genOn scope entry joinType = case NEA.fromArray (equalities scope entry) of
  Just eqs -> On <$> joinType <*> elements eqs
  Nothing -> On <$> restrict joinType <*> genExpr (Array.snoc scope entry) 1 TyBool
  where
  restrict = map case _ of
    RightJoin -> LeftJoin
    FullJoin -> InnerJoin
    other -> other

equalities :: Scope -> Rel -> Array Expr
equalities scope entry = do
  ty <- allTypes
  l <- colsOfType scope ty
  r <- colsOfType [ entry ] ty
  pure (BinOp "=" l r)

genJoinType :: Gen JoinType
genJoinType = weighted (pure InnerJoin)
  [ Tuple 5.0 (pure InnerJoin)
  , Tuple 2.0 (pure LeftJoin)
  , Tuple 1.0 (pure RightJoin)
  , Tuple 1.0 (pure FullJoin)
  ]

-- | A subquery used as a relation. Its select list is aliased, so the columns
-- | it offers the query around it are known by name and by type.
genSubSelect :: Int -> Scope -> String -> Gen { query :: Query, columns :: Array Column }
genSubSelect fuel outer alias = do
  tbl <- genTable
  tys <- listOfBetween 1 3 genType
  let scope = Array.snoc outer { alias: innerAlias, columns: tbl.columns, plain: true }
  items <- traverse (item scope) (Array.mapWithIndex Tuple tys)
  predicate <- optional 0.5 (genExpr scope (min fuel 1) TyBool)
  pure
    { query: emptyQuery
        { select = items
        , from = Just (Table tbl.name (Just innerAlias))
        , where_ = predicate
        }
    , columns: Array.mapWithIndex (\i ty -> { name: colName i, ty }) tys
    }
  where
  innerAlias = alias <> "x"
  item scope (Tuple i ty) = flip SelectAs (colName i) <$> genExpr scope (min fuel 1) ty
  colName i = "c" <> show i

-- ---------------------------------------------------------------------------
-- Query shapes
-- ---------------------------------------------------------------------------

-- | A `SELECT` with no aggregation: the shape most of the budget goes to,
-- | because it is the one whose select list, `WHERE` and `ORDER BY` are all
-- | free-form expressions.
genSimple :: Int -> Gen Query
genSimple fuel = do
  rels <- genRelations fuel
  items <- genSelectItems fuel rels.scope
  predicate <- optional 0.7 (genExpr rels.scope fuel TyBool)
  Tuple distinct ordering <- genDistinctAndOrder fuel rels.scope items.exprs
  limit <- optional 0.25 (Lit <<< LitInt <$> chooseInt 1 100)
  offset <- optional 0.15 (Lit <<< LitInt <$> chooseInt 0 20)
  locking <-
    if rels.lockable && not items.windowed && isNothing distinct then genLocking rels.scope
    else pure []
  pure emptyQuery
    { select = items.items
    , from = Just rels.from
    , joins = rels.joins
    , where_ = predicate
    , distinct = distinct
    , orderBy = ordering
    , limit = limit
    , offset = offset
    , locking = locking
    }

type SelectItems =
  { items :: Array SelectExpr
  -- | The expressions the select list projects, which is what `ORDER BY` has to
  -- | be drawn from once `DISTINCT` is in play.
  , exprs :: Array Expr
  -- | Whether a window function is among them, which rules out `FOR UPDATE`.
  , windowed :: Boolean
  }

genSelectItems :: Int -> Scope -> Gen SelectItems
genSelectItems fuel scope = do
  n <- chooseInt 1 4
  items <- traverse item (Array.range 1 n)
  pure
    { items: map _.item items
    , exprs: Array.mapMaybe _.expr items
    , windowed: any _.windowed items
    }
  where
  item i =
    weighted (plain i)
      [ Tuple 6.0 (plain i)
      , Tuple 3.0 (aliased i)
      , Tuple 1.5 (windowed i)
      , Tuple 1.0 (pure { item: SelectStar, expr: Nothing, windowed: false })
      , Tuple 1.0 (star <$> pickOr (pure "r0") (map _.alias scope))
      ]

  plain _ = do
    e <- genType >>= genExpr scope fuel
    pure { item: SelectExpr e, expr: Just e, windowed: false }

  aliased i = do
    e <- genType >>= genExpr scope fuel
    pure { item: SelectAs e ("x" <> show i), expr: Just e, windowed: false }

  windowed i = do
    e <- snd <$> genWindowFn scope (min fuel 1)
    named <- chance 0.5
    pure
      { item: if named then SelectAs e ("w" <> show i) else SelectExpr e
      , expr: Just e
      , windowed: true
      }

  star alias = { item: SelectStarFrom alias, expr: Nothing, windowed: false }

-- | `DISTINCT` and `ORDER BY` together, because SQL ties them together:
-- | `DISTINCT` requires every ordering expression to be projected, and
-- | `DISTINCT ON` requires its own expressions to lead the ordering. Generating
-- | the pair at once is what keeps both rules satisfied.
genDistinctAndOrder :: Int -> Scope -> Array Expr -> Gen (Tuple (Maybe Distinct) (Array OrderExpr))
genDistinctAndOrder fuel scope projected =
  weighted plain
    [ Tuple 7.0 plain
    , Tuple 1.5 distinctAll
    , Tuple 1.5 distinctOn
    ]
  where
  plain = Tuple Nothing <$> listOfBetween 0 2 (genOrderExpr scope (min fuel 1))

  distinctAll = do
    chosen <- someOf 0 2 (Array.filter literalFree projected)
    Tuple (Just Distinct) <$> traverse genOrderOf chosen

  distinctOn = do
    keys <- listOfBetween 1 2 (genGroupKey scope)
    Tuple (Just (DistinctOn keys)) <$> traverse genOrderOf keys

genLocking :: Scope -> Gen (Array Locking)
genLocking scope =
  weighted (pure [])
    [ Tuple 6.0 (pure [])
    , Tuple 2.0 (Array.singleton <$> clause (map _.alias scope))
    , Tuple 1.0 (Array.singleton <$> clause [])
    -- Two clauses may not both claim the same relation, so they split the
    -- aliases between them rather than each naming a subset.
    , Tuple 1.0 twoClauses
    ]
  where
  twoClauses = case scope of
    [ a, b ] -> do
      x <- clause [ a.alias ]
      y <- clause [ b.alias ]
      pure [ x, y ]
    _ -> Array.singleton <$> clause []

  clause tables = do
    strength <- pick ForUpdate [ ForNoKeyUpdate, ForShare, ForKeyShare ]
    wait <- optional 0.4 (pick NoWait [ SkipLocked ])
    pure { strength, tables, wait }

-- | An aggregated `SELECT`.
-- |
-- | The select list, `HAVING` and `ORDER BY` are all drawn from the same two
-- | pools — the grouping keys and the aggregates — because those are the only
-- | expressions PostgreSQL allows once a `GROUP BY` is present.
genGrouped :: Int -> Gen Query
genGrouped fuel = do
  rels <- genRelations fuel
  keys <- listOfBetween 1 2 (genGroupKey rels.scope)
  grouping <- genGrouping keys
  aggs <- listOfBetween 1 2 (genAggregate rels.scope (min fuel 1))
  projected <- someOf 0 2 keys
  predicate <- optional 0.5 (genExpr rels.scope (min fuel 1) TyBool)
  having <- optional 0.4 (genAggPredicate aggs)
  ordering <- someOf 0 2 (keys <> map snd aggs) >>= traverse genOrderOf
  limit <- optional 0.2 (Lit <<< LitInt <$> chooseInt 1 100)
  pure emptyQuery
    { select = map SelectExpr projected <> Array.mapWithIndex aggItem aggs
    , from = Just rels.from
    , joins = rels.joins
    , where_ = predicate
    , groupBy = grouping
    , having = having
    , orderBy = ordering
    , limit = limit
    }
  where
  aggItem i (Tuple _ e) = SelectAs e ("agg" <> show i)

-- | A grouping key, which is also what the leading expressions of a
-- | `DISTINCT ON` have to be.
-- |
-- | Built out of column references and nothing else. PostgreSQL matches a
-- | select-list expression against a grouping key structurally, so the key has
-- | to survive being written twice — which `literalFree` explains a literal
-- | does not — and a key holding a subquery is a match this generator would
-- | rather not have to reason about either.
genGroupKey :: Scope -> Gen Expr
genGroupKey scope = do
  Tuple ty e <- pickOr (pure (Tuple TyInt (Cast (Lit (LitInt 1)) "integer"))) (scopeColumns scope)
  weighted (pure e) [ Tuple 6.0 (pure e), Tuple 1.0 (pure (wrapped ty e)) ]
  where
  wrapped TyText e = App "UPPER" [ e ]
  wrapped TyBool e = Unary "NOT" e
  wrapped TyTime e = e
  wrapped _ e = App "ABS" [ e ]

genGrouping :: Array Expr -> Gen (Array GroupingElement)
genGrouping keys =
  weighted (pure plain)
    [ Tuple 6.0 (pure plain)
    , Tuple 1.0 (pure [ Rollup keys ])
    , Tuple 1.0 (pure [ Cube keys ])
    -- The empty grouping set is the grand total, and the only way to write it.
    , Tuple 1.0 (pure [ GroupingSets (map Array.singleton keys <> [ [] ]) ])
    ]
  where
  plain = map GroupingExpr keys

genAggPredicate :: Array (Tuple SqlType Expr) -> Gen Expr
genAggPredicate aggs = case NEA.fromArray aggs of
  Nothing -> pure (BinOp ">" countStar (Cast (Lit (LitInt 0)) "integer"))
  Just ne -> do
    Tuple ty e <- elements ne
    op <- pick ">" [ ">=", "<", "<=", "=", "<>" ]
    BinOp op e <$> genTypedLit ty

-- | Two queries combined. Both operands project the same list of types, which
-- | is what makes the column counts line up and the types unify.
genSetOp :: Int -> Gen Query
genSetOp fuel = do
  tys <- listOfBetween 1 3 genType
  left <- operand tys
  right <- operand tys
  op <- pick Union [ Intersect, Except ]
  everything <- chance 0.5
  limit <- optional 0.3 (Lit <<< LitInt <$> chooseInt 1 100)
  pure emptyQuery
    { setOp = Just (SetOperation { op, all: everything, left, right })
    , limit = limit
    }
  where
  operand tys = do
    tbl <- genTable
    let scope = [ { alias: "r0", columns: tbl.columns, plain: true } ]
    items <- traverse (genExpr scope (min fuel 2)) tys
    predicate <- optional 0.5 (genExpr scope (min fuel 1) TyBool)
    pure emptyQuery
      { select = map SelectExpr items
      , from = Just (Table tbl.name (Just "r0"))
      , where_ = predicate
      }

-- | A query reading from a `WITH` clause. The CTE's select list is aliased, so
-- | the outer query knows what columns it may reference.
genWithCte :: Int -> Gen Query
genWithCte fuel = do
  inner <- genSubSelect fuel [] "c0"
  named <- chance 0.4
  let scope = [ { alias: "q0", columns: inner.columns, plain: false } ]
  items <- genSelectItems fuel scope
  predicate <- optional 0.6 (genExpr scope (min fuel 1) TyBool)
  ordering <- listOfBetween 0 2 (genOrderExpr scope (min fuel 1))
  pure emptyQuery
    { with =
        [ Cte
            { name: "c0"
            , columns: if named then map _.name inner.columns else []
            , recursive: false
            , query: inner.query
            }
        ]
    , select = items.items
    , from = Just (Table "c0" (Just "q0"))
    , where_ = predicate
    , orderBy = ordering
    }

-- ---------------------------------------------------------------------------
-- Shrinking
-- ---------------------------------------------------------------------------

-- | Smaller queries to try when one of these fails.
-- |
-- | Every step narrows the query rather than changing it: a clause is dropped
-- | whole, or an expression is replaced by one of its own children of the same
-- | type. That matters because the validator keeps the smallest candidate that
-- | *still* fails — a shrink that introduced a type error or an orphaned alias
-- | would look like a smaller counterexample while actually being a different
-- | bug.
shrinkQuery :: Query -> Array Query
shrinkQuery q = case q.setOp of
  -- Each operand is a complete query, so trying them alone says which side of
  -- the operator the failure is on.
  Just (SetOperation s) -> [ s.left, s.right ]
  Nothing -> dropClauses <> dropJoin <> shortenSelect <> shrinkExprs
  where
  dropClauses = Array.catMaybes
    [ q.where_ $> q { where_ = Nothing }
    , q.having $> q { having = Nothing }
    , q.limit $> q { limit = Nothing }
    , q.offset $> q { offset = Nothing }
    -- `DISTINCT ON` fixes the leading ordering expressions, so the two go
    -- together or not at all.
    , q.distinct $> q { distinct = Nothing, orderBy = [] }
    , if Array.null q.locking then Nothing else Just q { locking = [] }
    , if Array.null q.orderBy || isDistinctOn then Nothing else Just q { orderBy = [] }
    , if Array.length q.groupBy <= 1 then Nothing else Just q { groupBy = Array.take 1 q.groupBy }
    ]

  isDistinctOn = case q.distinct of
    Just (DistinctOn _) -> true
    _ -> false

  -- A join can only go if nothing left behind still names it.
  dropJoin = case Array.unsnoc q.joins of
    Just { init, last } | not (mentionsAlias (relationAlias last.relation) q { joins = init }) ->
      [ q { joins = init } ]
    _ -> []

  -- Dropping a projection is safe unless `DISTINCT` requires the ordering
  -- expressions to be among them.
  shortenSelect =
    if Array.length q.select <= 1 || isJust' q.distinct then []
    else map (\i -> q { select = dropAt i q.select }) (Array.range 0 (Array.length q.select - 1))

  isJust' = maybe false (const true)

  shrinkExprs =
    maybe [] (\e -> map (\e' -> q { where_ = Just e' }) (shrinkExpr e)) q.where_
      <> maybe [] (\e -> map (\e' -> q { having = Just e' }) (shrinkExpr e)) q.having
      <> Array.concat (Array.mapWithIndex selectAt q.select)

  selectAt i (SelectExpr e) = map (\e' -> q { select = setAt i (SelectExpr e') q.select }) (shrinkExpr e)
  selectAt i (SelectAs e a) = map (\e' -> q { select = setAt i (SelectAs e' a) q.select }) (shrinkExpr e)
  selectAt _ _ = []

-- | Type-preserving replacements for an expression: one of its children of the
-- | same type, or the same node with fewer children.
shrinkExpr :: Expr -> Array Expr
shrinkExpr = case _ of
  And xs -> dropOne And xs <> Array.filter compound xs
  Or xs -> dropOne Or xs <> Array.filter compound xs
  Unary "NOT" x -> [ x ]
  -- Arithmetic and concatenation return the type of their operands, so either
  -- one stands in for the whole.
  BinOp op l r | Array.elem op [ "+", "-", "*", "||" ] -> [ l, r ]
  BinOp op l r -> map (\l' -> BinOp op l' r) (shrinkExpr l) <> map (BinOp op l) (shrinkExpr r)
  Between x lo hi -> [ BinOp ">=" x lo, BinOp "<=" x hi ]
  Filter agg _ -> [ agg ]
  Over f w -> map (Over f) (shrinkWindow w)
  Row xs -> dropOne Row xs
  -- These return the type of their arguments, so an argument is a legitimate
  -- replacement for the call.
  App f xs | Array.elem f [ "COALESCE", "GREATEST", "LEAST", "ABS", "UPPER", "LOWER", "INITCAP", "TRIM" ] -> xs
  Cast e ty -> map (flip Cast ty) (shrinkExpr e)
  Postfix op e -> map (Postfix op) (shrinkExpr e)
  Unary op e -> map (Unary op) (shrinkExpr e)
  Quantified quant op l r -> map (\l' -> Quantified quant op l' r) (shrinkExpr l)
  Sub q -> map Sub (shrinkQuery q)
  _ -> []
  where
  dropOne f xs =
    if Array.length xs <= 1 then []
    else map (f <<< flip dropAt xs) (Array.range 0 (Array.length xs - 1))

  compound (Lit _) = false
  compound (Col _) = false
  compound _ = true

shrinkWindow :: Window -> Array Window
shrinkWindow w = Array.catMaybes
  [ w.frame $> w { frame = Nothing }
  , if Array.null w.partitionBy then Nothing else Just w { partitionBy = [] }
  , if Array.null w.orderBy then Nothing else Just w { orderBy = [], frame = Nothing }
  ]

-- | Everything `shrinkQuery` can reach in a bounded number of steps, smallest
-- | first.
-- |
-- | Breadth-first and capped, because the reachable set is large and only its
-- | small end is worth reading. Ordering by the length of the emitted SQL lets
-- | the validator report the smallest candidate that still fails, which is the
-- | answer a shrinking loop would converge on — without the round trips a loop
-- | between two processes would cost.
-- |
-- | Candidates carry their SQL rather than being formatted on demand. Two
-- | shrink paths often arrive at the same query, so they have to be compared,
-- | and comparing them by formatting both every time is what turns a search
-- | over a few hundred candidates into one over tens of thousands of prints.
shrinkClosure :: Int -> Query -> Array Query
shrinkClosure limit root = map _.query (Array.sortWith (String.length <<< _.sql) (go [ start ] [] limit))
  where
  printed q = { sql: formatInline q, query: q }
  start = printed root
  same a b = a.sql == b.sql

  go frontier acc budget
    | Array.null frontier || budget <= 0 = acc
    | otherwise = go taken (acc <> taken) (budget - Array.length taken)
        where
        candidates = Array.nubByEq same (map printed (Array.concatMap (shrinkQuery <<< _.query) frontier))
        fresh = Array.filter (\c -> not (same c start) && not (any (same c) acc)) candidates
        taken = Array.take budget fresh

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

dropAt :: forall a. Int -> Array a -> Array a
dropAt i xs = Array.take i xs <> Array.drop (i + 1) xs

setAt :: forall a. Int -> a -> Array a -> Array a
setAt i x xs = fromMaybe xs (Array.updateAt i x xs)

relationAlias :: Relation -> String
relationAlias (Table name alias) = fromMaybe name alias
relationAlias (Derived _ alias) = alias
relationAlias (Lateral _ alias) = alias

-- | Whether any column reference, `alias.*` or lock target left in the query
-- | still names the given relation. Answered on the emitted SQL rather than by
-- | walking the AST: the quoted identifier is unambiguous, and a walk would
-- | have to cover every clause to be worth trusting.
mentionsAlias :: String -> Query -> Boolean
mentionsAlias alias = String.contains (String.Pattern ("\"" <> alias <> "\"")) <<< formatInline
