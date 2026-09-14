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
// Alongside the corpus it replays the queries `Test.Sqld.Generate` produced,
// which is the same property applied to queries nobody wrote down. Those run in
// batches — one psql session per fifty statements rather than one per statement
// — so a few hundred of them cost seconds rather than a minute, and the script
// only falls back to running a batch statement by statement once that batch has
// failed and it needs to say which one.
//
// Usage:
//   spago test                                    # emits test-artifacts/*.json
//   node scripts/validate-sql.mjs                 # corpus and generated queries
//   node scripts/validate-sql.mjs --only join     # just the entries matching "join"
//   node scripts/validate-sql.mjs --sql 'SELECT 1'  # probe an ad-hoc query
//   node scripts/validate-sql.mjs --list          # list corpus entry names
//
// Configuration:
//   DATABASE_URL        connection URI (default: local throwaway database)
//   SQLD_ALLOW_ANY_DB   set to 1 to bypass the disposable-database guard
//   SQLD_GEN_SEED       (read by `spago test`) regenerate a given run
//   SQLD_GEN_COUNT      (read by `spago test`) how many queries to generate
//   SQLD_GEN_SHRINK     (read by `spago test`) emit shrink candidates too

import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";

const CORPUS_PATH = "test-artifacts/corpus.json";
const GENERATED_PATH = "test-artifacts/generated.json";
const SCHEMA_PATH = "test/fixtures/schema.sql";
const DEFAULT_URL = "postgres://postgres:postgres@localhost:5432/sqld_validate";

// PostgreSQL cannot always infer a placeholder's type from context (`SELECT $1
// IS NULL` has nothing to unify against). That is a limitation of the
// parameterised form, not a malformed query — the inline form still gets full
// validation — so it is reported as a warning rather than a failure.
const INDETERMINATE_DATATYPE = "42P18";

// How many PREPAREs share one psql session. Large enough that process startup
// stops dominating, small enough that one failure only costs a re-run of fifty.
const BATCH_SIZE = 50;

const conn = process.env.DATABASE_URL ?? DEFAULT_URL;

function die(message) {
  console.error(`\nvalidate-sql: ${message}\n`);
  process.exit(1);
}

// --- arguments -------------------------------------------------------------

const USAGE = `Usage: node scripts/validate-sql.mjs [options]

  --only <pattern>   validate only entries whose name contains <pattern>
  --sql <query>      validate a single ad-hoc query instead of the corpus
  --list             list corpus entry names and exit
  --no-generated     skip the generated queries, replay only the corpus
  --generated-only   skip the corpus, replay only the generated queries
  -h, --help         show this message

Environment:
  DATABASE_URL       connection URI
                     (default: ${DEFAULT_URL})
  SQLD_ALLOW_ANY_DB  set to 1 to bypass the disposable-database guard`;

function parseArgs(argv) {
  const options = { only: null, sql: null, list: false, generated: true, corpus: true };

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
      case "--no-generated":
        options.generated = false;
        break;
      case "--generated-only":
        options.corpus = false;
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

  if (!options.generated && !options.corpus) {
    die("--no-generated and --generated-only are mutually exclusive.");
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

// --- generated queries -----------------------------------------------------

// Absent when the suite was run with SQLD_GEN_COUNT=0, and on a tree built
// before the generator existed. Either way there is simply nothing to replay.
function loadGenerated() {
  if (!existsSync(GENERATED_PATH)) return null;
  const set = JSON.parse(readFileSync(GENERATED_PATH, "utf8"));
  return set.entries.length ? set : null;
}

let entries = [];
let generated = null;

if (options.sql !== null) {
  // Ad-hoc probes carry no parameter list, so the placeholder cross-check and
  // the inline form do not apply.
  entries = [{ name: "ad-hoc", sql: options.sql, inlineSql: null, params: null }];
} else {
  if (options.corpus) entries = loadCorpus();
  if (options.generated) generated = loadGenerated();

  if (options.only !== null) {
    const needle = options.only.toLowerCase();
    const matches = (entry) => entry.name.toLowerCase().includes(needle);

    entries = entries.filter(matches);
    if (generated !== null) generated.entries = generated.entries.filter(matches);

    if (!entries.length && !generated?.entries.length) {
      die(
        `no entry matches "${options.only}".\n` +
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

const generatedEntries = generated?.entries ?? [];
const total = entries.length + generatedEntries.length;

console.log(`validate-sql: ${total} ${total === 1 ? "query" : "queries"}`);
if (generatedEntries.length) {
  console.log(`validate-sql: ${generatedEntries.length} of them generated from seed ${generated.seed}`);
}
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

// --- generated queries -----------------------------------------------------

// Every statement of a batch in one psql session, each PREPARE under a name of
// its own. ON_ERROR_STOP makes the session give up at the first failure, which
// is why a failing batch is re-run statement by statement rather than having
// its output parsed apart: the statements after the first error never ran.
function runBatch(sqls) {
  return runSql(sqls.map((sql, i) => `PREPARE sqld_batch_${i} AS ${sql};`).join("\n"));
}

// The shrink candidates arrive smallest-first, so the first one that still
// fails is the smallest counterexample the shrinker could reach — the same
// answer a shrinking loop converges on. Absent unless the suite ran with
// SQLD_GEN_SHRINK=1.
function smallestFailing(entry, form) {
  for (const candidate of entry.shrinks ?? []) {
    const sql = form === "format" ? candidate.sql : candidate.inlineSql;
    if (checkPrepares(sql).status === "fail") return sql;
  }
  return null;
}

function validateGenerated(set) {
  const troubled = new Map();
  const record = (entry, problem) => {
    if (!troubled.has(entry.name)) troubled.set(entry.name, { entry, problems: [] });
    troubled.get(entry.name).problems.push(problem);
  };

  const items = [];

  for (const entry of set.entries) {
    const mismatch = checkPlaceholders(entry);
    if (mismatch) record(entry, { form: "params", status: "fail", detail: mismatch });
    items.push({ entry, form: "format", sql: entry.sql });
    items.push({ entry, form: "formatInline", sql: entry.inlineSql });
  }

  for (let i = 0; i < items.length; i += BATCH_SIZE) {
    const batch = items.slice(i, i + BATCH_SIZE);
    // If the whole batch prepares there is nothing more to learn from it, and
    // that is the overwhelmingly common case.
    if (runBatch(batch.map((item) => item.sql)) === null) continue;

    for (const item of batch) {
      const result = checkPrepares(item.sql);
      if (result.status === "pass") continue;
      record(item.entry, {
        form: item.form,
        ...result,
        sql: item.sql,
        shrunk: result.status === "fail" ? smallestFailing(item.entry, item.form) : null,
      });
    }
  }

  for (const { entry, problems } of troubled.values()) {
    const failed = problems.filter((p) => p.status === "fail");

    if (failed.length) {
      failures.push({ entry, problems: failed });
      console.log(`  FAIL  ${entry.name}`);
    } else {
      warnings.push({ entry, problems });
      console.log(`  WARN  ${entry.name}`);
    }
  }

  const clean = set.entries.length - troubled.size;
  console.log(`  ok    ${clean} generated ${clean === 1 ? "query" : "queries"}`);

  return [...troubled.values()].some(({ problems }) => problems.some((p) => p.status === "fail"));
}

const generatedFailed = generatedEntries.length ? validateGenerated(generated) : false;

// --- reporting -------------------------------------------------------------

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
      if (problem.shrunk) {
        console.log(`  smallest failing shrink:`);
        console.log(`    ${problem.shrunk}`);
      }
    }
  }
}

report("Warnings", warnings);
report("Failures", failures);

// A generated failure is only actionable if it can be seen again, and the seed
// is the whole of what that takes: generation is pure.
if (generatedFailed) {
  const label = "Reproducing";
  console.log(`\n${label}\n${"=".repeat(label.length)}\n`);
  console.log(`  The generated queries above came from seed ${generated.seed}:\n`);
  console.log(`    SQLD_GEN_SEED=${generated.seed} make validate\n`);

  if (!generated.shrinks) {
    console.log(`  Add SQLD_GEN_SHRINK=1 to cut the counterexample down to something readable:\n`);
    console.log(`    SQLD_GEN_SEED=${generated.seed} SQLD_GEN_SHRINK=1 make validate\n`);
  }

  console.log(`  A bug found this way belongs in test/Sqld/Corpus.purs as a regression entry.`);
}

console.log(
  `\nvalidate-sql: ${total - failures.length - warnings.length} passed, ` +
    `${warnings.length} warned, ${failures.length} failed`,
);

process.exit(failures.length ? 1 : 0);
