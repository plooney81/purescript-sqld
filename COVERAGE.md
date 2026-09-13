# Grammar coverage

Measured 2026-09-13 against PostgreSQL's regression
suite with libpg-query 17.7.4. Regenerate with `make coverage`; the
prerequisites are documented at the top of
[scripts/coverage-report.mjs](scripts/coverage-report.mjs).

**sqld covers 38 of the 83 distinct parse-tree node types that PostgreSQL's
regression suite uses in `SELECT`, `INSERT`, `UPDATE` and `DELETE`
statements (45.8%) — 97.4% of those statements' node occurrences by
frequency.**

The two numbers say different things and both are worth having. The weighted one
is high because the nodes every query is built from — column references, target
list entries, constants, operators — are also the nodes sqld emits most; it is
the answer to "how much of the SQL people actually write can this express?". The
distinct-type one is lower and is the answer to "how many of PostgreSQL's
constructs exist here at all?".

## How the number is produced

Neither side of the comparison is hand-maintained, because a hand-maintained
list is the drift this exists to measure.

The **denominator** is PostgreSQL's own regression suite, parsed by PostgreSQL's
own parser and histogrammed by parse-tree node type. Weighting by occurrence is
what makes it a ranking rather than a checklist: a node used four thousand times
is worth more than one used twice.

The **numerator** is the set of node types appearing in the parse trees of the
SQL sqld itself emits — every entry of the validation corpus, in both the
parameterised and inline forms. `Test.Sqld.CorpusSpec` already fails the build
if an AST constructor exists that no corpus entry builds, so the corpus tracks
the AST and this number tracks the corpus.

## Corpus measured

| | |
|---|---|
| Source | `src/test/regress/sql`, PostgreSQL 17.2 |
| Files | 223 |
| Statements parsed | 44,407 |
| — of which `SELECT`/`INSERT`/`UPDATE`/`DELETE` | 23,020 |
| Statements skipped | 464 |
| Node occurrences | 517,603 |
| Distinct node types | 203 |
| sqld corpus entries | 187 |

Skipped statements are the ones PostgreSQL's parser rejects: the regression
suite deliberately includes malformed SQL to test error messages, alongside
`COPY` payloads and psql meta-commands that are not SQL at all. They
contribute to neither side of the ratio.

## Coverage

### SELECT, INSERT, UPDATE and DELETE

The denominator a query builder is actually measured against.

| Measure | Covered | Total | Coverage |
|---|---:|---:|---:|
| Node types (distinct) | 38 | 83 | 45.8% |
| Node occurrences (weighted) | 332,659 | 341,393 | 97.4% |

Unsupported node types, most frequent first — the to-do list, ranked by how
often the construct actually turns up:

| Node type | Occurrences | Share of scope |
|---|---:|---:|
| `RangeFunction` | 1,798 | 0.5% |
| `JsonFormat` | 944 | 0.3% |
| `A_ArrayExpr` | 715 | 0.2% |
| `BitString` | 666 | 0.2% |
| `A_Indices` | 588 | 0.2% |
| `JsonValueExpr` | 557 | 0.2% |
| `A_Indirection` | 377 | 0.1% |
| `CollateClause` | 243 | 0.1% |
| `JsonFuncExpr` | 241 | 0.1% |
| `JsonOutput` | 218 | 0.1% |
| `JsonReturning` | 218 | 0.1% |
| `NamedArgExpr` | 217 | 0.1% |
| `JsonTablePathSpec` | 210 | 0.1% |
| `ColumnDef` | 169 | 0.0% |
| `JsonBehavior` | 169 | 0.0% |
| `JsonTableColumn` | 164 | 0.0% |
| `JsonKeyValue` | 116 | 0.0% |
| `CaseWhen` | 114 | 0.0% |
| `CaseExpr` | 92 | 0.0% |
| `XmlExpr` | 88 | 0.0% |
| `SQLValueFunction` | 87 | 0.0% |
| `RangeTableFuncCol` | 85 | 0.0% |
| `JsonTable` | 73 | 0.0% |
| `JsonObjectConstructor` | 64 | 0.0% |
| `JsonAggConstructor` | 51 | 0.0% |
| `MultiAssignRef` | 50 | 0.0% |
| `JsonIsPredicate` | 44 | 0.0% |
| `JsonArgument` | 42 | 0.0% |
| `BooleanTest` | 38 | 0.0% |
| `XmlSerialize` | 31 | 0.0% |
| `CurrentOfExpr` | 29 | 0.0% |
| `JsonArrayConstructor` | 29 | 0.0% |
| `RangeTableFunc` | 29 | 0.0% |
| `JsonObjectAgg` | 28 | 0.0% |
| `MinMaxExpr` | 27 | 0.0% |
| `RangeTableSample` | 26 | 0.0% |
| `JsonArrayAgg` | 23 | 0.0% |
| `JsonParseExpr` | 15 | 0.0% |
| `JsonScalarExpr` | 12 | 0.0% |
| `JsonSerializeExpr` | 12 | 0.0% |
| `IntoClause` | 11 | 0.0% |
| `JsonArrayQueryConstructor` | 7 | 0.0% |
| `MergeWhenClause` | 7 | 0.0% |
| `MergeSupportFunc` | 6 | 0.0% |
| `MergeStmt` | 4 | 0.0% |

### Every statement in the suite

The unrestricted figure, including DDL, transaction control and roles — statements sqld does not set out to emit.

| Measure | Covered | Total | Coverage |
|---|---:|---:|---:|
| Node types (distinct) | 38 | 203 | 18.7% |
| Node occurrences (weighted) | 462,757 | 517,603 | 89.4% |

Unsupported node types, most frequent first — the to-do list, ranked by how
often the construct actually turns up:

| Node type | Occurrences | Share of scope |
|---|---:|---:|
| `DefElem` | 6,866 | 1.3% |
| `ColumnDef` | 5,405 | 1.0% |
| `CreateStmt` | 3,556 | 0.7% |
| `DropStmt` | 2,580 | 0.5% |
| `VariableSetStmt` | 2,130 | 0.4% |
| `RangeFunction` | 1,994 | 0.4% |
| `AlterTableCmd` | 1,955 | 0.4% |
| `AlterTableStmt` | 1,832 | 0.4% |
| `ExplainStmt` | 1,732 | 0.3% |
| `Constraint` | 1,636 | 0.3% |
| `FunctionParameter` | 1,481 | 0.3% |
| `TransactionStmt` | 1,452 | 0.3% |
| `JsonFormat` | 1,133 | 0.2% |
| `RoleSpec` | 1,102 | 0.2% |
| `CreateFunctionStmt` | 899 | 0.2% |
| `A_ArrayExpr` | 789 | 0.2% |
| `IndexStmt` | 738 | 0.1% |
| `JsonValueExpr` | 675 | 0.1% |
| `BitString` | 670 | 0.1% |
| `ObjectWithArgs` | 662 | 0.1% |
| `PartitionElem` | 662 | 0.1% |
| `A_Indices` | 635 | 0.1% |
| `PartitionSpec` | 591 | 0.1% |
| `VacuumRelation` | 467 | 0.1% |
| `VacuumStmt` | 448 | 0.1% |
| `A_Indirection` | 437 | 0.1% |
| `ViewStmt` | 434 | 0.1% |
| `CollateClause` | 402 | 0.1% |
| `AccessPriv` | 393 | 0.1% |
| `GrantStmt` | 379 | 0.1% |
| `MergeWhenClause` | 375 | 0.1% |
| `PartitionCmd` | 374 | 0.1% |
| `CreateTrigStmt` | 354 | 0.1% |
| `DefineStmt` | 326 | 0.1% |
| `JsonFuncExpr` | 285 | 0.1% |
| `JsonTablePathSpec` | 271 | 0.1% |
| `MergeStmt` | 266 | 0.1% |
| `ExecuteStmt` | 248 | 0.0% |
| `FetchStmt` | 242 | 0.0% |
| `JsonOutput` | 236 | 0.0% |
| `JsonReturning` | 236 | 0.0% |
| `DropRoleStmt` | 235 | 0.0% |
| `StatsElem` | 234 | 0.0% |
| `IntoClause` | 233 | 0.0% |
| `NamedArgExpr` | 232 | 0.0% |
| `JsonTableColumn` | 221 | 0.0% |
| `PublicationObjSpec` | 220 | 0.0% |
| `CreateTableAsStmt` | 217 | 0.0% |
| `CreateRoleStmt` | 214 | 0.0% |
| `RenameStmt` | 210 | 0.0% |

_115 rarer node types omitted; rerun with `--top 0` for the full list._

## Node types sqld emits

Counts are occurrences across the whole suite, so a node sqld supports that the
suite happens never to use shows as 0.

| Node type | Occurrences in suite |
|---|---:|
| `String` | 141,081 |
| `A_Const` | 58,949 |
| `ColumnRef` | 37,490 |
| `ResTarget` | 33,865 |
| `RangeVar` | 29,817 |
| `SelectStmt` | 27,902 |
| `Integer` | 26,966 |
| `TypeName` | 19,323 |
| `List` | 14,919 |
| `FuncCall` | 14,569 |
| `A_Expr` | 13,713 |
| `TypeCast` | 8,909 |
| `Alias` | 6,243 |
| `A_Star` | 5,715 |
| `InsertStmt` | 5,225 |
| `SortBy` | 3,472 |
| `Float` | 2,186 |
| `BoolExpr` | 1,752 |
| `RangeSubselect` | 1,562 |
| `IndexElem` | 1,313 |
| `JoinExpr` | 1,281 |
| `Boolean` | 1,052 |
| `UpdateStmt` | 878 |
| `SubLink` | 703 |
| `WindowDef` | 620 |
| `RowExpr` | 597 |
| `DeleteStmt` | 456 |
| `NullTest` | 389 |
| `CommonTableExpr` | 374 |
| `WithClause` | 334 |
| `OnConflictClause` | 217 |
| `InferClause` | 206 |
| `SetToDefault` | 192 |
| `GroupingSet` | 187 |
| `CoalesceExpr` | 130 |
| `ParamRef` | 73 |
| `GroupingFunc` | 51 |
| `LockingClause` | 46 |
