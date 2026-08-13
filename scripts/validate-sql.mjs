#!/usr/bin/env node
// Replays the emitted query corpus against a real PostgreSQL server.
//
// Golden tests prove sqld emits the string we expected. They do not prove
// PostgreSQL accepts it. This script closes that gap: every corpus entry is fed
// to the server via PREPARE, which runs the full parser AND parse analysis, so
// bad syntax, unknown columns, invalid GROUP BY and operator type mismatches
// all fail here.
//
// Both formatter outputs are checked:
//   * `sql`       — the parameterised form from `Sqld.Format.format`
//   * `inlineSql` — the debug form from `Sqld.Format.formatInline`
//
// Usage:
//   spago test                                    # emits test-artifacts/corpus.json
//   node scripts/validate-sql.mjs                 # validate the whole corpus
//   node scripts/validate-sql.mjs --only join     # just the entries matching "join"
//   node scripts/validate-sql.mjs --sql 'SELECT 1'  # probe an ad-hoc query
//   node scripts/validate-sql.mjs --list          # list corpus entry names
//
// Configuration:
//   DATABASE_URL        connection URI (default: local throwaway database)
//   SQLD_ALLOW_ANY_DB   set to 1 to bypass the disposable-database guard

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";

const CORPUS_PATH = "test-artifacts/corpus.json";
const SCHEMA_PATH = "test/fixtures/schema.sql";
const DEFAULT_URL = "postgres://postgres:postgres@localhost:5432/sqld_validate";

// PostgreSQL cannot always infer a placeholder's type from context (`SELECT $1
// IS NULL` has nothing to unify against). That is a limitation of the
// parameterised form, not a malformed query — the inline form still gets full
// validation — so it is reported as a warning rather than a failure.
const INDETERMINATE_DATATYPE = "42P18";

const conn = process.env.DATABASE_URL ?? DEFAULT_URL;

function die(message) {
  console.error(`\nvalidate-sql: ${message}\n`);
  process.exit(1);
}

// --- arguments -------------------------------------------------------------

const USAGE = `Usage: node scripts/validate-sql.mjs [options]

  --only <pattern>   validate only corpus entries whose name contains <pattern>
  --sql <query>      validate a single ad-hoc query instead of the corpus
  --list             list corpus entry names and exit
  -h, --help         show this message

Environment:
  DATABASE_URL       connection URI
                     (default: ${DEFAULT_URL})
  SQLD_ALLOW_ANY_DB  set to 1 to bypass the disposable-database guard`;

function parseArgs(argv) {
  const options = { only: null, sql: null, list: false };

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const takeValue = (name) => {
      const value = argv[++i];
      if (value === undefined) die(`${name} requires a value.\n\n${USAGE}`);
      return value;
    };

    switch (arg) {
      case "--only":
        options.only = takeValue("--only");
        break;
      case "--sql":
        options.sql = takeValue("--sql");
        break;
      case "--list":
        options.list = true;
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

  if (options.sql !== null && options.only !== null) {
    die("--sql and --only are mutually exclusive.");
  }

  return options;
}

const options = parseArgs(process.argv.slice(2));

// --- corpus ----------------------------------------------------------------

function loadCorpus() {
  if (!existsSync(CORPUS_PATH)) {
    die(`${CORPUS_PATH} not found. Run \`spago test\` first to emit the corpus.`);
  }
  return JSON.parse(readFileSync(CORPUS_PATH, "utf8"));
}

// Listing needs neither a database nor the disposable-database guard.
if (options.list) {
  for (const entry of loadCorpus()) console.log(entry.name);
  process.exit(0);
}

let entries;

if (options.sql !== null) {
  // Ad-hoc probes carry no parameter list, so the placeholder cross-check and
  // the inline form do not apply.
  entries = [{ name: "ad-hoc", sql: options.sql, inlineSql: null, params: null }];
} else {
  entries = loadCorpus();

  if (options.only !== null) {
    const needle = options.only.toLowerCase();
    entries = entries.filter((entry) => entry.name.toLowerCase().includes(needle));

    if (!entries.length) {
      die(
        `no corpus entry matches "${options.only}".\n` +
          `Run \`node scripts/validate-sql.mjs --list\` to see the available names.`,
      );
    }
  }
}

// --- guards ----------------------------------------------------------------

function assertDisposableDatabase(url) {
  if (process.env.SQLD_ALLOW_ANY_DB === "1") return;

  let name;
  try {
    name = new URL(url).pathname.replace(/^\//, "");
  } catch {
    die(
      `could not parse DATABASE_URL as a URI, so the disposable-database guard ` +
        `cannot run.\nApplying ${SCHEMA_PATH} DROPs and recreates the public schema. ` +
        `Set SQLD_ALLOW_ANY_DB=1 only if the target is throwaway.`,
    );
  }

  if (!/(sqld|validate|test|ci)/i.test(name)) {
    die(
      `refusing to run against database "${name}".\n` +
        `Applying ${SCHEMA_PATH} DROPs and recreates the public schema, destroying ` +
        `everything in it.\nPoint DATABASE_URL at a throwaway database (a name ` +
        `containing "sqld", "validate", "test" or "ci"), or set SQLD_ALLOW_ANY_DB=1 ` +
        `if you are certain.`,
    );
  }
}

// --- psql ------------------------------------------------------------------

// Runs SQL in a fresh psql session. Returns null on success, or the server's
// error text. Verbose output puts the SQLSTATE in the ERROR line, which is how
// we classify failures.
function runSql(sql) {
  try {
    execFileSync("psql", [conn, "-X", "-q", "-v", "ON_ERROR_STOP=1"], {
      input: `\\set VERBOSITY verbose\n${sql}\n`,
      stdio: ["pipe", "pipe", "pipe"],
      encoding: "utf8",
    });
    return null;
  } catch (err) {
    if (err.code === "ENOENT") {
      die("psql not found on PATH. Install the PostgreSQL client tools.");
    }
    return (err.stderr ?? String(err)).trim();
  }
}

function sqlState(errorText) {
  return errorText.match(/ERROR:\s+([0-9A-Z]{5}):/)?.[1] ?? null;
}

// Verbose errors carry a LOCATION line pointing into the Postgres C source,
// which is noise for this audience.
function tidy(errorText) {
  return errorText
    .split("\n")
    .filter((line) => !/^LOCATION:/.test(line))
    .map((line) => line.replace(/^psql:<stdin>:\d+:\s*/, ""))
    .join("\n");
}

// --- checks ----------------------------------------------------------------

function checkPlaceholders(entry) {
  const highest = [...entry.sql.matchAll(/\$(\d+)/g)]
    .map((m) => Number(m[1]))
    .reduce((a, b) => Math.max(a, b), 0);

  if (highest !== entry.params.length) {
    return (
      `placeholder/parameter mismatch: highest placeholder is $${highest} but ` +
      `${entry.params.length} parameter(s) were bound`
    );
  }
  return null;
}

function checkPrepares(sql) {
  const error = runSql(`PREPARE sqld_validate_stmt AS ${sql};`);
  if (error === null) return { status: "pass" };
  if (sqlState(error) === INDETERMINATE_DATATYPE) {
    return { status: "warn", detail: tidy(error) };
  }
  return { status: "fail", detail: tidy(error) };
}

// --- main ------------------------------------------------------------------

assertDisposableDatabase(conn);

console.log(`validate-sql: ${entries.length} ${entries.length === 1 ? "query" : "queries"}`);
console.log(`validate-sql: applying ${SCHEMA_PATH}\n`);

try {
  execFileSync("psql", [conn, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", SCHEMA_PATH], {
    stdio: ["ignore", "pipe", "pipe"],
    encoding: "utf8",
  });
} catch (err) {
  if (err.code === "ENOENT") die("psql not found on PATH.");
  die(`could not apply ${SCHEMA_PATH}:\n\n${(err.stderr ?? String(err)).trim()}`);
}

const failures = [];
const warnings = [];

for (const entry of entries) {
  const problems = [];

  if (entry.params !== null) {
    const mismatch = checkPlaceholders(entry);
    if (mismatch) problems.push({ form: "params", status: "fail", detail: mismatch });
  }

  const forms = [["format", entry.sql]];
  if (entry.inlineSql !== null) forms.push(["formatInline", entry.inlineSql]);

  for (const [form, sql] of forms) {
    const result = checkPrepares(sql);
    if (result.status !== "pass") problems.push({ form, ...result, sql });
  }

  const failed = problems.filter((p) => p.status === "fail");
  const warned = problems.filter((p) => p.status === "warn");

  if (failed.length) {
    failures.push({ entry, problems: failed });
    console.log(`  FAIL  ${entry.name}`);
  } else if (warned.length) {
    warnings.push({ entry, problems: warned });
    console.log(`  WARN  ${entry.name}`);
  } else {
    console.log(`  ok    ${entry.name}`);
  }
}

function report(label, items) {
  if (!items.length) return;
  console.log(`\n${label}\n${"=".repeat(label.length)}`);
  for (const { entry, problems } of items) {
    for (const problem of problems) {
      console.log(`\n${entry.name} [${problem.form}]`);
      if (problem.sql) console.log(`  ${problem.sql}`);
      console.log(
        problem.detail
          .split("\n")
          .map((line) => `  ${line}`)
          .join("\n"),
      );
    }
  }
}

report("Warnings", warnings);
report("Failures", failures);

console.log(
  `\nvalidate-sql: ${entries.length - failures.length - warnings.length} passed, ` +
    `${warnings.length} warned, ${failures.length} failed`,
);

process.exit(failures.length ? 1 : 0);
