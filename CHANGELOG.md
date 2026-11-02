# Changelog

Lattice is not released yet. This log tracks the work toward Milestone 1 of [`specs/LATTICE_SPEC.md`](specs/LATTICE_SPEC.md).

## Unreleased — Org-style TODO keywords

### Changed (breaking)

- Personal tasks are now items whose first word is an org-mode style keyword: `- TODO Send update`, `## NEXT Draft plan`. They can sit anywhere in a note, at any nesting depth. The `To Do` heading is no longer recognized, so existing `## To Do` bullets need a keyword (`- TODO ...`) to appear.
- Keywords match exactly, as in org-mode (`TODO`, not `todo` or `To Do`).
- `<leader>lt` / `:LatticeAddTodo` adds `- TODO <task>` below the cursor instead of under a heading, so there is no heading prompt.
- `headings.todo` in `.lattice.json` is ignored, with a notice.

### Added

- Keyword sequences such as `TODO NEXT | DONE CANCELED`, following org's `#+TODO:` rules (`|` splits open and done states; fast-access suffixes are ignored).
- Root sequences come from `todo` in `.lattice.json` (default `TODO | DONE`). Per-note sequences come from a YAML front matter `todo:` key, which replaces the root ones for that note. Invalid front matter is a jumpable warning, and the note falls back to the root sequences.
- Dashboard rows show each item's state, and a **DONE** group lists done-state items, most recently modified note first.
- `:LatticeHealth` lists the root sequences and front matter problems.

## Milestone 1 (merged in #1)

### Added

- Dashboard sections **OVERDUE** (oldest first) and **DUE SOON** (today through 7 days ahead, soonest first). A task can appear in both its owner group and a date group.
- Dashboard header with today's date, the scanned root and note count, an empty state that explains the heading convention, and the footer `Enter / r / q / ?`.
- `?` toggles keyboard and command help in the dashboard.
- The dashboard window turns off line numbers, sign column and wrapping, which LazyVim enables by default.
- `:LatticeHealth` (`:checkhealth lattice`) reports the root, config status, counts, unreadable paths, invalid dates with file and line, and skipped keymaps. The dashboard's WARNINGS block lists the same problems, and `Enter` opens an invalid date's line.
- `:LatticeAddTodo` and `:LatticeAddWaiting` commands, so insertion works with keymaps turned off.
- Insertion asks before creating a missing heading. Declining or cancelling leaves the buffer untouched.
- With repeated headings, insertion uses the section containing the cursor, else the nearest one above it, else the first.
- The Waiting On assignee is optional and asked for first.
- Keymaps never replace an existing global mapping. Conflicts are skipped with a warning, listed in `:LatticeHealth`, and left out of the dashboard help. Buffer-local mappings aren't conflicts. Re-running `setup` removes the previous run's keys. Invalid keymap values are reported and ignored rather than breaking setup.
- Adding a task warns when the item lands inside an unclosed code fence, where Lattice can't see it.
- `.git/**` added to the default excludes. `.git` directories are also skipped even when a custom exclude list omits them.
- `doc/lattice.txt` (`:help lattice`), `specs/LATTICE_SPEC.md`, this changelog, and a fuller README with limitations and troubleshooting.
- Tests split into `parser_spec`, `scanner_spec`, `dashboard_spec` and `insert_spec`, still run with `nvim -l tests/run.lua`. New coverage includes symlink cycles, `.git` skipping, empty notes, the 2/2/1 fixture, due-soon window edges, keymap conflicts, unsaved-buffer preservation, health reporting, and the sample notes.

### Changed

- Insertion code moved from `init.lua` to `insert.lua`.
- `examples/meeting-notes.md` renamed to `examples/sample-notes.md` and extended with edge cases.
- The header date uses English names whatever the system locale, to match the rows.
- Dates render as `Nov 05` (and `Nov 05, 2027` outside the current year). Waiting On rows read `Name — task`.

### Kept from the initial version

- Strict `To Do` / `Waiting On` parsing, `.lattice.json` scanning, source navigation, manual refresh.
- The read-only capture **INBOX** group and the optional `[promised:YYYY-MM-DD]` tag, both recorded as decisions in `specs/product-vision.md` (2026-11-01). They go beyond LATTICE_SPEC.md but don't conflict with it.

### Deferred (not implemented)

- File watching or background indexing; refresh is manual.
- A completion command (mark `[x]` by editing).
- Following symlinks that stay inside the root. All symlinks are skipped, which is the simpler safe choice.
- Multi-word assignees.
- WBR preparation, AI-assisted commitment discovery, Portico publishing, automated Drafts import (Milestones 3–6).
- A license, which the repository owner will choose.
