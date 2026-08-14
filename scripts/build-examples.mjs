#!/usr/bin/env node
// Renders EXAMPLES.md from the cookbook.
//
// The PureScript shown in the docs is sliced out of src/Example/Cookbook.purs
// rather than retyped into a string, and the SQL beneath it is what that code
// actually produced when the test suite ran it. Neither half can drift from the
// other, and the corpus harness has already proved PostgreSQL accepts the SQL.
//
// Usage:
//   spago test                       # emits test-artifacts/examples.json
//   node scripts/build-examples.mjs  # writes EXAMPLES.md
//   node scripts/build-examples.mjs --check   # fails if EXAMPLES.md is stale
//
// Source format — markers delimit the slices:
//
//   -- #example some-name        <- must match a `cookbook` entry
//   -- # Human readable title
//   -- Free prose, one or more lines.
//   someName :: Query
//   someName = ...
//
//   -- #end                      <- everything after this is ignored

import { existsSync, readFileSync, writeFileSync } from "node:fs";

const SOURCE = "src/Example/Cookbook.purs";
const EXAMPLES_JSON = "test-artifacts/examples.json";
const OUTPUT = "EXAMPLES.md";

const check = process.argv.includes("--check");

function die(message) {
  console.error(`\nbuild-examples: ${message}\n`);
  process.exit(1);
}

// --- parse the source ------------------------------------------------------

function parseSource(text) {
  const lines = text.split("\n");
  const blocks = [];
  let current = null;

  for (const line of lines) {
    const marker = line.match(/^--\s*#example\s+(\S+)\s*$/);

    if (marker) {
      current = { name: marker[1], title: null, description: [], code: [] };
      blocks.push(current);
      continue;
    }

    if (/^--\s*#end\s*$/.test(line)) break;
    if (!current) continue;

    const title = line.match(/^--\s*#\s+(.+?)\s*$/);
    if (title && current.title === null && !current.code.length) {
      current.title = title[1];
      continue;
    }

    const prose = line.match(/^--\s?(.*)$/);
    if (prose && !current.code.length) {
      current.description.push(prose[1]);
      continue;
    }

    current.code.push(line);
  }

  for (const block of blocks) {
    // Declarations are separated by blank lines, so a block picks up the
    // trailing gap before the next marker.
    while (block.code.length && block.code.at(-1).trim() === "") block.code.pop();
    if (!block.title) die(`example "${block.name}" has no "-- # Title" line`);
    if (!block.code.length) die(`example "${block.name}" has no code`);
  }

  return blocks;
}

// --- load and cross-check --------------------------------------------------

if (!existsSync(EXAMPLES_JSON)) {
  die(`${EXAMPLES_JSON} not found. Run \`spago test\` first.`);
}

const blocks = parseSource(readFileSync(SOURCE, "utf8"));
const emitted = JSON.parse(readFileSync(EXAMPLES_JSON, "utf8"));

// The markers and the `cookbook` list are two hand-maintained halves of the
// same thing. Diff them rather than trusting they agree.
const inSource = blocks.map((b) => b.name);
const inCookbook = emitted.map((e) => e.name);

const missingFromCookbook = inSource.filter((n) => !inCookbook.includes(n));
const missingFromSource = inCookbook.filter((n) => !inSource.includes(n));

if (missingFromCookbook.length || missingFromSource.length) {
  const parts = [];
  if (missingFromCookbook.length)
    parts.push(`marked in ${SOURCE} but absent from \`cookbook\`: ${missingFromCookbook.join(", ")}`);
  if (missingFromSource.length)
    parts.push(`in \`cookbook\` but not marked with -- #example: ${missingFromSource.join(", ")}`);
  die(`example lists disagree.\n  ${parts.join("\n  ")}`);
}

if (inSource.join() !== inCookbook.join()) {
  die(
    `example order differs between ${SOURCE} and \`cookbook\`.\n` +
      `  source:   ${inSource.join(", ")}\n  cookbook: ${inCookbook.join(", ")}`,
  );
}

// --- render ----------------------------------------------------------------

const byName = Object.fromEntries(emitted.map((e) => [e.name, e]));

// Approximates GitHub's heading-anchor rules well enough for a table of
// contents: lowercase, drop punctuation, spaces to hyphens.
function anchor(title) {
  return title
    .toLowerCase()
    .replace(/[^\w\s-]/g, "")
    .trim()
    .replace(/\s+/g, "-");
}

function renderParams(params) {
  if (!params.length) return "";
  const rendered = params
    .map((p, i) => `\`$${i + 1}\` = \`${p === null ? "NULL" : JSON.stringify(p)}\``)
    .join(", ");
  return `\nBound parameters: ${rendered}\n`;
}

const body = blocks
  .map((block) => {
    const { sql, params, prettySql } = byName[block.name];
    const description = block.description.join("\n").trim();

    return [
      `## ${block.title}`,
      "",
      description,
      "",
      "```purescript",
      block.code.join("\n"),
      "```",
      "",
      "```sql",
      prettySql,
      "```",
      renderParams(params),
      `<sub>Parameterised: <code>${sql}</code></sub>`,
    ].join("\n");
  })
  .join("\n\n---\n\n");

const contents = blocks.map((b) => `- [${b.title}](#${anchor(b.title)})`).join("\n");

const page = `# sqld by example

<!-- Generated from ${SOURCE} by scripts/build-examples.mjs. Do not edit by hand. -->

Every example below is a real \`Query\` that compiles, and every SQL block is
what that code actually produced. The validation harness replays each one
against a live PostgreSQL server, so nothing here can be a query PostgreSQL
would reject.

The SQL blocks show literals inline for readability. \`format\` emits the same
query with each literal replaced by a numbered parameter and returns the
bindings alongside it — that parameterised form is shown in small text under
each example, and is what you pass to your driver.

Regenerate with \`make examples\`.

## Contents

${contents}

---

${body}
`;

if (check) {
  const existing = existsSync(OUTPUT) ? readFileSync(OUTPUT, "utf8") : "";
  if (existing !== page) {
    die(
      `${OUTPUT} is out of date. Run \`make examples\` and commit the result.`,
    );
  }
  console.log(`build-examples: ${OUTPUT} is up to date (${blocks.length} examples)`);
} else {
  writeFileSync(OUTPUT, page);
  console.log(`build-examples: wrote ${OUTPUT} (${blocks.length} examples)`);
}
