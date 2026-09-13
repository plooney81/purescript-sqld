#!/usr/bin/env node
// Measures how much of PostgreSQL's grammar sqld can emit.
//
// A hand-maintained feature checklist answers "what do we support?" only until
// someone forgets to tick a box. This script answers it with a denominator
// nobody curates: PostgreSQL's own regression suite, parsed by PostgreSQL's own
// parser (`libpg_query`), histogrammed by parse-tree node type.
//
// Neither side of the comparison is written down:
//
//   * the denominator is every node type appearing in `src/test/regress/sql`,
//     weighted by how often it actually appears
//   * the numerator is every node type appearing in the parse trees of the SQL
//     sqld itself emits — the validation corpus, which `Test.Sqld.CorpusSpec`
//     already asserts exercises every AST constructor
//
// So the supported set is whatever the formatter can currently produce. Add a
// constructor without a corpus entry and the corpus spec fails; add one with a
// corpus entry and the number here moves on its own.
//
// Prerequisites — the reason this runs on demand rather than in CI:
//
//   * `npm install libpg-query`, a build of PostgreSQL's parser
//   * PostgreSQL's source tree, for the regression suite and the node headers:
//       curl -sLO https://github.com/postgres/postgres/archive/refs/tags/REL_17_2.tar.gz
//       tar xzf REL_17_2.tar.gz
//   * `spago test`, to emit `test-artifacts/corpus.json`
//
// Usage:
//   node scripts/coverage-report.mjs --pg-source <path/to/postgres>
//   make coverage PG_SOURCE=<path/to/postgres>

import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const SQLD_CORPUS_PATH = "test-artifacts/corpus.json";
const REGRESS_DIR = "src/test/regress/sql";
const NODES_DIR = "src/include/nodes";
const DEFAULT_OUT = "COVERAGE.md";
const DEFAULT_TOP = 50;

// The statement kinds a query builder could conceivably grow into. Everything
// else in the regression suite is DDL, transaction control, roles and psql
// plumbing, which sqld is not trying to emit and which would otherwise bury the
// number under nodes it can never move. Reported alongside the unrestricted
// figure rather than instead of it, so neither denominator is hidden.
const DML_STATEMENTS = new Set(["SelectStmt", "InsertStmt", "UpdateStmt", "DeleteStmt"]);

// Wrapped nodes are the only capitalised keys libpg_query emits: every struct
// field it writes is lowercase (`targetList`, `agg_star`, `location`).
const NODE_KEY = /^[A-Z][A-Za-z0-9_]*$/;

// Three C types that never name a node in the JSON. `Node` and `Expr` are
// polymorphic, so libpg_query wraps them and the key already says the type;
// `List` is flattened to a bare JSON array with its elements wrapped. Treating
// any of them as a resolvable field type would invent nodes that are not there.
const UNRESOLVABLE = new Set(["Node", "Expr", "List"]);

function die(message) {
  console.error(`\ncoverage-report: ${message}\n`);
  process.exit(1);
}

// --- arguments -------------------------------------------------------------

const USAGE = `Usage: node scripts/coverage-report.mjs --pg-source <dir> [options]

  --pg-source <dir>  root of a PostgreSQL source tree (required, or set
                     PG_SOURCE). Supplies ${REGRESS_DIR}
                     and ${NODES_DIR}.
  --out <path>       write the report here (default: ${DEFAULT_OUT})
  --top <n>          rows in each unsupported-node table, 0 for all
                     (default: ${DEFAULT_TOP})
  --stdout           print the report instead of writing it
  -h, --help         show this message

Environment:
  PG_SOURCE          default for --pg-source`;

function parseArgs(argv) {
  const options = {
    pgSource: process.env.PG_SOURCE ?? null,
    out: DEFAULT_OUT,
    top: DEFAULT_TOP,
    stdout: false,
  };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const takeValue = (name) => {
      const value = argv[++i];
      if (value === undefined) die(`${name} requires a value.\n\n${USAGE}`);
      return value;
    };

    switch (arg) {
      case "--pg-source":
        options.pgSource = takeValue("--pg-source");
        break;
      case "--out":
        options.out = takeValue("--out");
        break;
      case "--top":
        options.top = Number(takeValue("--top"));
        if (!Number.isInteger(options.top) || options.top < 0) {
          die("--top requires a non-negative integer.");
        }
        break;
      case "--stdout":
        options.stdout = true;
        break;
      case "-h":
      case "--help":
        console.log(USAGE);
        process.exit(0);
      // eslint-disable-next-line no-fallthrough
      default:
        die(`unknown option "${arg}".\n\n${USAGE}`);
    }
  }

  if (options.pgSource === null) die(`--pg-source is required.\n\n${USAGE}`);

  for (const sub of [REGRESS_DIR, NODES_DIR]) {
    if (!existsSync(join(options.pgSource, sub))) {
      die(
        `"${options.pgSource}" does not look like a PostgreSQL source tree: ` +
          `${sub} is missing.\n\n${USAGE}`,
      );
    }
  }

  return options;
}

const options = parseArgs(process.argv.slice(2));
const regressDir = join(options.pgSource, REGRESS_DIR);
const nodesDir = join(options.pgSource, NODES_DIR);

// --- the parser ------------------------------------------------------------

// Imported dynamically so the missing-dependency path is a sentence about how
// to fix it rather than a module resolution stack trace.
async function loadParser() {
  let module;
  try {
    module = await import("libpg-query");
  } catch {
    die(
      `libpg-query is not installed.\n` +
        `It carries a build of PostgreSQL's parser, which is why this script runs ` +
        `on demand rather\nthan in CI. Install it with:\n\n    npm install libpg-query`,
    );
  }

  await module.loadModule();

  let version = "unknown";
  try {
    const pkg = await import("libpg-query/package.json", { with: { type: "json" } });
    version = pkg.default.version;
  } catch {
    // Only the report header loses out, so a package that keeps its manifest
    // out of the export map is not worth failing over.
  }

  // Returns the parsed statement list, or null if PostgreSQL rejects the text.
  const parse = (sql) => {
    try {
      return module.parseSync(sql).stmts ?? [];
    } catch {
      return null;
    }
  };

  return { parse, version };
}

const { parse, version: parserVersion } = await loadParser();

// --- what a field's type is ------------------------------------------------

// libpg_query only writes the node type as a key where the C field is
// polymorphic. A field declared as a concrete struct — `WindowDef *over`,
// `Alias *alias`, `TypeName *typeName` — is inlined with no name attached, so a
// walk that trusts the keys alone cannot see it: `OVER (…)` would count as no
// node at all, and window functions would show up as unsupported.
//
// The missing names come out of the same source tree the regression suite does.
// `src/include/nodes/*.h` declares every node struct, so field name to node type
// is a read of those headers rather than a table maintained here.
function structFields(dir) {
  const text = readdirSync(dir)
    .filter((name) => name.endsWith(".h"))
    .map((name) => readFileSync(join(dir, name), "utf8"))
    .join("\n");

  const nodeTypes = new Set([...text.matchAll(/^typedef struct (\w+)/gm)].map((m) => m[1]));

  // Members of the form `Type *field;`, keeping only the ones whose type names
  // a node libpg_query would have had to inline.
  const membersOf = (body) => {
    const members = new Map();
    for (const line of body.split("\n")) {
      const member = line.match(/^\s*(?:struct\s+)?(\w+)\s*\*?\s*(\w+)\s*;/);
      if (member && nodeTypes.has(member[1]) && !UNRESOLVABLE.has(member[1])) {
        members.set(member[2], member[1]);
      }
    }
    return members;
  };

  // A union member is flattened into its parent by libpg_query, which is how
  // `A_Const`'s `ival`/`sval`/`boolval` reach the JSON without a union in sight.
  const unions = new Map(
    [...text.matchAll(/^union (\w+)\s*\n\{([\s\S]*?)^\};/gm)]
      .map(([, name, body]) => [name, membersOf(body)]),
  );

  const fields = new Map();
  for (const [, name, body] of text.matchAll(/^typedef struct (\w+)\s*\n\{([\s\S]*?)^\}/gm)) {
    const members = membersOf(body);
    for (const inlined of body.matchAll(/^\s*union\s+(\w+)\s+\w+\s*;/gm)) {
      for (const [field, type] of unions.get(inlined[1]) ?? []) members.set(field, type);
    }
    if (members.size) fields.set(name, members);
  }

  if (!fields.size) {
    die(
      `no node struct definitions found in ${dir}.\n` +
        `Without them the walk cannot name inlined fields and the coverage number ` +
        `would be wrong\nrather than merely incomplete.`,
    );
  }

  return fields;
}

const fields = structFields(nodesDir);

// --- histogramming ---------------------------------------------------------

// Counts every node in a parse tree, naming inlined fields from the struct map
// so a `WindowDef` reached through `FuncCall.over` counts the same as one
// reached through a `WINDOW` clause.
function countNodes(value, declaredType, into) {
  if (Array.isArray(value)) {
    // Only a `List *` field serialises as an array, and its elements are
    // wrapped, so the declared type does not carry into them.
    for (const element of value) countNodes(element, null, into);
    return;
  }
  if (value === null || typeof value !== "object") return;

  const keys = Object.keys(value);
  const wrapped = keys.length === 1 && NODE_KEY.test(keys[0]) &&
    typeof value[keys[0]] === "object" && value[keys[0]] !== null &&
    !Array.isArray(value[keys[0]]);

  const type = wrapped ? keys[0] : declaredType;
  const body = wrapped ? value[keys[0]] : value;

  if (type !== null) into.set(type, (into.get(type) ?? 0) + 1);

  for (const [field, child] of Object.entries(body)) {
    countNodes(child, fields.get(type)?.get(field) ?? null, into);
  }
}

// The node type of the statement itself, which is what decides whether it
// counts towards the DML-only figure.
function statementKind(stmt) {
  const node = stmt?.stmt;
  if (node === null || typeof node !== "object") return null;
  return Object.keys(node)[0] ?? null;
}

// --- what sqld can emit ----------------------------------------------------

// Derived, not declared: whatever node types turn up in the parse trees of the
// SQL sqld actually produces. Both formatter outputs are read, because both are
// SQL a caller can run — the parameterised form contributes `ParamRef` where
// the inline form contributes `A_Const`.
function supportedNodes() {
  if (!existsSync(SQLD_CORPUS_PATH)) {
    die(`${SQLD_CORPUS_PATH} not found. Run \`spago test\` first to emit the corpus.`);
  }

  const entries = JSON.parse(readFileSync(SQLD_CORPUS_PATH, "utf8"));
  const histogram = new Map();
  const rejected = [];

  for (const entry of entries) {
    for (const sql of [entry.sql, entry.inlineSql]) {
      if (!sql) continue;
      const stmts = parse(sql);
      // sqld emitting SQL PostgreSQL's own parser rejects is a real bug, so it
      // is surfaced rather than quietly dropped from the numerator.
      if (stmts === null) rejected.push(entry.name);
      else countNodes(stmts, null, histogram);
    }
  }

  return { nodes: new Set(histogram.keys()), entries: entries.length, rejected };
}

// --- splitting a .sql file into statements ---------------------------------

// The regression files are psql scripts, not SQL: they carry meta-commands,
// COPY payloads and statements written specifically to be rejected. Handing a
// whole file to the parser therefore fails on the first `\set`, so the text is
// scanned into statements first and each is parsed on its own — a statement the
// parser rejects then costs one statement rather than the rest of the file.
//
// The scan has to understand every construct a `;` can hide inside, or one
// semicolon in a string literal desynchronises everything after it.
function splitStatements(text) {
  const statements = [];
  let start = 0;
  let i = 0;

  const endOfLine = (from) => {
    const newline = text.indexOf("\n", from);
    return newline === -1 ? text.length : newline + 1;
  };

  const flush = (end, next) => {
    const statement = text.slice(start, end).trim();
    if (statement !== "") statements.push(statement);
    start = next;
    return statement;
  };

  while (i < text.length) {
    const ch = text[i];

    if (text.startsWith("--", i)) {
      i = endOfLine(i);
      continue;
    }

    // PostgreSQL's block comments nest, so a `/*` inside one has to be counted
    // rather than scanned past.
    if (text.startsWith("/*", i)) {
      let depth = 1;
      i += 2;
      while (i < text.length && depth > 0) {
        if (text.startsWith("/*", i)) { depth++; i += 2; }
        else if (text.startsWith("*/", i)) { depth--; i += 2; }
        else i++;
      }
      continue;
    }

    if (ch === "'") {
      // In an escape string (`E'…'`) a backslash escapes the next character, so
      // `E'\''` is one string and not the start of two.
      const escapes = /^[Ee]$/.test(text[i - 1] ?? "") &&
        !/^[A-Za-z0-9_]$/.test(text[i - 2] ?? "");
      i++;
      while (i < text.length) {
        if (escapes && text[i] === "\\") i += 2;
        else if (text[i] === "'" && text[i + 1] === "'") i += 2;
        else if (text[i] === "'") { i++; break; }
        else i++;
      }
      continue;
    }

    if (ch === '"') {
      i++;
      while (i < text.length) {
        if (text[i] === '"' && text[i + 1] === '"') i += 2;
        else if (text[i] === '"') { i++; break; }
        else i++;
      }
      continue;
    }

    // `$tag$…$tag$`, but not `$1` — a positional parameter is not a quote.
    const dollar = ch === "$" ? text.slice(i).match(/^\$([A-Za-z_][A-Za-z0-9_]*)?\$/) : null;
    if (dollar) {
      const close = text.indexOf(dollar[0], i + dollar[0].length);
      i = close === -1 ? text.length : close + dollar[0].length;
      continue;
    }

    // A psql meta-command runs to the end of its line and terminates whatever
    // statement precedes it — which is what `SELECT 1 AS x \gset` relies on.
    if (ch === "\\") {
      flush(i, endOfLine(i));
      i = start;
      continue;
    }

    if (ch === ";") {
      const statement = flush(i, i + 1);
      i++;

      // `COPY … FROM stdin` is followed by raw data terminated by a lone `\.`.
      // Those lines are not SQL and would desynchronise the scan, so they are
      // stepped over as a block rather than parsed and discarded one by one.
      if (/\bcopy\b[\s\S]*\bfrom\s+stdin\b/i.test(statement)) {
        const terminator = text.indexOf("\n\\.", i);
        i = terminator === -1 ? text.length : endOfLine(terminator + 1);
        start = i;
      }
      continue;
    }

    i++;
  }

  flush(text.length, text.length);
  return statements;
}

// --- the denominator -------------------------------------------------------

function measureCorpus(dir) {
  const files = readdirSync(dir).filter((name) => name.endsWith(".sql")).sort();
  if (!files.length) die(`no .sql files in "${dir}".`);

  const all = new Map();
  const dml = new Map();
  let parsed = 0;
  let skipped = 0;
  let dmlParsed = 0;

  for (const file of files) {
    for (const statement of splitStatements(readFileSync(join(dir, file), "utf8"))) {
      const stmts = parse(statement);
      if (stmts === null) {
        skipped++;
        continue;
      }

      for (const stmt of stmts) {
        parsed++;
        // `stmt.stmt` rather than `stmt`, so the `RawStmt` wrapper — an artefact
        // of parsing, present once per statement whatever the statement is —
        // stays out of both histograms.
        countNodes(stmt.stmt, null, all);

        if (DML_STATEMENTS.has(statementKind(stmt))) {
          dmlParsed++;
          countNodes(stmt.stmt, null, dml);
        }
      }
    }
  }

  return { files, all, dml, parsed, skipped, dmlParsed };
}

// --- rendering -------------------------------------------------------------

const pct = (part, whole) => (whole === 0 ? "0.0%" : `${((part / whole) * 100).toFixed(1)}%`);
const num = (n) => n.toLocaleString("en-US");

function tally(histogram, supported) {
  const rows = [...histogram.entries()]
    .map(([node, count]) => ({ node, count, supported: supported.has(node) }))
    .sort((a, b) => b.count - a.count || a.node.localeCompare(b.node));

  const occurrences = rows.reduce((total, row) => total + row.count, 0);
  const covered = rows.filter((row) => row.supported);

  return {
    rows,
    occurrences,
    coveredOccurrences: covered.reduce((total, row) => total + row.count, 0),
    types: rows.length,
    coveredTypes: covered.length,
  };
}

function scopeSection(title, note, stats, top) {
  const unsupported = stats.rows.filter((row) => !row.supported);
  const shown = top === 0 ? unsupported : unsupported.slice(0, top);
  const omitted = unsupported.length - shown.length;

  return `### ${title}

${note}

| Measure | Covered | Total | Coverage |
|---|---:|---:|---:|
| Node types (distinct) | ${num(stats.coveredTypes)} | ${num(stats.types)} | ${pct(stats.coveredTypes, stats.types)} |
| Node occurrences (weighted) | ${num(stats.coveredOccurrences)} | ${num(stats.occurrences)} | ${pct(stats.coveredOccurrences, stats.occurrences)} |

Unsupported node types, most frequent first — the to-do list, ranked by how
often the construct actually turns up:

| Node type | Occurrences | Share of scope |
|---|---:|---:|
${shown.map((row) => `| \`${row.node}\` | ${num(row.count)} | ${pct(row.count, stats.occurrences)} |`).join("\n")}
${omitted ? `\n_${num(omitted)} rarer node types omitted; rerun with \`--top 0\` for the full list._\n` : ""}`;
}

function render({ sqld, corpus, top }) {
  const allStats = tally(corpus.all, sqld.nodes);
  const dmlStats = tally(corpus.dml, sqld.nodes);

  const emitted = [...sqld.nodes]
    .map((node) => ({ node, count: corpus.all.get(node) ?? 0 }))
    .sort((a, b) => b.count - a.count || a.node.localeCompare(b.node));

  const unused = emitted.filter((row) => row.count === 0).map((row) => row.node);

  return `# Grammar coverage

Measured ${new Date().toISOString().slice(0, 10)} against PostgreSQL's regression
suite with libpg-query ${parserVersion}. Regenerate with \`make coverage\`; the
prerequisites are documented at the top of
[scripts/coverage-report.mjs](scripts/coverage-report.mjs).

**sqld covers ${num(dmlStats.coveredTypes)} of the ${num(dmlStats.types)} distinct parse-tree node types that PostgreSQL's
regression suite uses in \`SELECT\`, \`INSERT\`, \`UPDATE\` and \`DELETE\`
statements (${pct(dmlStats.coveredTypes, dmlStats.types)}) — ${pct(dmlStats.coveredOccurrences, dmlStats.occurrences)} of those statements' node occurrences by
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
parameterised and inline forms. \`Test.Sqld.CorpusSpec\` already fails the build
if an AST constructor exists that no corpus entry builds, so the corpus tracks
the AST and this number tracks the corpus.

## Corpus measured

| | |
|---|---|
| Source | \`${REGRESS_DIR}\`${corpus.pgVersion ? `, PostgreSQL ${corpus.pgVersion}` : ""} |
| Files | ${num(corpus.files.length)} |
| Statements parsed | ${num(corpus.parsed)} |
| — of which \`SELECT\`/\`INSERT\`/\`UPDATE\`/\`DELETE\` | ${num(corpus.dmlParsed)} |
| Statements skipped | ${num(corpus.skipped)} |
| Node occurrences | ${num(allStats.occurrences)} |
| Distinct node types | ${num(allStats.types)} |
| sqld corpus entries | ${num(sqld.entries)} |

Skipped statements are the ones PostgreSQL's parser rejects: the regression
suite deliberately includes malformed SQL to test error messages, alongside
\`COPY\` payloads and psql meta-commands that are not SQL at all. They
contribute to neither side of the ratio.

## Coverage

${scopeSection(
  "SELECT, INSERT, UPDATE and DELETE",
  "The denominator a query builder is actually measured against.",
  dmlStats,
  top,
)}
${scopeSection(
  "Every statement in the suite",
  "The unrestricted figure, including DDL, transaction control and roles — statements sqld does not set out to emit.",
  allStats,
  top,
)}
## Node types sqld emits

Counts are occurrences across the whole suite, so a node sqld supports that the
suite happens never to use shows as 0.${unused.length ? ` ${num(unused.length)}: ${unused.map((n) => `\`${n}\``).join(", ")}.` : ""}

| Node type | Occurrences in suite |
|---|---:|
${emitted.map((row) => `| \`${row.node}\` | ${num(row.count)} |`).join("\n")}
`;
}

// --- main ------------------------------------------------------------------

console.error(`coverage-report: reading ${SQLD_CORPUS_PATH}`);
const sqld = supportedNodes();

if (sqld.rejected.length) {
  die(
    `PostgreSQL's parser rejected SQL emitted by sqld, so the supported-node set ` +
      `cannot be trusted.\nAffected corpus entries: ${[...new Set(sqld.rejected)].join(", ")}`,
  );
}

console.error(`coverage-report: parsing ${regressDir}/*.sql`);
const corpus = measureCorpus(regressDir);

// The one place the report names a PostgreSQL version, taken from the tree that
// supplied the corpus rather than from the parser that read it. Cosmetic, so a
// tree that keeps its version somewhere else costs a line of the header and
// nothing more.
corpus.pgVersion = (() => {
  const configure = join(options.pgSource, "configure.ac");
  if (!existsSync(configure)) return null;
  return readFileSync(configure, "utf8").match(/AC_INIT\(\[PostgreSQL\], \[([^\]]+)\]/)?.[1] ?? null;
})();

const report = render({ sqld, corpus, top: options.top });

if (options.stdout) {
  process.stdout.write(report);
} else {
  writeFileSync(options.out, report);
  console.error(`coverage-report: wrote ${options.out}`);
}
