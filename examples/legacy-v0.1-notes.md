---
title: November 2 — Project Review (Lattice v0.1 syntax)
todo: TODO NEXT WAITING | DONE CANCELED
---

# November 2 — Project Review

Synthetic example of the Lattice v0.1 syntax, which Lattice still reads:
keyword bullets, a `Waiting On` section with `@Name`, and inline `[due:]` /
`[promised:]` dates. See sample-notes.md for the Org-style equivalent.

- TODO Prepare revised staffing plan
- NEXT Send project update [due:2026-11-05]
- TODO Review budget [due:2026-10-30]
- DONE Review the completed migration
- CANCELED Book the offsite
  - TODO Nested items count when they start with a keyword

## Waiting On
- @Raju Provide deployment estimate [due:2026-11-06]
- [ ] @Asha Submit hiring feedback [due:2026-11-09] [promised:2026-11-07]
- [ ] Follow up with vendor
- DONE @Lee Send the signed contract

## NEXT Draft the Q1 plan

## Decisions
We agreed to revisit the release date next week.

- Plain bullets outside Waiting On are notes, not tasks
- todo and Todo are not keywords: matching is exact

```markdown
- TODO Examples inside code fences are ignored
```
