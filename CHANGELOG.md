# Changelog

## Unreleased — Org-mode for Markdown

Work toward [`specs/LATTICE_SYNTAX_SPEC.md`](specs/LATTICE_SYNTAX_SPEC.md) v0.2; plan and decisions in [`specs/ORG_MARKDOWN_PLAN.md`](specs/ORG_MARKDOWN_PLAN.md).

### Milestone A — Parser foundation

- `lattice.markdown`: Markdown block structure from Neovim's bundled Tree-sitter parser (headings with section ranges, list items with nesting and task markers, front matter; code blocks ignored).
- `lattice.tasks`: heading tasks, checkbox tasks (every marker form, including numbered), keyword bullets, inline states on checkboxes, multi-word states, checkbox/state conflict diagnostics, and the unified task tree with source ranges.
- Acceptance tests PAR-001 to PAR-006 and PAR-015. Not yet used by the dashboard.

### Milestone B — Metadata and workflows

- Planning lines (`SCHEDULED`, `DEADLINE`, `CLOSED`) and property drawers, read directly below a heading or inside a checkbox's list item, never from a neighbour (`lattice.metadata`, `lattice.timestamp`).
- Priorities (`[#A]` on headings, `:PRIORITY:` on checkboxes), tags (trailing `:a:b:` on headings, `:TAGS:` on checkboxes) with inheritance, and properties with configurable inheritance.
- `:STATE:` on checkboxes; the box decides completion, and disagreements are warnings.
- Workflows in `.lattice.json` (`workflows`, with multi-word states), chosen by `:WORKFLOW:`, by project, by front matter `todo:`, or `default`. Projects are optional: an inherited `:PROJECT:`, front matter `project:`, or a top-level heading naming a configured workflow.
- New `.lattice.json` keys: `workflows`, `priorities`, `inherit`, `deadlines.warning_days`.
- Diagnostics for invalid timestamps, weekday mismatches, malformed drawers, unknown states, priorities and workflows, state conflicts, and duplicate `:ID:`s within and across notes, on the dashboard and in `:LatticeHealth`.
- `:LatticeHealth` reports the Markdown parser, the workflows, and v0.1 syntax still in use.
- The scanner, dashboard and commands now use the new parser; `lattice.parser` is removed. Dashboard rows show priority and tags.

#### Changed

- **Every checkbox is a task**, as the spec says, including numbered ones (`1. [ ]`).
- The default workflow is `TODO NEXT WAITING | DONE CANCELED` (was `TODO | DONE`).
- `- [ ] DONE x` is open, because the box decides (was done). It is listed as a warning.
- Checked v0.1 `Waiting On` items now appear in DONE instead of being hidden.
- Lattice v0.1 syntax keeps working: `Waiting On` sections (items get `WAITING`), `@Name`, `[due:]`, `[promised:]`, front matter `todo:`.
- `examples/sample-notes.md` is now written in the Org style; the v0.1 example moved to `examples/legacy-v0.1-notes.md`.

### Milestone C — Scheduling engine

- `lattice.schedule`: calendar arithmetic without `os.time` (no time-zone or DST drift), Org's `+`, `++` and `.+` repeaters in hours, days, weeks, months and years, with Org's month-end overflow; deadline warning periods and scheduled delays converted as Org does; agenda status for deadlines and scheduled dates; the next SCHEDULED/DEADLINE for completing a repeating task.
- Dashboard: a new **TODAY** group (scheduled today or earlier and still open, deadlines today), DUE SOON based on each deadline's warning period (default `deadlines.warning_days`, 14), and `sched` dates on rows.
- Acceptance tests PAR-016 to PAR-021, the §15.3 fixture, and the §10.5 edge cases (early, late, missed occurrences, month ends, leap years, year rollover, both timestamps repeating, time of day).

#### Changed

- DUE SOON now uses deadline warning periods (default 14 days, Org's) instead of a fixed 7 days, and no longer includes today: deadlines due today are in TODAY.

### Strict Org: only headings are tasks

Spec Amendment 1 and plan decision D14: as in Org-mode, a Markdown checkbox is not a task.

- Only headings that start with a state are tasks. Checkboxes (including Org's partly done `[-]`) are steps: each heading task gets `progress` from the top-level checkboxes directly in its entry, else from its child TODO headings, and a `[1/3]` / `[33%]` cookie in its title is recognized.
- Planning lines, drawers, priorities and tags are read for headings only, as in Org. `:PRIORITY:` and `:STATE:` drawer entries set nothing.
- `<leader>lt` adds `## TODO <task>` (Org's `C-S-RET`: the current heading's level, after its subtree) instead of a `- TODO` bullet. `<leader>ld` adds `## WAITING <task>` with an `:ASSIGNED:` drawer instead of a `Waiting On` bullet, and the name may be several words.
- `<leader>ln` / `<leader>lp` work on headings; a plain list item never gains a state.
- Lattice v0.1 list forms (`- TODO x`, `Waiting On` bullets) are still read with v0.1 rules, and counted as legacy in `:LatticeHealth`.
- `examples/sample-notes.md` uses headings for every task.

### Milestone D — Mutation engine

- `lattice.mutate`: pure edit operations and `apply()`, which writes only changed lines as one undo step after checking the buffer still matches (stale or repeated commands are refused).
- State changes follow Org: `CLOSED` when `logging.done` is `"time"`, removed on reopen; repeating tasks advance, stay open (previous state or `repeat_to_state`), and record `:LAST_REPEAT:` and a state note (`logging.repeat`); optional `enforce.checkboxes` / `enforce.todo`; parent subtask cookies update. `<leader>ln` / `<leader>lp` now do all of this for headings.
- New commands and keys: `:LatticeSetState` (`<leader>ls`), `:LatticeToggleCheckbox` (`<leader>lx`, with Org's parent `[-]`/`[x]` and cookie updates), `:LatticeSchedule` (`<leader>lS`), `:LatticeDeadline` (`<leader>lD`), `:LatticePriorityUp` / `Down` (`<leader>l+` / `<leader>l-`), and `:LatticeMigrate` to convert a note's v0.1 items to Org headings.
- New `.lattice.json` keys: `logging`, `enforce`, `repeat_to_state`.
- Acceptance tests PAR-022 to PAR-024, PAR-026 and PAR-027.

### Milestone E — Integration

- **Incremental refresh:** a refresh re-parses only notes that changed (PAR-029); unsaved open buffers are read instead of their files; saving a note refreshes an open dashboard.
- **Views:** `1` overview, `2` week agenda (scheduled, deadlines, repeats; today's `Sched. Nx`, `N d. ago`, `In N d.`; `b`/`f`/`.` between weeks), `3` all TODOs by priority, `4` projects with counts, status and next action (`Enter` lists a project's TODOs).
- **Filters** with `/`: `+tag -tag #A project:Name @person state:NEXT` and title words.
- **Editing from the dashboard**, as in Org's agenda: `t` state, `+`/`-` priority, `S`/`D` dates, `s` saves the edited notes. Edits go to the note's buffer, unsaved.
- **`Enter`** finds the task by its title when lines moved in an open note (PAR-030).
- **`:LatticeRefile`** (`<leader>lw`) and **`:LatticeArchive`** (`<leader>lA`), with Org's re-levelling and ARCHIVE_* properties; archive notes (`**/*_archive.md`) are excluded from scanning by default; new `archive.location` setting.
- The README's example dashboard, empty since the strict-Org change, is rendered again.

## 0.1.0 — 2026-11-03

First release: Milestone 1 of [`specs/LATTICE_SPEC.md`](specs/LATTICE_SPEC.md), plus org-style TODO keyword sequences and state cycling. The sections below record how it got there.

### Cycling TODO states (#4)

#### Added

- `<leader>ln` / `:LatticeNextState` and `<leader>lp` / `:LatticePrevState` step the item under the cursor through its keyword sequence, like org-mode's `S-Right` / `S-Left`: no keyword → `TODO` → … → last done state → no keyword. They work on bullets and headings, use the note's own sequences, stay within the sequence that holds the item's keyword, and refuse lines Lattice wouldn't list (plain lines, numbered items, empty bullets, front matter, code blocks).
- New keymap names `next_state` and `prev_state`.

### Org-style TODO keywords (#2)

#### Changed from Milestone 1

- Personal tasks are now items whose first word is an org-mode style keyword: `- TODO Send update`, `## NEXT Draft plan`. They can sit anywhere in a note, at any nesting depth. The `To Do` heading is no longer recognized, so existing `## To Do` bullets need a keyword (`- TODO ...`) to appear.
- Keywords match exactly, as in org-mode (`TODO`, not `todo` or `To Do`).
- `<leader>lt` / `:LatticeAddTodo` adds `- TODO <task>` below the cursor instead of under a heading, so there is no heading prompt.
- `headings.todo` in `.lattice.json` is ignored, with a notice.

#### Added

- Keyword sequences such as `TODO NEXT | DONE CANCELED`, following org's `#+TODO:` rules (`|` splits open and done states; fast-access suffixes are ignored).
- Root sequences come from `todo` in `.lattice.json` (default `TODO | DONE`). Per-note sequences come from a YAML front matter `todo:` key, which replaces the root ones for that note. Invalid front matter is a jumpable warning, and the note falls back to the root sequences.
- Dashboard rows show each item's state, and a **DONE** group lists done-state items, most recently modified note first.
- `:LatticeHealth` lists the root sequences and front matter problems.

#### Fixed (code review)

- A note that opens with a horizontal rule is no longer mistaken for front matter. Front matter must start with a `key:` line and contain only YAML-shaped lines.
- Front matter `todo:` also accepts unindented list items, flow lists, and `# comments`.
- `<leader>lt` on a list item with sub-bullets inserts after them, so the sub-bullets stay with their own item.
- Bullets indented as code inside a list are no longer tasks.
- `- [x] TODO …` counts as done.
- The DONE group shows the 20 most recent items plus a count of the rest.
- Only notes with done items are checked for their modified time.

### Milestone 1 (#1)

#### Added

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

#### Changed

- Insertion code moved from `init.lua` to `insert.lua`.
- `examples/meeting-notes.md` renamed to `examples/sample-notes.md` and extended with edge cases.
- The header date uses English names whatever the system locale, to match the rows.
- Dates render as `Nov 05` (and `Nov 05, 2027` outside the current year). Waiting On rows read `Name — task`.

#### Kept from the initial version

- Strict `To Do` / `Waiting On` parsing, `.lattice.json` scanning, source navigation, manual refresh.
- The read-only capture **INBOX** group and the optional `[promised:YYYY-MM-DD]` tag, both recorded as decisions in `specs/product-vision.md` (2026-11-01). They go beyond LATTICE_SPEC.md but don't conflict with it.

#### Deferred (not implemented)

- File watching or background indexing; refresh is manual.
- A command that ticks `[x]` checkboxes. Cycle to a done keyword with `<leader>ln`, or edit the box by hand.
- Following symlinks that stay inside the root. All symlinks are skipped, which is the simpler safe choice.
- Multi-word assignees.
- WBR preparation, AI-assisted commitment discovery, Portico publishing, automated Drafts import (Milestones 3–6).
- A license, which the repository owner will choose.
