## What this changes

<!-- One or two sentences. Link the issue if there is one: Closes #123 -->

## SQL before / after

<!-- If this changes emitted SQL, show it. Delete this section if it doesn't. -->

```sql
-- before

-- after
```

## Checklist

- [ ] `make validate` passes locally (tests **and** replay against PostgreSQL)
- [ ] New `Sqld.Core` constructors have a `test/Sqld/Corpus.purs` entry
- [ ] Any new tables/columns exist in `test/fixtures/schema.sql`
- [ ] `make examples-check` passes, or `EXAMPLES.md` was regenerated via `make examples`
- [ ] `CHANGELOG.md` updated under `[Unreleased]`

## Notes for the reviewer

<!-- Trade-offs, alternatives you rejected, anything you're unsure about. -->
