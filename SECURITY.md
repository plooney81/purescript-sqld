# Security Policy

## Supported versions

`sqld` is pre-1.0 and not yet published to the PureScript registry. Only the
latest commit on `main` receives fixes.

| Version | Supported |
| ------- | --------- |
| `main`  | ✅        |
| Older tags / forks | ❌ |

## What counts as a security issue here

`sqld` is a pure query builder: it turns a `Query` value into a SQL string and
an array of parameters. It never opens a connection and never executes
anything. The security-relevant surface is therefore narrow but real:

- **Injection through a value that should have been parameterised.** Every
  literal is meant to become a numbered param (`$1`, `$2`, …). If any input path
  ends up interpolated into the SQL string instead, that is a vulnerability.
- **Injection through identifier quoting.** Table, column, and alias names are
  quoted. A name that escapes its quotes — via an embedded `"`, a null byte, or
  any other input — is a vulnerability.
- **Param numbering or ordering bugs** that cause a value to bind to the wrong
  placeholder, since that can silently defeat an authorisation predicate in a
  `WHERE` clause.

Not security issues:

- `raw` emitting exactly what you passed it. `raw` is a documented escape hatch
  that opts out of quoting; passing untrusted input to it is a bug in the
  calling code.
- `formatInline` / `formatPretty` substituting values into the string. These are
  documented as debugging and logging helpers and must never be handed to a
  driver.

## Reporting a vulnerability

Please **do not open a public issue** for a suspected vulnerability.

Report it privately using GitHub's
[private vulnerability reporting](https://github.com/plooney81/purescript-sqld/security/advisories/new),
or by email to **petelooney81@gmail.com**.

Please include:

- the PureScript snippet that builds the `Query`,
- the SQL string and params `format` returned,
- what you expected instead, and
- why the difference is exploitable, if it is not obvious.

## What to expect

- **Acknowledgement** within 7 days.
- **An assessment** — confirmed, needs more information, or not a vulnerability
  — within 14 days.
- **A fix on `main`**, with a corpus entry covering the case so it cannot
  regress, and credit in the changelog unless you prefer otherwise.

Since nothing is published yet there is no advisory or backport process to
follow; once `sqld` is on the registry this section will be updated.
